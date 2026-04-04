require "file_utils"
require "option_parser"
require "uri"

module Galaxy
  class CLI
    # Galaxy's own commands — checked before delegation
    GALAXY_COMMANDS = %w[help version update config backups]

    def self.run(args : Array(String))
      # Save original args before OptionParser modifies the array in-place.
      # Needed for delegation — claude-persona must receive the full args.
      original_args = args.dup

      show_help_flag = false
      show_version_flag = false
      vibe = false
      dryrun = false
      resume_id : String? = nil
      print_prompt : String? = nil

      parser = OptionParser.new do |p|
        p.banner = build_banner

        p.separator ""
        p.separator "Options:"

        p.on("--vibe", "Launch persona in vibe mode") { vibe = true }
        p.on("--dry-run", "Show command without executing (delegates to claude-persona)") { dryrun = true }
        p.on("-p PROMPT", "--print=PROMPT", "Print response and exit (delegates to claude-persona)") { |prompt| print_prompt = prompt }
        p.on("-r ID", "--resume=ID", "Resume a previous session") { |id| resume_id = id }
        p.on("-h", "--help", "Show this help") { show_help_flag = true }
        p.on("-v", "--version", "Show version") { show_version_flag = true }

        p.invalid_option do |flag|
          STDERR.puts "Error: Unknown flag '#{flag}'"
          STDERR.puts "Run 'galaxy --help' for usage"
          exit(1)
        end
      end

      # Parse and collect positional args
      positional_args = [] of String
      parser.unknown_args { |a| positional_args = a }
      parser.parse(args)

      # 1. Handle help/version flags
      if show_help_flag
        puts parser
        return
      end

      if show_version_flag
        puts VERSION
        return
      end

      # 2. No args: open Galaxy.app with vanilla Claude session
      #    (--resume without a command opens Mac app for vanilla resume)
      if positional_args.empty? && !resume_id
        open_session(vibe: vibe)
        return
      end

      # 3. No args + --resume: open Galaxy.app for vanilla resume
      if positional_args.empty? && resume_id
        open_session(vibe: vibe, resume: resume_id)
        return
      end

      # First positional arg is command or persona name
      command = positional_args.first
      rest = positional_args[1..]? || [] of String

      # 4. Galaxy's own commands
      case command
      when "help"
        puts parser
        return
      when "version"
        puts VERSION
        return
      when "update"
        handle_update_command(rest)
        return
      when "config"
        handle_config_command(rest)
        return
      when "backups"
        handle_backups_command(rest, dryrun: dryrun)
        return
      end

      # 5. "generate" → delegate to claude-persona locally + post-banner
      if command == "generate"
        handle_generate_command(original_args)
        return
      end

      # 6. Non-interactive flags (--dry-run or -p): delegate locally
      if dryrun || print_prompt
        delegate_to_claude_persona(original_args)
        return
      end

      # 7. Persona TOML exists for first arg → open Galaxy.app with persona
      if persona_file_exists?(command)
        open_session(persona: command, vibe: vibe, resume: resume_id)
        return
      end

      # 8. Otherwise → delegate to claude-persona (handles: list, show, rename,
      #    remove, mcp *, unknown commands/errors)
      delegate_to_claude_persona(original_args)
    end

    # Check if a persona TOML file exists in the personas directory
    def self.persona_file_exists?(name : String) : Bool
      File.exists?(PERSONAS_DIR / "#{name}.toml")
    end

    # Build a galaxy:// URL with optional persona/vibe/resume parameters
    def self.build_session_url(
      path : String,
      persona : String? = nil,
      vibe : Bool = false,
      resume : String? = nil,
    ) : String
      encoded_path = URI.encode_path(path)
      url = "#{URL_SCHEME}://new-session?path=#{encoded_path}"
      url += "&persona=#{URI.encode_path(persona)}" if persona
      url += "&vibe=true" if vibe
      url += "&resume=#{URI.encode_path(resume)}" if resume
      url
    end

    # Locate the claude-persona binary. Returns path or nil if not found.
    def self.find_claude_persona_path : String?
      possible_paths = [
        Path.home / ".local" / "bin" / "claude-persona",
        Path.new("/usr/local/bin/claude-persona"),
      ]

      possible_paths.each do |path|
        path_str = path.to_s
        if File.exists?(path_str) && File.info(path_str).permissions.owner_execute?
          return path_str
        end
      end

      # Fallback: which (may fail if PATH is empty or which is not found)
      begin
        output = IO::Memory.new
        status = Process.run("which", args: ["claude-persona"],
          output: output,
          error: Process::Redirect::Close)
        if status.success?
          result = output.to_s.strip
          return result unless result.empty?
        end
      rescue File::NotFoundError
        # `which` not found (e.g., empty PATH) — fall through to nil
      end

      nil
    end

    # Opens Galaxy.app via URL scheme with optional persona parameters
    def self.open_session(
      persona : String? = nil,
      vibe : Bool = false,
      resume : String? = nil,
    )
      # For persona sessions, verify claude-persona is available
      if persona
        unless find_claude_persona_path
          show_claude_persona_install_hint
          exit(1)
        end
      end

      path = Dir.current
      url = build_session_url(path, persona: persona, vibe: vibe, resume: resume)

      stderr = IO::Memory.new
      status = Process.run(
        "open",
        args: [url],
        output: Process::Redirect::Close,
        error: stderr
      )

      unless status.success?
        error_output = stderr.to_s
        unless error_output.empty?
          STDERR.puts error_output
        end
        STDERR.puts "Error: Failed to open Galaxy.app"
        STDERR.puts "Make sure Galaxy.app is installed"
        exit(1)
      end
    end

    # Delegate a command to claude-persona with inherited I/O
    private def self.delegate_to_claude_persona(args : Array(String))
      cp_path = find_claude_persona_path

      unless cp_path
        show_claude_persona_install_hint
        exit(1)
      end

      status = Process.run(
        cp_path,
        args: args,
        input: Process::Redirect::Inherit,
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit
      )

      exit(status.exit_code)
    end

    # Handle "galaxy generate" — delegate locally, then show post-banner
    private def self.handle_generate_command(original_args : Array(String))
      cp_path = find_claude_persona_path

      unless cp_path
        show_claude_persona_install_hint
        exit(1)
      end

      status = Process.run(
        cp_path,
        args: original_args,
        input: Process::Redirect::Inherit,
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit
      )

      if status.success?
        # Show post-generate banner with Galaxy launch hint
        puts ""
        puts "Launch this persona in Galaxy:"
        puts "  galaxy <persona-name>"
      end

      exit(status.exit_code)
    end

    private def self.show_claude_persona_install_hint
      STDERR.puts "Claude Persona is not installed. Persona features require it."
      STDERR.puts ""
      STDERR.puts "Install from: https://github.com/kellyredding/claude-persona"
    end

    private def self.build_banner : String
      if find_claude_persona_path
        build_full_banner
      else
        build_vanilla_banner
      end
    end

    private def self.build_full_banner : String
      <<-BANNER
      Galaxy v#{VERSION} - Claude Code session manager

      Usage:
        galaxy                          Open Galaxy with a new Claude session
        galaxy <persona>                Open Galaxy with a persona session
        galaxy <persona> --vibe         Launch persona in vibe mode
        galaxy <persona> --resume <id>  Resume a persona session
        galaxy --resume <id>            Resume a vanilla session
        galaxy generate                 Create a new persona interactively

        galaxy list                     List available personas
        galaxy show <name>              Show persona configuration
        galaxy mcp list                 List imported MCP configs
        ... and all other claude-persona commands.
        Run 'claude-persona help' for the full reference.

        galaxy config                   Manage Galaxy configuration
        galaxy backups                  Manage backups
        galaxy update                   Update Galaxy
        galaxy version                  Show version
        galaxy help                     Show this help
      BANNER
    end

    private def self.build_vanilla_banner : String
      <<-BANNER
      Galaxy v#{VERSION} - Claude Code session manager

      Usage:
        galaxy                          Open Galaxy with a new Claude session
        galaxy --resume <id>            Resume a session

        galaxy config                   Manage Galaxy configuration
        galaxy backups                  Manage backups
        galaxy update                   Update Galaxy
        galaxy version                  Show version
        galaxy help                     Show this help

      Persona features require claude-persona:
        https://github.com/kellyredding/claude-persona
      BANNER
    end

    private def self.handle_update_command(args : Array(String))
      # Check for help subcommand first
      if args.includes?("help")
        show_update_help
        return
      end

      # Validate prerequisites
      unless command_exists?("curl")
        STDERR.puts "Error: curl is required for updates"
        STDERR.puts "Install curl and try again"
        exit(1)
      end

      unless command_exists?("bash")
        STDERR.puts "Error: bash is required for updates"
        exit(1)
      end

      # Build script URL
      script_url = "https://raw.githubusercontent.com/kellyredding/galaxy/main/tools/galaxy/scripts/update.sh"

      # Pass subcommands to script
      script_args = args.join(" ")

      # Fetch and execute
      status = Process.run(
        "bash",
        args: ["-c", "curl -fsSL '#{script_url}' | bash -s -- #{script_args}"],
        input: Process::Redirect::Inherit,
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit
      )

      exit(status.exit_code)
    end

    def self.command_exists?(cmd : String) : Bool
      Process.run("which", args: [cmd], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
    rescue File::NotFoundError
      false
    end

    # --- Config command ---

    private def self.handle_config_command(
      args : Array(String),
    )
      if args.empty?
        config = SharedConfig.load
        puts config.to_pretty_json
        return
      end

      subcommand = args[0]
      rest = args[1..]? || [] of String

      case subcommand
      when "help", "-h", "--help"
        show_config_help
      when "set"
        config_set(rest)
      when "get"
        config_get(rest)
      when "reset"
        config_reset
      when "path"
        puts CONFIG_FILE
      else
        STDERR.puts(
          "Error: Unknown config command '#{subcommand}'"
        )
        STDERR.puts(
          "Run 'galaxy config help' for usage"
        )
        exit(1)
      end
    end

    private def self.show_config_help
      puts <<-HELP
      galaxy config - Manage shared Galaxy configuration

      USAGE:
        galaxy config                    Show current configuration
        galaxy config help               Configuration documentation
        galaxy config set KEY VALUE      Set a configuration value
        galaxy config get KEY            Get a configuration value
        galaxy config reset              Reset to defaults
        galaxy config path               Show config file location

      CONFIGURATION FILE:
        #{CONFIG_FILE}

      AVAILABLE SETTINGS:

        backups.*                    Database backup settings
          backups.enabled            Enable/disable backups (default: true)
          backups.retention_days     Days to keep backups (default: 3)
          backups.path               Custom backup directory (default: #{GALAXY_DIR / "data" / "backups"})

      EXAMPLES:
        galaxy config set backups.retention_days 7
        galaxy config set backups.enabled false
        galaxy config set backups.path /path/to/backups
        galaxy config get backups.retention_days
        galaxy config reset
      HELP
    end

    private def self.config_set(args : Array(String))
      if args.size < 2
        STDERR.puts(
          "Usage: galaxy config set KEY VALUE"
        )
        exit(1)
      end

      key = args[0]
      value = args[1]

      config = SharedConfig.load
      begin
        config.set(key, value)
        config.save
        puts "Set #{key} = #{value}"
      rescue ex
        STDERR.puts "Error: #{ex.message}"
        exit(1)
      end
    end

    private def self.config_get(args : Array(String))
      if args.empty?
        STDERR.puts(
          "Usage: galaxy config get KEY"
        )
        exit(1)
      end

      key = args[0]
      config = SharedConfig.load

      begin
        value = config.get(key)
        puts value
      rescue ex
        STDERR.puts "Error: #{ex.message}"
        exit(1)
      end
    end

    private def self.config_reset
      config = SharedConfig.default
      config.save
      puts "Configuration reset to defaults"
      puts "  #{CONFIG_FILE}"
    end

    # --- Backups command ---

    private def self.handle_backups_command(
      args : Array(String),
      dryrun : Bool = false,
    )
      if args.empty?
        show_backups_help
        return
      end

      subcommand = args[0]
      rest = args[1..]? || [] of String

      case subcommand
      when "help", "-h", "--help"
        show_backups_help
      when "create"
        # --dry-run can come from top-level parser or
        # from subcommand args
        dry = dryrun || rest.includes?("--dry-run")
        backups_create(rest, dry_run: dry)
      when "list"
        backups_list
      when "prune"
        backups_prune
      else
        STDERR.puts(
          "Error: Unknown backups command " \
          "'#{subcommand}'"
        )
        STDERR.puts(
          "Run 'galaxy backups help' for usage"
        )
        exit(1)
      end
    end

    private def self.show_backups_help
      puts <<-HELP
      galaxy backups - Manage backups for all Galaxy tools and app data

      USAGE:
        galaxy backups create            Back up everything
        galaxy backups create --dry-run  Show what would be backed up
        galaxy backups list              List all backups
        galaxy backups prune             Prune old backups
        galaxy backups help              Show this help

      CONFIGURATION:
        Backup settings are in #{CONFIG_FILE}:
          backups.enabled          Enable/disable backups (default: true)
          backups.retention_days   Days to keep (default: 3)
          backups.path             Custom backup directory

        Use 'galaxy config set backups.retention_days 7' to configure.

      DESCRIPTION:
        Creates point-in-time backups of all Galaxy tool databases
        (ledger, snapshots, artifacts, timeline, agents) and Galaxy.app
        data files (sessions, settings, window state).

        Tool databases are backed up via SQLite VACUUM INTO. App data
        files are copied. All backups land in date-stamped directories
        under the configured backup path.

        Backups also run automatically on every fresh session start via
        the ledger startup hook. This command provides manual control.
      HELP
    end

    private def self.backups_create(
      args : Array(String),
      dry_run : Bool = false,
    )
      config = SharedConfig.load
      backup_dir = config.effective_backup_path
      today = Time.local.to_s("%Y-%m-%d")
      date_dir = backup_dir / today

      unless config.backups.enabled
        puts "Backups are disabled."
        puts(
          "  Enable with: galaxy config set " \
          "backups.enabled true"
        )
        return
      end

      if dry_run
        puts "Dry run — no changes will be made.\n"
        puts "Backup directory: #{date_dir}\n"
        puts "Tool backups:"
        BACKUP_TOOLS.each do |name, bin|
          puts "  #{bin} backup --session-id 0"
        end
        puts "\nApp data copies:"
        APP_DATA_FILES.each do |filename|
          src = APP_SUPPORT_DIR / filename
          dst_name = "galaxy-app-#{filename}"
          if File.exists?(src)
            puts "  #{src} → #{date_dir}/#{dst_name}"
          else
            puts(
              "  #{src} → #{date_dir}/#{dst_name}" \
              " (skip: not found)"
            )
          end
        end
        return
      end

      Dir.mkdir_p(date_dir) unless Dir.exists?(date_dir)

      # Back up each sub-tool database
      failures = [] of String
      BACKUP_TOOLS.each do |name, bin|
        unless File.exists?(bin)
          STDERR.puts(
            "  ✗ #{name}: binary not found " \
            "(#{bin})"
          )
          failures << name
          next
        end

        stderr_io = IO::Memory.new
        status = Process.run(
          bin.to_s,
          args: ["backup", "--session-id", "0"],
          output: Process::Redirect::Inherit,
          error: stderr_io,
        )

        if status.success?
          puts "  ✓ #{name}"
        else
          err = stderr_io.to_s.strip
          STDERR.puts "  ✗ #{name}: backup failed"
          STDERR.puts "    #{err}" unless err.empty?
          failures << name
        end
      end

      # Copy Galaxy.app data files
      app_copied = 0
      APP_DATA_FILES.each do |filename|
        src = APP_SUPPORT_DIR / filename
        next unless File.exists?(src)

        dst = date_dir / "galaxy-app-#{filename}"
        begin
          File.copy(src, dst)
          app_copied += 1
        rescue ex
          STDERR.puts(
            "  ✗ app data: #{filename} " \
            "(#{ex.message})"
          )
          failures << "app:#{filename}"
        end
      end

      # Summary
      tool_count = BACKUP_TOOLS.size - failures
        .count { |f| !f.starts_with?("app:") }
      puts(
        "\nBackup complete: #{tool_count}/" \
        "#{BACKUP_TOOLS.size} tools, " \
        "#{app_copied} app files"
      )
      if failures.any?
        puts(
          "  Failures: #{failures.join(", ")}"
        )
        exit(1)
      end
    end

    private def self.backups_list
      config = SharedConfig.load
      backup_dir = config.effective_backup_path
      retention = config.backups.retention_days

      unless Dir.exists?(backup_dir)
        puts "No backups found."
        puts "  Backup directory: #{backup_dir}"
        return
      end

      # Collect date directories (YYYY-MM-DD pattern)
      date_dirs = Dir.children(backup_dir)
        .select { |d|
          d.matches?(/^\d{4}-\d{2}-\d{2}$/) &&
            Dir.exists?(backup_dir / d)
        }
        .sort
        .reverse

      if date_dirs.empty?
        puts "No backups found."
        puts "  Backup directory: #{backup_dir}"
        return
      end

      puts(
        "Backups (retention: " \
        "#{retention} days)\n"
      )

      total_files = 0
      total_size : Int64 = 0_i64

      date_dirs.each do |date|
        dir = backup_dir / date
        files = Dir.children(dir)
          .select { |f|
            File.file?(dir / f)
          }
          .sort

        next if files.empty?

        puts "  #{date}/"
        files.each do |f|
          file_path = dir / f
          size = File.size(file_path)
          total_size += size
          total_files += 1
          puts(
            "    #{f} " \
            "(#{format_size(size)})"
          )
        end
      end

      puts(
        "\n#{total_files} files, " \
        "#{format_size(total_size)} total"
      )
    end

    private def self.backups_prune
      config = SharedConfig.load
      backup_dir = config.effective_backup_path
      retention = config.backups.retention_days

      unless config.backups.enabled
        puts "Backups are disabled."
        return
      end

      # Call each tool's backup --prune-only
      BACKUP_TOOLS.each do |name, bin|
        next unless File.exists?(bin)

        stderr_io = IO::Memory.new
        status = Process.run(
          bin.to_s,
          args: ["backup", "--prune-only"],
          output: Process::Redirect::Inherit,
          error: stderr_io,
        )

        if status.success?
          puts "  ✓ #{name}: pruned"
        else
          err = stderr_io.to_s.strip
          STDERR.puts(
            "  ✗ #{name}: prune failed"
          )
          STDERR.puts(
            "    #{err}"
          ) unless err.empty?
        end
      end

      # Prune stale date directories that may still
      # contain only app data .json files (not handled
      # by sub-tool prune commands).
      prune_stale_date_dirs(backup_dir, retention)

      puts "\nPrune complete."
    end

    private def self.prune_stale_date_dirs(
      backup_dir : Path,
      retention_days : Int32,
    )
      return unless Dir.exists?(backup_dir)

      cutoff = Time.local - retention_days.days

      Dir.children(backup_dir).each do |entry|
        next unless entry.matches?(
                      /^\d{4}-\d{2}-\d{2}$/,
                    )

        dir_path = backup_dir / entry
        next unless Dir.exists?(dir_path)

        begin
          date = Time.parse(
            entry, "%Y-%m-%d", Time::Location::UTC
          )
          if date < cutoff
            FileUtils.rm_rf(dir_path.to_s)
          end
        rescue Time::Format::Error
          # Skip directories that look like dates but
          # aren't valid
        end
      end
    end

    private def self.format_size(bytes : Int64) : String
      if bytes < 1024
        "#{bytes} B"
      elsif bytes < 1024 * 1024
        "%.1f KB" % (bytes / 1024.0)
      else
        "%.1f MB" % (bytes / (1024.0 * 1024.0))
      end
    end

    # --- Update command ---

    private def self.show_update_help
      puts <<-HELP
      galaxy update - Update to the latest version

      Usage:
        galaxy update           Update to latest version
        galaxy update preview   Preview update without making changes
        galaxy update force     Reinstall latest (even if up-to-date)
        galaxy update help      Show this help

      The update downloads the latest release from GitHub, verifies the
      checksum, and replaces the current binary.

      Update script: https://raw.githubusercontent.com/kellyredding/galaxy/main/tools/galaxy/scripts/update.sh
      HELP
    end
  end
end
