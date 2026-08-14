require "json"

module GalaxyDiff
  # Orchestrates a diff capture: runs `git diff` in the
  # target repo, parses hunks via `DiffParser`, then
  # enriches each file entry with full before/after
  # contents and language hints. Produces an immutable
  # `GdiffDocument` ready for JSON serialization.
  module DiffCapture
    extend self

    # Map file extensions to highlight.js language names.
    # Mirrors `languageForExtension` in Galaxy.app so the
    # renderer picks the same grammar for highlighting.
    LANGUAGE_MAP = {
      ".rb" => "ruby", ".cr" => "crystal",
      ".py" => "python", ".js" => "javascript",
      ".ts" => "typescript", ".jsx" => "javascript",
      ".tsx" => "typescript", ".swift" => "swift",
      ".go" => "go", ".rs" => "rust",
      ".java" => "java", ".kt" => "kotlin",
      ".sql" => "sql", ".sh" => "bash",
      ".bash" => "bash", ".zsh" => "bash",
      ".yml" => "yaml", ".yaml" => "yaml",
      ".json" => "json", ".toml" => "ini",
      ".xml" => "xml", ".html" => "xml",
      ".htm" => "xml", ".css" => "css",
      ".scss" => "scss", ".less" => "less",
      ".vue" => "xml", ".erb" => "erb",
      ".haml" => "haml", ".slim" => "ruby",
      ".md" => "markdown", ".markdown" => "markdown",
    }

    def capture(
      from_ref : String,
      to_ref : String?,
      repo_path : String?,
      pathspecs : Array(String) = [] of String,
    ) : GdiffDocument
      dir = repo_path || Dir.current

      diff_args = build_diff_args(from_ref, to_ref)
      diff_args += ["--"] + pathspecs unless pathspecs.empty?
      raw_diff = run_git(
        dir,
        ["diff", "--no-color", "-U3"] + diff_args,
      )

      parsed_files = DiffParser.parse(raw_diff)

      files = [] of GdiffFile
      parsed_files.each do |pf|
        before = read_before(dir, pf, from_ref)
        after = read_after(dir, pf, to_ref)
        language = language_for_path(pf.path)

        # Git's detection is authoritative about intent but
        # not about encoding: a latin-1 source, or a fixture
        # with a stray high byte, is "text" to git and still
        # cannot be spliced into a JSON string. Emitting it
        # produced a .gdiff no strict decoder would read,
        # while every layer reported success.
        unless embeddable?(before) && embeddable?(after)
          pf.binary = true
          before = nil
          after = nil
        end

        before_bytes, after_bytes =
          if pf.binary
            {
              blob_size(
                dir, pf.old_path || pf.path,
                from_ref, pf.status, :before,
              ),
              blob_size(
                dir, pf.path, to_ref, pf.status, :after,
              ),
            }
          else
            {nil, nil}
          end

        files << GdiffFile.new(
          path: pf.path,
          old_path: pf.old_path,
          status: pf.status,
          language: language,
          before: before,
          after: after,
          # Git supplies no hunks for a binary it detected,
          # but a file caught by the check above does — full
          # of the same bytes. Dropping them is what makes
          # the check complete rather than half-applied.
          hunks: pf.binary ? [] of GdiffHunk : pf.hunks,
          binary: pf.binary,
          before_bytes: before_bytes,
          after_bytes: after_bytes,
        )
      end

      # Untracked files don't show up in `git diff`,
      # but when capturing against the working tree they
      # conceptually belong in the "after" set as
      # newly-added files. Synthesize an `added` entry
      # for each so the reader renders them alongside
      # tracked changes.
      if to_ref.nil?
        list_untracked(dir, pathspecs).each do |rel|
          content = read_working_file(dir, rel)
          next if content.nil?
          files << build_untracked_file(dir, rel, content)
        end
      end

      # Resolve refs to 40-char SHAs when possible —
      # commit snapshots are durable, branch names
      # aren't. Fall back to the original input (e.g.,
      # "main" for an unresolvable ref, "staged" for
      # the index pseudo-ref); fall back to
      # "working-tree" when ref_to is nil. The reader
      # uses the SHA-shape of both refs as its
      # linkability check, so storing non-SHA strings
      # here correctly suppresses the GitHub link
      # affordance for cases that can't address a
      # specific remote commit.
      resolved_from =
        resolve_ref_to_sha(dir, from_ref) || from_ref
      resolved_to =
        if to_ref.nil?
          "working-tree"
        else
          resolve_ref_to_sha(dir, to_ref) || to_ref
        end
      repo = parse_github_origin(dir)
      summary = build_summary(files)

      GdiffDocument.new(
        version: 1,
        metadata: GdiffMetadata.new(
          ref_from: resolved_from,
          ref_to: resolved_to,
          repo: repo,
          created_at: Time.utc.to_rfc3339,
          summary: summary,
        ),
        files: files,
      )
    end

    # Build the ref-selection portion of the git diff
    # invocation. An explicit `to_ref` of "staged" maps
    # to `--cached <from>` (index vs base); otherwise we
    # emit a standard `<from> [<to>]` pair. Omitting
    # `to_ref` diffs working tree against `from_ref`.
    private def build_diff_args(
      from_ref : String,
      to_ref : String?,
    ) : Array(String)
      if to_ref == "staged"
        ["--cached", from_ref]
      elsif to_ref
        [from_ref, to_ref]
      else
        [from_ref]
      end
    end

    private def read_before(
      dir : String,
      pf : ParsedFile,
      from_ref : String,
    ) : String?
      # A newly-added file has no prior content.
      return nil if pf.status == "added"
      # Binary files can't be read as text.
      return nil if pf.binary
      target = pf.old_path || pf.path
      read_file_at_ref(dir, target, from_ref)
    end

    private def read_after(
      dir : String,
      pf : ParsedFile,
      to_ref : String?,
    ) : String?
      return nil if pf.status == "deleted"
      return nil if pf.binary

      case to_ref
      when nil
        read_working_file(dir, pf.path)
      when "staged"
        read_staged_file(dir, pf.path)
      else
        read_file_at_ref(dir, pf.path, to_ref)
      end
    end

    private def read_file_at_ref(
      dir : String,
      path : String,
      ref : String,
    ) : String?
      output, status = run_git_with_status(
        dir, ["show", "#{ref}:#{path}"],
      )
      return nil unless status.success?
      output
    end

    private def read_staged_file(
      dir : String,
      path : String,
    ) : String?
      output, status = run_git_with_status(
        dir, ["show", ":#{path}"],
      )
      return nil unless status.success?
      output
    end

    private def read_working_file(
      dir : String,
      path : String,
    ) : String?
      full_path = File.join(dir, path)
      return nil unless File.exists?(full_path)
      File.read(full_path)
    rescue
      nil
    end

    # List paths that git knows about as untracked
    # (respecting `.gitignore` via --exclude-standard).
    # Returns relative paths from the repo root.
    private def list_untracked(
      dir : String,
      pathspecs : Array(String) = [] of String,
    ) : Array(String)
      args = ["ls-files", "--others", "--exclude-standard"]
      args += ["--"] + pathspecs unless pathspecs.empty?
      output, status = run_git_with_status(dir, args)
      return [] of String unless status.success?
      output.split('\n').reject(&.empty?)
    end

    # Build a synthetic `GdiffFile` for an untracked
    # file. We treat it as a fully-added file: `before`
    # is nil, `after` is the working-tree content, and
    # we synthesize a single hunk where every line is
    # an "add" so per-file stats (insertion count,
    # renderer overlay) behave identically to a git-
    # reported added file.
    private def build_untracked_file(
      dir : String, rel : String, content : String,
    ) : GdiffFile
      # An untracked binary — a new icon, a build artifact —
      # never reached git's binary detection, because it
      # never appeared in a diff at all. Without this its
      # bytes landed in `after` AND, split on 0x0A, in every
      # synthesized hunk line.
      unless embeddable?(content)
        return GdiffFile.new(
          path: rel,
          old_path: nil,
          status: "added",
          language: nil,
          before: nil,
          after: nil,
          hunks: [] of GdiffHunk,
          binary: true,
          before_bytes: 0_i64,
          after_bytes: file_size_or_nil(dir, rel),
        )
      end

      raw = content.split('\n')
      # Drop trailing empty element if content ended
      # with "\n" — Unix convention, not a real line.
      if !raw.empty? && raw.last.empty? &&
         content.ends_with?('\n')
        raw.pop
      end

      lines = raw.map_with_index do |text, idx|
        GdiffLine.new(
          type: GdiffLineType::Add,
          old_no: nil,
          new_no: idx + 1,
          content: text,
        )
      end

      hunk = GdiffHunk.new(
        old_start: 0,
        old_count: 0,
        new_start: lines.empty? ? 0 : 1,
        new_count: lines.size,
      )
      hunk.lines = lines

      GdiffFile.new(
        path: rel,
        old_path: nil,
        status: "added",
        language: language_for_path(rel),
        before: nil,
        after: content,
        hunks: [hunk],
      )
    end

    # Resolves a git ref to its full 40-char commit
    # SHA. Uses `rev-parse --verify <ref>^{commit}` so
    # tags peel to their commit and invalid refs fail
    # cleanly. Returns nil when the ref doesn't
    # resolve (bad input, "staged" pseudo-ref, etc.);
    # caller falls back to the original input.
    #
    # Runs silently so expected-to-fail calls (e.g.,
    # resolving "staged") don't pollute stderr.
    private def resolve_ref_to_sha(
      dir : String, ref : String,
    ) : String?
      output, status = run_git_with_status(
        dir,
        ["rev-parse", "--verify", "#{ref}^{commit}"],
        silent: true,
      )
      return nil unless status.success?
      sha = output.strip
      return nil unless sha =~ /\A[0-9a-f]{40}\z/
      sha
    end

    # Parses `origin` remote URL into `owner/repo`
    # form for GitHub remotes. Returns "" when origin
    # isn't set or isn't a GitHub URL. Recognized
    # shapes:
    #   git@github.com:owner/repo.git
    #   https://github.com/owner/repo.git
    #   https://github.com/owner/repo
    #   ssh://git@github.com/owner/repo.git
    #
    # GitHub Enterprise (github.mycorp.com) is not
    # handled — would need explicit user configuration
    # to know which hosts support the compare URL.
    private def parse_github_origin(
      dir : String,
    ) : String
      output, status = run_git_with_status(
        dir,
        ["remote", "get-url", "origin"],
        silent: true,
      )
      return "" unless status.success?
      url = output.strip
      idx = url.index("github.com")
      return "" if idx.nil?

      # Everything after "github.com", minus any
      # leading ":"/"/" (SSH uses colon, HTTPS uses
      # slash).
      remainder = url[(idx + "github.com".size)..]
      remainder = remainder.lstrip(":/")

      # Strip trailing noise: ".git" suffix, trailing
      # slashes. Order matters — do "/" first so
      # "repo.git/" trims to "repo.git" then "repo".
      remainder = remainder.rchop("/")
      remainder = remainder.rchop(".git")
      remainder = remainder.rchop("/")

      parts = remainder.split("/")
      return "" if parts.size < 2
      owner = parts[0]
      repo = parts[1]
      return "" if owner.empty? || repo.empty?
      "#{owner}/#{repo}"
    end

    private def build_summary(
      files : Array(GdiffFile),
    ) : String
      total_adds = 0
      total_dels = 0
      files.each do |f|
        f.hunks.each do |h|
          h.lines.each do |l|
            total_adds += 1 if l.type.add?
            total_dels += 1 if l.type.delete?
          end
        end
      end
      file_word = files.size == 1 ? "file" : "files"
      ins_word = total_adds == 1 ? "insertion" : "insertions"
      del_word = total_dels == 1 ? "deletion" : "deletions"
      "#{files.size} #{file_word} changed, " \
      "#{total_adds} #{ins_word}, " \
      "#{total_dels} #{del_word}"
    end

    private def language_for_path(
      path : String,
    ) : String?
      ext = File.extname(path).downcase
      LANGUAGE_MAP[ext]?
    end

    # Whether content can be spliced into a JSON string.
    #
    # `nil` is embeddable — it means "no content on this
    # side", a legitimate state for an added or deleted file.
    #
    # NUL is rejected separately because `valid_encoding?`
    # accepts it: NUL is a legal codepoint, so a file whose
    # first NUL falls past git's 8000-byte sniff window is
    # "text" to git and "valid" to Crystal, and embeds as the
    # six characters \\u0000 apiece — valid JSON, and NUL
    # characters delivered into the reader's DOM.
    private def embeddable?(content : String?) : Bool
      return true if content.nil?
      return false unless content.valid_encoding?
      !content.includes?('\0')
    end

    # Size of a blob without reading it. `cat-file -s` asks
    # the object database for the size alone, so a 6 MB
    # binary costs no transfer — which is why a binary entry
    # can afford to report sizes while refusing content.
    private def blob_size(
      dir : String,
      path : String,
      ref : String?,
      status : String,
      side : Symbol,
    ) : Int64?
      return 0_i64 if side == :before && status == "added"
      return 0_i64 if side == :after && status == "deleted"

      spec =
        case ref
        when nil
          return file_size_or_nil(dir, path)
        when "staged"
          ":#{path}"
        else
          "#{ref}:#{path}"
        end

      output, st = run_git_with_status(
        dir, ["cat-file", "-s", spec], silent: true)
      return nil unless st.success?
      output.strip.to_i64?
    end

    private def file_size_or_nil(
      dir : String, path : String,
    ) : Int64?
      full = File.join(dir, path)
      return nil unless File.exists?(full)
      File.size(full).to_i64
    rescue
      nil
    end

    # Run `git` in `dir` and return stdout as a String.
    # Errors on stderr are relayed to our own stderr so
    # the caller sees git's complaint (e.g., bad ref).
    private def run_git(
      dir : String,
      args : Array(String),
    ) : String
      output, _ = run_git_with_status(dir, args)
      output
    end

    private def run_git_with_status(
      dir : String,
      args : Array(String),
      silent : Bool = false,
    ) : {String, Process::Status}
      output = IO::Memory.new
      error = IO::Memory.new
      # --no-optional-locks makes diff/rev-parse skip the opportunistic
      # index.lock they take to refresh the stat cache, so capturing a
      # diff can't race a concurrent git write in the same repo and fail
      # with "another git process is running".
      status = Process.run(
        "git",
        args: ["--no-optional-locks"] + args,
        chdir: dir,
        output: output,
        error: error,
      )
      unless status.success? || silent
        err = error.to_s.strip
        STDERR.puts "git error: #{err}" unless err.empty?
      end
      {output.to_s, status}
    end
  end
end
