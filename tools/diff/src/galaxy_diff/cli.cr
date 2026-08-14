module GalaxyDiff
  module CLI
    def self.run(args : Array(String))
      if args.empty?
        show_help
        return
      end

      command = args.first
      rest = args[1..]

      case command
      when "capture"
        if rest.includes?("-h") || rest.includes?("--help")
          show_capture_help
        else
          handle_capture(rest)
        end
      when "install"
        if InstallManager.install
          puts "galaxy-diff: skills installed"
        else
          STDERR.puts "Error: install failed"
          exit(1)
        end
      when "uninstall"
        if InstallManager.uninstall
          puts "galaxy-diff: skills uninstalled"
        else
          STDERR.puts "Error: uninstall failed"
          exit(1)
        end
      when "version"
        puts "galaxy-diff #{VERSION}"
      when "help", "-h", "--help"
        show_help
      when "-v", "--version"
        puts "galaxy-diff #{VERSION}"
      else
        STDERR.puts "Error: Unknown command '#{command}'"
        STDERR.puts "Run 'galaxy-diff --help' for usage"
        exit(1)
      end
    end

    # ============================================================
    # capture
    # ============================================================

    private def self.handle_capture(args : Array(String))
      from_ref : String? = nil
      to_ref : String? = nil
      repo_path : String? = nil
      pathspecs = [] of String

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--"
          # Everything after `--` is a path, git's own
          # convention. This is the remedy for an oversized
          # capture: a diff too large for the reader can be
          # taken in two narrower passes instead of not at
          # all, which until now was the only option.
          pathspecs = args[(i + 1)..]
          break
        when "--from"
          if i + 1 < args.size
            from_ref = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --from requires a value"
            exit(1)
          end
        when "--to"
          if i + 1 < args.size
            to_ref = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --to requires a value"
            exit(1)
          end
        when "--repo"
          if i + 1 < args.size
            repo_path = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --repo requires a value"
            exit(1)
          end
        else
          STDERR.puts "Error: Unknown option '#{arg}'"
          STDERR.puts "Run 'galaxy-diff capture --help' for usage"
          exit(1)
        end
      end

      # Default base is HEAD. Default target is the
      # working tree (represented by nil in capture).
      effective_from = from_ref || "HEAD"

      result = DiffCapture.capture(
        from_ref: effective_from,
        to_ref: to_ref,
        repo_path: repo_path,
        pathspecs: pathspecs,
      )

      STDOUT.puts result.to_json
    end

    # ============================================================
    # help
    # ============================================================

    private def self.show_help
      puts <<-HELP
      galaxy-diff - Capture structured diff snapshots

      USAGE:
        galaxy-diff <command> [options]

      COMMANDS:
        capture     Capture a diff as structured JSON
        install     Install galaxy-diff skills
        uninstall   Remove galaxy-diff skills
        version     Show version

      Run 'galaxy-diff <command> --help' for details.
      HELP
    end

    private def self.show_capture_help
      puts <<-HELP
      galaxy-diff capture - Capture a structured diff

      USAGE:
        galaxy-diff capture [options]

      OPTIONS:
        --from REF    Base ref (default: HEAD)
        --to REF      Target ref (default: working tree).
                      Special value "staged" captures the
                      index vs the base ref.
        --repo PATH   Repository path (default: cwd)
        -- PATH...    Limit the capture to these paths

      EXAMPLES:
        # Working tree changes vs HEAD:
        galaxy-diff capture

        # One subtree only — also the fix when a capture
        # comes out too large for the diff reader:
        galaxy-diff capture -- tools/diff

        # Staged changes only:
        galaxy-diff capture --from HEAD --to staged

        # Between two commits:
        galaxy-diff capture --from abc123 --to def456

        # Pipe into artifact storage:
        galaxy-diff capture | galaxy-artifacts save \\
          --pid PID --filename changes.gdiff

      OUTPUT:
        Structured JSON (.gdiff format) to stdout.
        Contains full file contents (before/after) and
        parsed hunk data for each changed file.
      HELP
    end
  end
end
