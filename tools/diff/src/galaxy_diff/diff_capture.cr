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
    ) : GdiffDocument
      dir = repo_path || Dir.current

      diff_args = build_diff_args(from_ref, to_ref)
      raw_diff = run_git(
        dir,
        ["diff", "--no-color", "-U3"] + diff_args,
      )

      parsed_files = DiffParser.parse(raw_diff)

      files = parsed_files.map do |pf|
        before = read_before(dir, pf, from_ref)
        after = read_after(dir, pf, to_ref)
        language = language_for_path(pf.path)

        GdiffFile.new(
          path: pf.path,
          old_path: pf.old_path,
          status: pf.status,
          language: language,
          before: before,
          after: after,
          hunks: pf.hunks,
        )
      end

      branch = resolve_branch(dir)
      summary = build_summary(files)

      GdiffDocument.new(
        version: 1,
        metadata: GdiffMetadata.new(
          ref_from: from_ref,
          ref_to: to_ref || "working-tree",
          branch: branch,
          repo: dir,
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
      return nil if pf.status == "binary"
      target = pf.old_path || pf.path
      read_file_at_ref(dir, target, from_ref)
    end

    private def read_after(
      dir : String,
      pf : ParsedFile,
      to_ref : String?,
    ) : String?
      return nil if pf.status == "deleted"
      return nil if pf.status == "binary"

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

    private def resolve_branch(dir : String) : String
      output, status = run_git_with_status(
        dir, ["rev-parse", "--abbrev-ref", "HEAD"],
      )
      return "unknown" unless status.success?
      output.strip
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
    ) : {String, Process::Status}
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run(
        "git",
        args: args,
        chdir: dir,
        output: output,
        error: error,
      )
      unless status.success?
        err = error.to_s.strip
        STDERR.puts "git error: #{err}" unless err.empty?
      end
      {output.to_s, status}
    end
  end
end
