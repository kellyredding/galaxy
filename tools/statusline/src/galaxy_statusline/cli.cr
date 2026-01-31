require "option_parser"

module GalaxyStatusline
  class CLI
    def self.run(args : Array(String))
      show_help_flag = false
      show_version_flag = false

      parser = OptionParser.new do |p|
        p.banner = build_banner

        p.separator ""
        p.separator "Options:"

        p.on("-h", "--help", "Show this help") { show_help_flag = true }
        p.on("-v", "--version", "Show version") { show_version_flag = true }

        p.invalid_option do |flag|
          STDERR.puts "Error: Unknown flag '#{flag}'"
          STDERR.puts "Run 'galaxy-statusline --help' for usage"
          exit(1)
        end
      end

      # Parse and collect positional args
      positional_args = [] of String
      parser.unknown_args { |a| positional_args = a }
      parser.parse(args)

      # Handle help/version flags
      if show_help_flag
        puts parser
        return
      end

      if show_version_flag
        puts VERSION
        return
      end

      # No args: auto-detect stdin or show help
      if positional_args.empty?
        if stdin_has_data?
          render_status_line
        else
          puts parser
        end
        return
      end

      # First positional arg is command
      command = positional_args.first
      rest = positional_args[1..]? || [] of String

      case command
      when "render"
        render_status_line
      when "config"
        handle_config_command(rest)
      when "update"
        handle_update_command(rest)
      when "version"
        puts VERSION
      when "help"
        puts parser
      else
        STDERR.puts "Error: Unknown command '#{command}'"
        STDERR.puts "Run 'galaxy-statusline --help' for usage"
        exit(1)
      end
    end

    private def self.build_banner : String
      <<-BANNER
      galaxy-statusline - Customizable status line for Claude Code

      Usage: galaxy-statusline [command] [options]

      Commands:
        render              Render status line (reads JSON from stdin)
        config              Show current configuration
        config help         Configuration documentation
        config set KEY VAL  Set a configuration value
        config get KEY      Get a configuration value
        config reset        Reset to defaults
        config path         Show config file location
        update              Update to latest version
        update preview      Preview update without changes
        update force        Reinstall latest version
        version             Show version
        help                Show this help

      If no command is given:
        - With stdin data: renders status line (implicit 'render')
        - Without stdin: shows this help
      BANNER
    end

    private def self.stdin_has_data? : Bool
      # Check if stdin is a TTY (interactive) or has data piped
      !STDIN.tty?
    end

    private def self.render_status_line
      begin
        input = STDIN.gets_to_end

        if input.empty?
          STDERR.puts "Error: No input received on stdin"
          exit(1)
        end

        claude_input = ClaudeInput.parse(input)
        config = Config.load

        renderer = Renderer.new(claude_input, config)
        puts renderer.render
      rescue ex : JSON::ParseException
        STDERR.puts "Error: Invalid JSON input - #{ex.message}"
        exit(1)
      rescue ex
        STDERR.puts "Error: #{ex.message}"
        exit(1)
      end
    end

    private def self.handle_config_command(args : Array(String))
      if args.empty?
        # Show current config
        config = Config.load
        puts config.to_pretty_json
        return
      end

      subcommand = args[0]
      rest = args[1..]? || [] of String

      case subcommand
      when "help"
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
        STDERR.puts "Error: Unknown config command '#{subcommand}'"
        STDERR.puts "Run 'galaxy-statusline config help' for usage"
        exit(1)
      end
    end

    private def self.show_config_help
      puts <<-HELP
      galaxy-statusline config - Manage status line configuration

      USAGE:
        galaxy-statusline config                    Show current configuration
        galaxy-statusline config help               Configuration documentation
        galaxy-statusline config set KEY VALUE      Set a configuration value
        galaxy-statusline config get KEY            Get a configuration value
        galaxy-statusline config reset              Reset to defaults
        galaxy-statusline config path               Show config file location

      CONFIGURATION FILE:
        ~/.claude/galaxy/statusline/config.json

      AVAILABLE SETTINGS:

        colors.*                     Color values for status line components
          Accepts: red, green, yellow, blue, magenta, cyan, white
                   bright_red, bright_green, etc.
                   bold:green, bold:yellow (with modifier)
                   "default" for terminal default

          colors.directory           Directory path (default: bold:yellow)
          colors.branch              Git branch name (default: green)
          colors.upstream_behind     Behind indicator (default: cyan)
          colors.upstream_ahead      Ahead indicator (default: cyan)
          colors.upstream_synced     In sync indicator (default: green)
          colors.dirty               Uncommitted changes (default: yellow)
          colors.staged              Staged changes (default: green)
          colors.stashed             Stashed changes (default: red)
          colors.context_normal      Context < warning (default: green)
          colors.context_warning     Context at warning (default: yellow)
          colors.context_critical    Context at critical (default: red)
          colors.model               Model name (default: default)
          colors.cost                Cost display (default: default)

        branch_style                 Git branch display format
          Accepts: symbolic, arrows, minimal

          "symbolic"  ->  [main=*]     = synced, < behind, > ahead, * dirty, + staged
          "arrows"    ->  main ↑2↓3    Exact ahead/behind counts
          "minimal"   ->  main*        Branch name, * if dirty

          Default: symbolic

        context_thresholds.*         Context bar color thresholds
          context_thresholds.warning     Yellow threshold (default: 60)
          context_thresholds.critical    Red threshold (default: 80)

        layout.*                     Display options
          layout.min_width               Collapse threshold (default: 60)
          layout.context_bar_min_width   Min context bar width (default: 25)
          layout.context_bar_max_width   Max context bar width (default: 50)
          layout.show_cost               Show cost (default: true)
          layout.show_model              Show model (default: true)
          layout.directory_style         full, smart, basename, short (default: smart)

      EXAMPLES:
        galaxy-statusline config set branch_style arrows
        galaxy-statusline config set context_thresholds.warning 50
        galaxy-statusline config set colors.dirty red
        galaxy-statusline config get branch_style
        galaxy-statusline config reset
      HELP
    end

    private def self.config_set(args : Array(String))
      if args.size < 2
        STDERR.puts "Usage: galaxy-statusline config set KEY VALUE"
        exit(1)
      end

      key = args[0]
      value = args[1]

      config = Config.load
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
        STDERR.puts "Usage: galaxy-statusline config get KEY"
        exit(1)
      end

      key = args[0]
      config = Config.load

      begin
        value = config.get(key)
        puts value
      rescue ex
        STDERR.puts "Error: #{ex.message}"
        exit(1)
      end
    end

    private def self.config_reset
      config = Config.default
      config.save
      puts "Configuration reset to defaults"
      puts "  #{CONFIG_FILE}"
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
      script_url = "https://raw.githubusercontent.com/kellyredding/galaxy/main/tools/statusline/scripts/update.sh"

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

    private def self.command_exists?(cmd : String) : Bool
      Process.run("which", args: [cmd], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
    end

    private def self.show_update_help
      puts <<-HELP
      galaxy-statusline update - Update to the latest version

      Usage:
        galaxy-statusline update           Update to latest version
        galaxy-statusline update preview   Preview update without making changes
        galaxy-statusline update force     Reinstall latest (even if up-to-date)
        galaxy-statusline update help      Show this help

      The update downloads the latest release from GitHub, verifies the
      checksum, and replaces the current binary.

      Update script: https://raw.githubusercontent.com/kellyredding/galaxy/main/tools/statusline/scripts/update.sh
      HELP
    end
  end
end
