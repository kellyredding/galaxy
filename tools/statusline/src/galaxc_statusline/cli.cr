require "option_parser"

module GalaxcStatusline
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
          STDERR.puts "Run 'galaxc-statusline --help' for usage"
          exit(1)
        end
      end

      # Parse and collect positional args
      positional_args = [] of String
      parser.unknown_args { |a| positional_args = a }

      # If first arg is a subcommand, don't parse global flags after it
      # This allows "config --help" to work correctly
      first_positional_idx = args.index { |a| !a.starts_with?("-") }
      if first_positional_idx && first_positional_idx > 0
        # Parse only flags before the subcommand
        parser.parse(args[0...first_positional_idx])
        positional_args = args[first_positional_idx..]
      elsif first_positional_idx == 0
        # No flags before subcommand, just use as positional
        positional_args = args
      else
        # All flags, no positional args
        parser.parse(args)
      end

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
      when "version"
        puts VERSION
      when "help"
        puts parser
      else
        STDERR.puts "Error: Unknown command '#{command}'"
        STDERR.puts "Run 'galaxc-statusline --help' for usage"
        exit(1)
      end
    end

    private def self.build_banner : String
      <<-BANNER
      galaxc-statusline - Customizable status line for Claude Code

      Usage: galaxc-statusline [command] [options]

      Commands:
        render              Render status line (reads JSON from stdin)
        config              Show current configuration
        config --help       Configuration documentation
        config set KEY VAL  Set a configuration value
        config get KEY      Get a configuration value
        config reset        Reset to defaults
        config path         Show config file location
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
      when "--help", "-h"
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
        STDERR.puts "Run 'galaxc-statusline config --help' for usage"
        exit(1)
      end
    end

    private def self.show_config_help
      puts <<-HELP
      galaxc-statusline config - Manage status line configuration

      USAGE:
        galaxc-statusline config                    Show current configuration
        galaxc-statusline config set KEY VALUE      Set a configuration value
        galaxc-statusline config get KEY            Get a configuration value
        galaxc-statusline config reset              Reset to defaults
        galaxc-statusline config path               Show config file location

      CONFIGURATION FILE:
        ~/.claude/galaxc/statusline/config.json

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
          layout.context_bar_min_width   Min bar width (default: 10)
          layout.context_bar_max_width   Max bar width (default: 20)
          layout.show_cost               Show cost (default: true)
          layout.show_model              Show model (default: true)
          layout.directory_style         full, smart, basename, short (default: smart)

      EXAMPLES:
        galaxc-statusline config set branch_style arrows
        galaxc-statusline config set context_thresholds.warning 50
        galaxc-statusline config set colors.dirty red
        galaxc-statusline config get branch_style
        galaxc-statusline config reset
      HELP
    end

    private def self.config_set(args : Array(String))
      if args.size < 2
        STDERR.puts "Usage: galaxc-statusline config set KEY VALUE"
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
        STDERR.puts "Usage: galaxc-statusline config get KEY"
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
  end
end
