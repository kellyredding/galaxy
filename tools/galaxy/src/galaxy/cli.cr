require "option_parser"
require "uri"

module Galaxy
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
          STDERR.puts "Run 'galaxy --help' for usage"
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

      # No args: open Galaxy.app with new session
      if positional_args.empty?
        open_session
        return
      end

      # First positional arg is command
      command = positional_args.first
      rest = positional_args[1..]? || [] of String

      case command
      when "update"
        handle_update_command(rest)
      when "version"
        puts VERSION
      when "help"
        puts parser
      else
        STDERR.puts "Error: Unknown command '#{command}'"
        STDERR.puts "Run 'galaxy --help' for usage"
        exit(1)
      end
    end

    private def self.build_banner : String
      <<-BANNER
      galaxy - Launch Galaxy sessions from the terminal

      Usage: galaxy [command] [options]

      Commands:
        (none)              Open Galaxy.app, create session in current directory
        update              Update to latest version
        update preview      Preview update without changes
        update force        Reinstall latest version
        version             Show version
        help                Show this help

      Options:
        -h, --help          Show this help
        -v, --version       Show version

      Examples:
        cd ~/projects/my-app && galaxy    Start session in project directory
        galaxy version                    Check installed version
        galaxy update                     Update to latest release
      BANNER
    end

    # Opens Galaxy.app via URL scheme with current directory
    def self.open_session
      path = Dir.current
      encoded_path = URI.encode_path(path)
      url = "#{URL_SCHEME}://new-session?path=#{encoded_path}"

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

    private def self.command_exists?(cmd : String) : Bool
      Process.run("which", args: [cmd], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
    end

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
