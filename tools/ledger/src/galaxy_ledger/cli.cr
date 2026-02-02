require "option_parser"

module GalaxyLedger
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
          STDERR.puts "Run 'galaxy-ledger --help' for usage"
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
        puts "galaxy-ledger #{VERSION}"
        return
      end

      # No args: show help
      if positional_args.empty?
        puts parser
        return
      end

      # First positional arg is command
      command = positional_args.first
      rest = positional_args[1..]? || [] of String

      case command
      when "config"
        handle_config_command(rest)
      when "session"
        handle_session_command(rest)
      when "on-startup"
        handle_on_startup_command(rest)
      when "on-stop"
        handle_on_stop_command(rest)
      when "on-session-start"
        handle_on_session_start_command(rest)
      when "version"
        puts "galaxy-ledger #{VERSION}"
      when "help"
        puts parser
      else
        STDERR.puts "Error: Unknown command '#{command}'"
        STDERR.puts "Run 'galaxy-ledger --help' for usage"
        exit(1)
      end
    end

    private def self.build_banner : String
      <<-BANNER
      galaxy-ledger - Continuous context management for Claude Code

      Usage: galaxy-ledger [command] [options]

      Commands:
        config              Show current configuration
        config help         Configuration documentation
        config set KEY VAL  Set a configuration value
        config get KEY      Get a configuration value
        config reset        Reset to defaults
        config path         Show config file location
        session list        List all sessions
        session show ID     Show session details
        session remove ID   Remove session and purge database entries
        on-startup          Handle SessionStart(startup) hook
        version             Show version
        help                Show this help

      Hook Commands (called by Claude Code hooks):
        on-startup          Fresh session startup (ledger awareness)
        on-stop             Capture last exchange, check thresholds
        on-session-start    Restore context after clear/compact
      BANNER
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
        STDERR.puts "Run 'galaxy-ledger config help' for usage"
        exit(1)
      end
    end

    private def self.show_config_help
      puts <<-HELP
      galaxy-ledger config - Manage ledger configuration

      USAGE:
        galaxy-ledger config                    Show current configuration
        galaxy-ledger config help               Configuration documentation
        galaxy-ledger config set KEY VALUE      Set a configuration value
        galaxy-ledger config get KEY            Get a configuration value
        galaxy-ledger config reset              Reset to defaults
        galaxy-ledger config path               Show config file location

      CONFIGURATION FILE:
        ~/.claude/galaxy/ledger/config.json

      AVAILABLE SETTINGS:

        thresholds.*                 Context percentage thresholds
          thresholds.warning         Warning threshold (default: 70)
          thresholds.critical        Critical threshold (default: 85)

        warnings.*                   Warning display settings
          warnings.at_warning_threshold   Show warning at warning % (default: true)
          warnings.at_critical_threshold  Show critical at critical % (default: true)

        extraction.*                 Learning extraction settings
          extraction.on_stop              Extract learnings after responses (default: true)
          extraction.on_guideline_read    Extract from guideline files (default: true)

        storage.*                    Storage settings
          storage.postgres_enabled        Use PostgreSQL + pgvector (default: false)
          storage.postgres_host_port      Host port for Postgres (default: 5433)
          storage.embeddings_enabled      Generate embeddings (default: false)
          storage.openai_api_key_env_var  Env var for OpenAI key (default: GALAXY_OPENAI_API_KEY)

        buffer.*                     Buffer settings
          buffer.flush_threshold          Entries before flush (default: 50)
          buffer.flush_interval_seconds   Max seconds before flush (default: 300)

        restoration.*                Context restoration settings
          restoration.max_essential_tokens  Token budget for essentials (default: 2000)

      EXAMPLES:
        galaxy-ledger config set thresholds.warning 75
        galaxy-ledger config set storage.postgres_enabled true
        galaxy-ledger config get thresholds.warning
        galaxy-ledger config reset
      HELP
    end

    private def self.config_set(args : Array(String))
      if args.size < 2
        STDERR.puts "Usage: galaxy-ledger config set KEY VALUE"
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
        STDERR.puts "Usage: galaxy-ledger config get KEY"
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

    private def self.handle_session_command(args : Array(String))
      if args.empty?
        show_session_help
        return
      end

      subcommand = args[0]
      rest = args[1..]? || [] of String

      case subcommand
      when "list"
        session_list
      when "show"
        session_show(rest)
      when "remove"
        session_remove(rest)
      when "help"
        show_session_help
      else
        STDERR.puts "Error: Unknown session command '#{subcommand}'"
        STDERR.puts "Run 'galaxy-ledger session help' for usage"
        exit(1)
      end
    end

    private def self.show_session_help
      puts <<-HELP
      galaxy-ledger session - Manage sessions

      USAGE:
        galaxy-ledger session list              List all sessions
        galaxy-ledger session show SESSION_ID   Show session details
        galaxy-ledger session remove SESSION_ID Remove session completely
        galaxy-ledger session help              Show this help

      DESCRIPTION:
        Sessions are stored in ~/.claude/galaxy/sessions/{session_id}/

        Each session folder contains:
          - context-status.json     Context percentage (from statusline)
          - ledger_buffer.jsonl     Buffered entries before flush
          - ledger_last-exchange.json  Last user/assistant exchange

      REMOVE BEHAVIOR:
        The 'remove' command completely removes a session:
          - Deletes the session folder and all its files
          - Purges entries from SQLite database
          - Purges entries from PostgreSQL (if enabled)

      EXAMPLES:
        galaxy-ledger session list
        galaxy-ledger session show abc123-def456
        galaxy-ledger session remove abc123-def456
      HELP
    end

    private def self.session_list
      sessions = Session.list

      if sessions.empty?
        puts "No sessions found."
        puts "  Sessions directory: #{SESSIONS_DIR}"
        return
      end

      puts "Sessions (#{sessions.size} total):"
      puts ""

      sessions.each do |session|
        # Format: SESSION_ID | 72% | 3 files | 2.5 KB | 5 min ago
        parts = [] of String
        parts << session.session_id

        if pct = session.context_percentage
          parts << "#{pct.round.to_i}%"
        end

        parts << "#{session.files.size} files"
        parts << format_size(session.total_size)
        parts << format_time_ago(session.last_modified)

        puts "  #{parts.join(" | ")}"
      end
    end

    private def self.session_show(args : Array(String))
      if args.empty?
        STDERR.puts "Usage: galaxy-ledger session show SESSION_ID"
        exit(1)
      end

      session_id = args[0]
      session = Session.show(session_id)

      unless session
        STDERR.puts "Error: Session not found: #{session_id}"
        STDERR.puts "  Path: #{SESSIONS_DIR / session_id}"
        exit(1)
      end

      puts "Session: #{session.session_id}"
      puts "  Path: #{session.path}"
      puts "  Last modified: #{format_time_ago(session.last_modified)}"
      puts "  Total size: #{format_size(session.total_size)}"
      puts ""
      puts "Files:"
      session.files.each do |file|
        file_path = session.path / file
        size = File.size(file_path)
        puts "  #{file} (#{format_size(size)})"
      end
      puts ""
      puts "Status:"
      puts "  Context status: #{session.has_context_status ? "yes" : "no"}"
      if session.has_context_status && (pct = session.context_percentage)
        puts "    Percentage: #{pct.round(1)}%"
      end
      puts "  Buffer: #{session.has_buffer ? "yes" : "no"}"
      puts "  Last exchange: #{session.has_last_exchange ? "yes" : "no"}"
    end

    private def self.session_remove(args : Array(String))
      if args.empty?
        STDERR.puts "Usage: galaxy-ledger session remove SESSION_ID"
        exit(1)
      end

      session_id = args[0]

      # Check if session exists
      unless Session.exists?(session_id)
        STDERR.puts "Error: Session not found: #{session_id}"
        STDERR.puts "  Path: #{SESSIONS_DIR / session_id}"
        exit(1)
      end

      result = Session.remove(session_id)

      puts "Removed session: #{session_id}"
      puts "  Folder removed: #{result.folder_removed ? "yes" : "no"}"
      puts "  SQLite purged: #{result.sqlite_purged ? "yes" : "no (not implemented yet)"}"
      if Config.load.storage.postgres_enabled
        puts "  PostgreSQL purged: #{result.postgres_purged ? "yes" : "no (not implemented yet)"}"
      end
    end

    private def self.format_size(bytes : Int64) : String
      if bytes < 1024
        "#{bytes} B"
      elsif bytes < 1024 * 1024
        "#{(bytes / 1024.0).round(1)} KB"
      else
        "#{(bytes / (1024.0 * 1024.0)).round(1)} MB"
      end
    end

    private def self.format_time_ago(time : Time) : String
      diff = Time.utc - time
      seconds = diff.total_seconds.to_i

      if seconds < 60
        "#{seconds}s ago"
      elsif seconds < 3600
        "#{seconds // 60}m ago"
      elsif seconds < 86400
        "#{seconds // 3600}h ago"
      else
        "#{seconds // 86400}d ago"
      end
    end

    private def self.handle_on_startup_command(args : Array(String))
      handler = Hooks::OnStartup.new
      handler.run
    end

    private def self.handle_on_stop_command(args : Array(String))
      handler = Hooks::OnStop.new
      handler.run
    end

    private def self.handle_on_session_start_command(args : Array(String))
      handler = Hooks::OnSessionStart.new
      handler.run
    end
  end
end
