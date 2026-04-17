module GalaxyDiff
  # Intermediate mutable parse result — built up line by
  # line as the parser walks unified diff output, then
  # converted into immutable `GdiffFile` structs by
  # `DiffCapture`.
  class ParsedFile
    property path : String = ""
    property old_path : String? = nil
    property old_path_raw : String? = nil
    property status : String = ""
    property hunks : Array(GdiffHunk) = [] of GdiffHunk
  end

  # Parses unified-diff output (`git diff --no-color -U3`)
  # into structured `ParsedFile` records. The output is
  # position-sensitive: each `diff --git` block starts a
  # new file, each `@@` line starts a new hunk, and
  # `+`/`-`/` ` lines populate the active hunk.
  module DiffParser
    extend self

    HUNK_HEADER =
      /@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

    # Matches `diff --git a/PATH b/PATH`. Captures both
    # paths — for most diffs they're identical, for
    # renames they differ. This gives us a `path` value
    # even for diffs with no `---`/`+++` headers (e.g.
    # binary files).
    DIFF_GIT_HEADER =
      /^diff --git a\/(.+) b\/(.+)$/

    def parse(raw : String) : Array(ParsedFile)
      files = [] of ParsedFile
      current_file : ParsedFile? = nil
      current_hunk : GdiffHunk? = nil
      old_line = 0
      new_line = 0

      raw.each_line do |line|
        if line.starts_with?("diff --git")
          # Flush the hunk we were building (if any) onto
          # its owning file, then flush the file itself.
          if (hunk = current_hunk) && (file = current_file)
            file.hunks << hunk
          end
          if file = current_file
            file.status = "modified" if file.status.empty?
            files << file
          end

          current_file = ParsedFile.new
          current_hunk = nil

          # Seed path/old_path_raw from the diff header
          # itself so binary diffs (which have no +++
          # line) still get a usable path, and so deleted
          # files (whose +++ is /dev/null) still know
          # their original path.
          if m = line.match(DIFF_GIT_HEADER)
            current_file.not_nil!.old_path_raw = m[1]
            current_file.not_nil!.path = m[2]
          end
        elsif line.starts_with?("--- ")
          if file = current_file
            old_path = line[4..]
            if old_path.starts_with?("a/")
              file.old_path_raw = old_path[2..]
            elsif old_path == "/dev/null"
              file.old_path_raw = "/dev/null"
              file.status = "added"
            end
          end
        elsif line.starts_with?("+++ ")
          if file = current_file
            new_path = line[4..]
            if new_path.starts_with?("b/")
              file.path = new_path[2..]
            elsif new_path == "/dev/null"
              file.status = "deleted"
            end
          end
        elsif line.starts_with?("rename from ")
          if file = current_file
            file.old_path = line[12..].chomp
            file.status = "renamed"
          end
        elsif line.starts_with?("rename to ")
          if file = current_file
            file.path = line[10..].chomp
          end
        elsif line.starts_with?("deleted file")
          if file = current_file
            file.status = "deleted"
          end
        elsif line.starts_with?("new file")
          if file = current_file
            file.status = "added"
          end
        elsif line.starts_with?("Binary files")
          # Git skips content for binaries; mark the file
          # so downstream renderers know there's nothing
          # to display.
          if file = current_file
            file.status = "binary" if file.status.empty?
          end
        elsif line.starts_with?("@@")
          if (hunk = current_hunk) && (file = current_file)
            file.hunks << hunk
          end
          if m = line.match(HUNK_HEADER)
            old_start = m[1].to_i
            old_count = (m[2]? || "1").to_i
            new_start = m[3].to_i
            new_count = (m[4]? || "1").to_i
            current_hunk = GdiffHunk.new(
              old_start: old_start,
              old_count: old_count,
              new_start: new_start,
              new_count: new_count,
            )
            old_line = old_start
            new_line = new_start
          end
        elsif line.starts_with?("\\ ")
          # `\ No newline at end of file` — skip.
        elsif hunk = current_hunk
          if line.starts_with?("-")
            hunk.lines << GdiffLine.new(
              type: GdiffLineType::Delete,
              old_no: old_line,
              new_no: nil,
              content: line[1..],
            )
            old_line += 1
          elsif line.starts_with?("+")
            hunk.lines << GdiffLine.new(
              type: GdiffLineType::Add,
              old_no: nil,
              new_no: new_line,
              content: line[1..],
            )
            new_line += 1
          elsif line.starts_with?(" ") || line.empty?
            content = line.empty? ? "" : line[1..]
            hunk.lines << GdiffLine.new(
              type: GdiffLineType::Context,
              old_no: old_line,
              new_no: new_line,
              content: content,
            )
            old_line += 1
            new_line += 1
          end
        end
      end

      # Flush the in-flight hunk and file at EOF.
      if (hunk = current_hunk) && (file = current_file)
        file.hunks << hunk
      end
      if file = current_file
        file.status = "modified" if file.status.empty?
        files << file
      end

      files
    end
  end
end
