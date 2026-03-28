require "option_parser"

module GalaxyLedger
  class CLI
    def self.run(args : Array(String))
      show_help_flag = false
      show_version_flag = false

      # Manually extract -h/-v/--help/--version from the start of args only
      # This allows subcommands to handle their own flags
      remaining_args = args.dup

      # Check for help/version flags at the start
      if remaining_args.any?
        first_arg = remaining_args.first
        case first_arg
        when "-h", "--help"
          show_help_flag = true
          remaining_args.shift
        when "-v", "--version"
          show_version_flag = true
          remaining_args.shift
        end
      end

      parser = OptionParser.new do |p|
        p.banner = build_banner

        p.separator ""
        p.separator "Options:"

        p.on("-h", "--help", "Show this help") { }
        p.on("-v", "--version", "Show version") { }
      end

      # positional_args are all remaining args after extracting top-level flags
      positional_args = remaining_args

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

      # Skip hooks early when GALAXY_SKIP_HOOKS is set (prevents recursion
      # from extraction subprocesses).  Drain stdin first so the parent
      # process's copy fiber can complete without a Broken pipe error.
      if command.starts_with?("on-") && ENV["GALAXY_SKIP_HOOKS"]? == "1"
        STDIN.gets_to_end rescue nil
        return
      end

      case command
      when "config"
        handle_config_command(rest)
      when "search"
        handle_search_command(rest)
      when "list-entries"
        handle_list_entries_command(rest)
      when "add"
        handle_add_command(rest)
      when "on-startup"
        handle_on_startup_command(rest)
      when "on-stop"
        handle_on_stop_command(rest)
      when "on-session-end"
        handle_on_session_end_command(rest)
      when "on-clear"
        handle_on_clear_command(rest)
      when "on-compact"
        handle_on_compact_command(rest)
      when "on-resume"
        handle_on_resume_command(rest)
      when "on-post-tool-use"
        handle_on_post_tool_use_command(rest)
      when "on-user-prompt-submit"
        handle_on_user_prompt_submit_command(rest)
      when "install"
        handle_install_command(rest)
      when "uninstall"
        handle_uninstall_command(rest)
      when "extract-user"
        handle_extract_user_command(rest)
      when "extract-assistant"
        handle_extract_assistant_command(rest)
      when "list-files"
        handle_list_files_command(rest)
      when "update-session-metrics"
        handle_update_session_metrics_command(rest)
      when "publish"
        handle_publish_command(rest)
      when "sessions"
        handle_sessions_command(rest)
      when "resolve-session"
        handle_resolve_session_command(rest)
      when "session-identifiers"
        handle_session_identifiers_command(rest)
      when "spend"
        handle_spend_command(rest)
      when "prune"
        handle_prune_command(rest)
      when "backup"
        handle_backup_command(rest)
      when "suggest-name"
        handle_suggest_name_command(rest)
      when "session-name"
        handle_session_name_command(rest)
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
        search              Search entries using full-text search
        list-entries        List recent entries
        list-files          List session file access records
        add                 Add an entry (learning, decision, direction, etc.)
        spend               Show token and cost usage over time
        prune               Prune old session entries and files
        backup              Manage database backups
        config              Manage configuration
        suggest-name        Generate/improve session name via LLM one-shot
        session-name        Look up session name from transcript JSONL
        install             Install hooks and skills into Claude Code
        uninstall           Remove hooks and skills from Claude Code
        version             Show version
        help                Show this help

      Hook Commands (called by Claude Code hooks):
        on-startup          Fresh session startup (ledger awareness)
        on-resume           Restore context for resumed session
        on-clear            Restore context after /clear
        on-compact          Restore context after auto/manual compact
        on-stop             Capture last exchange, check thresholds
        on-session-end      Record session:ended timeline event
        on-post-tool-use    Track file operations with type detection
        on-user-prompt-submit  Capture user directions/preferences

      Session Metrics:
        update-session-metrics  Update session metrics from stdin JSON

      Event Publishing:
        publish                 Publish an event to Galaxy.app

      Session Data:
        sessions                Query session state as JSON
        resolve-session         Resolve PID or session identifier to ledger session ID
        session-identifiers     List session identifiers for a ledger session (JSON)

      Run 'galaxy-ledger <command> --help' for detailed command usage.
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
      when "help", "-h", "--help"
        show_config_help
      when "set"
        # Check for help on subcommand
        if rest.includes?("-h") || rest.includes?("--help")
          show_config_set_help
        else
          config_set(rest)
        end
      when "get"
        # Check for help on subcommand
        if rest.includes?("-h") || rest.includes?("--help")
          show_config_get_help
        else
          config_get(rest)
        end
      when "reset"
        if rest.includes?("-h") || rest.includes?("--help")
          show_config_reset_help
        else
          config_reset
        end
      when "path"
        if rest.includes?("-h") || rest.includes?("--help")
          show_config_path_help
        else
          puts CONFIG_FILE
        end
      else
        STDERR.puts "Error: Unknown config command '#{subcommand}'"
        STDERR.puts "Run 'galaxy-ledger config --help' for usage"
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

        restoration.*                Context restoration settings
          restoration.max_essential_tokens  Token budget for essentials (default: 2000)

      EXAMPLES:
        galaxy-ledger config set thresholds.warning 75
        galaxy-ledger config set storage.postgres_enabled true
        galaxy-ledger config get thresholds.warning
        galaxy-ledger config reset
      HELP
    end

    private def self.show_config_set_help
      puts <<-HELP
      galaxy-ledger config set - Set a configuration value

      USAGE:
        galaxy-ledger config set KEY VALUE

      ARGUMENTS:
        KEY     Configuration key using dot notation (e.g., thresholds.warning)
        VALUE   Value to set (type is inferred: integer, boolean, or string)

      EXAMPLES:
        galaxy-ledger config set thresholds.warning 75
        galaxy-ledger config set storage.postgres_enabled true
        galaxy-ledger config set storage.openai_api_key_env_var MY_KEY

      Run 'galaxy-ledger config --help' for all available settings.
      HELP
    end

    private def self.show_config_get_help
      puts <<-HELP
      galaxy-ledger config get - Get a configuration value

      USAGE:
        galaxy-ledger config get KEY

      ARGUMENTS:
        KEY     Configuration key using dot notation (e.g., thresholds.warning)

      EXAMPLES:
        galaxy-ledger config get thresholds.warning
        galaxy-ledger config get storage.postgres_enabled

      Run 'galaxy-ledger config --help' for all available settings.
      HELP
    end

    private def self.show_config_reset_help
      puts <<-HELP
      galaxy-ledger config reset - Reset configuration to defaults

      USAGE:
        galaxy-ledger config reset

      DESCRIPTION:
        Resets all configuration values to their defaults. This overwrites
        the config file at #{CONFIG_FILE}.
      HELP
    end

    private def self.show_config_path_help
      puts <<-HELP
      galaxy-ledger config path - Show config file location

      USAGE:
        galaxy-ledger config path

      DESCRIPTION:
        Prints the full path to the ledger configuration file.
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

    private def self.build_filter_summary(
      entry_type : String?,
      importance : String?,
      category : String?,
      session_id : String? = nil,
    ) : Array(String)
      filters = [] of String
      filters << "session=#{session_id[0, 8]}..." if session_id
      filters << "type=#{entry_type}" if entry_type
      filters << "importance=#{importance}" if importance
      filters << "category=#{category}" if category
      filters
    end

    # Resolve a --pid or --session value to a ledger_session_id via database lookup.
    # Exits with error if not found.
    private def self.resolve_pid_to_ledger_session_id(pid_str : String) : Int64
      pid = pid_str.to_i64?
      unless pid
        STDERR.puts "Error: invalid --pid value '#{pid_str}' (must be an integer)"
        exit(1)
      end

      ledger_session_id = Database.resolve_claude_pid(pid)
      unless ledger_session_id
        STDERR.puts "Error: no session found for PID #{pid}"
        exit(1)
      end

      ledger_session_id
    end

    private def self.resolve_session_to_ledger_session_id(session_identifier : String) : Int64
      ledger_session_id = Database.resolve_session_identifier(session_identifier)
      unless ledger_session_id
        STDERR.puts "Error: no session found for identifier '#{session_identifier}'"
        exit(1)
      end

      ledger_session_id
    end

    private def self.resolve_ledger_session_id_str(id_str : String) : Int64
      id = id_str.to_i64?
      unless id
        STDERR.puts "Error: invalid --ledger-session-id value '#{id_str}' (must be an integer)"
        exit(1)
      end

      id
    end

    private def self.output_entries_json(entries : Array(Database::StoredEntry))
      JSON.build(STDOUT, indent: "  ") do |json|
        json.object do
          json.field "entries" do
            json.array do
              entries.each do |entry|
                json.object do
                  json.field "id", entry.id
                  json.field "entry_type", entry.entry_type
                  json.field "source", entry.source
                  json.field "content", entry.content
                  json.field "importance", entry.importance
                  json.field "category", entry.category
                  json.field "keywords", entry.keywords
                  json.field "source_file", entry.source_file
                  json.field "ledger_session_id", entry.ledger_session_id
                  json.field "created_at", entry.created_at
                end
              end
            end
          end
        end
      end
      puts ""
    end

    private def self.truncate(text : String, max_length : Int32) : String
      if text.size <= max_length
        text.gsub("\n", "\\n")
      else
        text[0, max_length - 3].gsub("\n", "\\n") + "..."
      end
    end

    private def self.handle_search_command(args : Array(String))
      # Check for help flag first (only if it's a standalone argument, not a value)
      if args.empty? || args.first? == "-h" || args.first? == "--help"
        show_search_help
        return
      end

      # Parse options
      entry_type : String? = nil
      importance : String? = nil
      category : String? = nil
      session_id : String? = nil
      pid_str : String? = nil
      ledger_session_id_str : String? = nil
      prefix_match = true
      json_output = false
      query : String? = nil

      i = 0
      while i < args.size
        arg = args[i]
        if arg == "--query" && i + 1 < args.size
          query = args[i + 1]
          i += 2
        elsif arg == "--type" && i + 1 < args.size
          entry_type = args[i + 1]
          unless ENTRY_TYPES.includes?(entry_type)
            STDERR.puts "Error: Invalid type '#{entry_type}'"
            STDERR.puts "Valid types: #{ENTRY_TYPES.join(", ")}"
            exit(1)
          end
          i += 2
        elsif arg == "--importance" && i + 1 < args.size
          importance = args[i + 1]
          unless IMPORTANCE_LEVELS.includes?(importance)
            STDERR.puts "Error: Invalid importance '#{importance}'"
            STDERR.puts "Valid levels: #{IMPORTANCE_LEVELS.join(", ")}"
            exit(1)
          end
          i += 2
        elsif arg == "--category" && i + 1 < args.size
          category = args[i + 1]
          i += 2
        elsif arg == "--session" && i + 1 < args.size
          session_id = args[i + 1]
          i += 2
        elsif arg == "--pid" && i + 1 < args.size
          pid_str = args[i + 1]
          i += 2
        elsif arg == "--ledger-session-id" && i + 1 < args.size
          ledger_session_id_str = args[i + 1]
          i += 2
        elsif arg == "--json"
          json_output = true
          i += 1
        elsif arg == "--exact"
          prefix_match = false
          i += 1
        else
          # Unknown argument
          STDERR.puts "Error: Unknown option '#{arg}'"
          STDERR.puts "Run 'galaxy-ledger search --help' for usage"
          exit(1)
        end
      end

      unless query
        STDERR.puts "Error: --query is required"
        STDERR.puts "Run 'galaxy-ledger search --help' for usage"
        exit(1)
      end

      # Resolve --ledger-session-id, --pid, or --session to ledger_session_id
      ledger_session_id : Int64? = nil
      if lsid_str = ledger_session_id_str
        ledger_session_id = resolve_ledger_session_id_str(lsid_str)
      elsif ps = pid_str
        ledger_session_id = resolve_pid_to_ledger_session_id(ps)
      elsif sid = session_id
        ledger_session_id = resolve_session_to_ledger_session_id(sid)
      end

      entries = if lsid = ledger_session_id
                  Database.search_in_session(lsid, query, entry_type: entry_type, importance: importance, category: category, prefix_match: prefix_match)
                else
                  Database.search(query, entry_type: entry_type, importance: importance, category: category, prefix_match: prefix_match)
                end

      if json_output
        output_entries_json(entries)
        return
      end

      if entries.empty?
        puts "No results found for: #{query}"
        filters = build_filter_summary(entry_type, importance, category, session_id)
        puts "  Filters: #{filters.join(", ")}" if filters.any?
        return
      end

      puts "Search results for: #{query}"
      filters = build_filter_summary(entry_type, importance, category, session_id)
      puts "  Filters: #{filters.join(", ")}" if filters.any?
      puts "  Found: #{entries.size} entries"
      puts ""

      entries.each_with_index do |entry, idx|
        # Show category in header if present
        header = "[#{idx + 1}] #{entry.entry_type} (#{entry.importance})"
        header += " [#{entry.category}]" if entry.category
        puts header
        if source = entry.source
          puts "    Source: #{source}"
        end
        if source_file = entry.source_file
          puts "    File: #{source_file}"
        end
        puts "    Session: ##{entry.ledger_session_id}"
        puts "    Content: #{truncate(entry.content, 100)}"
        # Show keywords if present
        keywords = entry.keywords_array
        puts "    Keywords: #{keywords.join(", ")}" if keywords.any?
        puts "    Created: #{entry.created_at}"
        puts ""
      end
    end

    private def self.show_search_help
      puts <<-HELP
      galaxy-ledger search - Search ledger entries

      USAGE:
        galaxy-ledger search --query "QUERY" [options]

      REQUIRED:
        --query QUERY         The search query (supports prefix matching by default)
                              Searches across content, keywords, category, and source file

      OPTIONS:
        --pid PID             Scope search to session by Claude Code PID
        --session ID          Scope search to a specific session (backward compat)
        --ledger-session-id N Scope search by internal ledger session ID
        --type TYPE           Filter by entry type
        --importance LEVEL    Filter by importance (high, medium, low)
        --category CATEGORY   Filter by category (e.g., ruby-style, rspec, git-workflow)
        --exact               Disable prefix matching (exact word match only)
        --json                Output as JSON
        -h, --help            Show this help

      ENTRY TYPES:
        #{ENTRY_TYPES.join(", ")}

      EXAMPLES:
        galaxy-ledger search --query "JWT authentication"
        galaxy-ledger search --query "database" --type learning
        galaxy-ledger search --query "Redis" --importance high
        galaxy-ledger search --query "trailing" --category ruby-style
        galaxy-ledger search --query "trail"          # Finds "trailing" (prefix match)
        galaxy-ledger search --query "trail" --exact  # No match (exact only)
        galaxy-ledger search --query "--help"         # Search for literal "--help"
        galaxy-ledger search --query "auth" --session abc123  # Session-scoped search
        galaxy-ledger search --query "auth" --ledger-session-id 42
      HELP
    end

    private def self.handle_list_entries_command(args : Array(String))
      # Check for help flag first (only if it's a standalone argument, not a value)
      if args.first? == "-h" || args.first? == "--help"
        show_list_entries_help
        return
      end

      # Parse options
      limit = 20
      entry_type : String? = nil
      importance : String? = nil
      session_id : String? = nil
      pid_str : String? = nil
      ledger_session_id_str : String? = nil
      json_output = false

      i = 0
      while i < args.size
        arg = args[i]
        if arg == "--type" && i + 1 < args.size
          entry_type = args[i + 1]
          unless ENTRY_TYPES.includes?(entry_type)
            STDERR.puts "Error: Invalid type '#{entry_type}'"
            STDERR.puts "Valid types: #{ENTRY_TYPES.join(", ")}"
            exit(1)
          end
          i += 2
        elsif arg == "--importance" && i + 1 < args.size
          importance = args[i + 1]
          unless IMPORTANCE_LEVELS.includes?(importance)
            STDERR.puts "Error: Invalid importance '#{importance}'"
            STDERR.puts "Valid levels: #{IMPORTANCE_LEVELS.join(", ")}"
            exit(1)
          end
          i += 2
        elsif arg == "--session" && i + 1 < args.size
          session_id = args[i + 1]
          i += 2
        elsif arg == "--pid" && i + 1 < args.size
          pid_str = args[i + 1]
          i += 2
        elsif arg == "--ledger-session-id" && i + 1 < args.size
          ledger_session_id_str = args[i + 1]
          i += 2
        elsif arg == "--json"
          json_output = true
          i += 1
        elsif arg == "--limit" && i + 1 < args.size
          limit = args[i + 1].to_i? || 20
          i += 2
        elsif arg.to_i? && arg.to_i > 0
          limit = arg.to_i
          i += 1
        else
          i += 1
        end
      end

      # Resolve --ledger-session-id, --pid, or --session to ledger_session_id
      ledger_session_id : Int64? = nil
      if lsid_str = ledger_session_id_str
        ledger_session_id = resolve_ledger_session_id_str(lsid_str)
      elsif ps = pid_str
        ledger_session_id = resolve_pid_to_ledger_session_id(ps)
      elsif sid = session_id
        ledger_session_id = resolve_session_to_ledger_session_id(sid)
      end

      entries = Database.query_recent_filtered(limit, entry_type, importance, ledger_session_id: ledger_session_id)

      if json_output
        output_entries_json(entries)
        return
      end

      if entries.empty?
        puts "No entries in ledger."
        filters = build_filter_summary(entry_type, importance, nil, session_id)
        puts "  Filters: #{filters.join(", ")}" if filters.any?
        puts "  Database: #{Database.database_path}"
        return
      end

      total = Database.count
      header = "Recent ledger entries (showing #{entries.size}"
      header += " of #{total}" unless entry_type || importance || ledger_session_id
      header += "):"
      puts header
      filters = build_filter_summary(entry_type, importance, nil, session_id)
      puts "  Filters: #{filters.join(", ")}" if filters.any?
      puts ""

      entries.each_with_index do |entry, idx|
        # Show category in header if present
        header = "[#{idx + 1}] #{entry.entry_type} (#{entry.importance})"
        header += " [#{entry.category}]" if entry.category
        puts header
        if source = entry.source
          puts "    Source: #{source}"
        end
        if source_file = entry.source_file
          puts "    File: #{source_file}"
        end
        puts "    Session: ##{entry.ledger_session_id}"
        puts "    Content: #{truncate(entry.content, 100)}"
        # Show keywords if present
        keywords = entry.keywords_array
        puts "    Keywords: #{keywords.join(", ")}" if keywords.any?
        puts "    Created: #{entry.created_at}"
        puts ""
      end
    end

    private def self.show_list_entries_help
      puts <<-HELP
      galaxy-ledger list-entries - List recent ledger entries

      USAGE:
        galaxy-ledger list-entries [options]

      OPTIONS:
        --pid PID               Scope listing to session by Claude Code PID
        --session ID            Scope listing to a specific session (backward compat)
        --ledger-session-id N   Scope listing by internal ledger session ID
        --limit N               Number of entries to show (default: 20)
        --type TYPE             Filter by entry type
        --importance LEVEL      Filter by importance (high, medium, low)
        --json                  Output as JSON
        -h, --help              Show this help

      ENTRY TYPES:
        #{ENTRY_TYPES.join(", ")}

      EXAMPLES:
        galaxy-ledger list-entries
        galaxy-ledger list-entries --limit 50
        galaxy-ledger list-entries --type guideline
        galaxy-ledger list-entries --importance high
        galaxy-ledger list-entries --limit 10 --type learning --importance medium
        galaxy-ledger list-entries --session abc123                    # Session-scoped listing
        galaxy-ledger list-entries --session abc123 --type learning    # Session + type filter
        galaxy-ledger list-entries --json --ledger-session-id 42
      HELP
    end

    private def self.handle_list_files_command(args : Array(String))
      # Check for help flag first
      if args.first? == "-h" || args.first? == "--help"
        show_list_files_help
        return
      end

      # Parse options
      session_id : String? = nil
      pid_str : String? = nil
      ledger_session_id_str : String? = nil
      limit = 50
      json_output = false

      i = 0
      while i < args.size
        arg = args[i]
        if arg == "--session" && i + 1 < args.size
          session_id = args[i + 1]
          i += 2
        elsif arg == "--pid" && i + 1 < args.size
          pid_str = args[i + 1]
          i += 2
        elsif arg == "--ledger-session-id" && i + 1 < args.size
          ledger_session_id_str = args[i + 1]
          i += 2
        elsif arg == "--json"
          json_output = true
          i += 1
        elsif arg == "--limit" && i + 1 < args.size
          limit = args[i + 1].to_i? || 50
          i += 2
        else
          STDERR.puts "Error: Unknown option '#{arg}'"
          STDERR.puts "Run 'galaxy-ledger list-files --help' for usage"
          exit(1)
        end
      end

      # When --json is used without explicit --limit, fetch all files
      limit = Int32::MAX if json_output && !args.includes?("--limit")

      # Resolve --ledger-session-id, --pid, or --session to ledger_session_id
      ledger_session_id : Int64? = nil
      if lsid_str = ledger_session_id_str
        ledger_session_id = resolve_ledger_session_id_str(lsid_str)
      elsif ps = pid_str
        ledger_session_id = resolve_pid_to_ledger_session_id(ps)
      elsif sid = session_id
        ledger_session_id = resolve_session_to_ledger_session_id(sid)
      end

      unless ledger_session_id
        STDERR.puts "Error: --session, --pid, or --ledger-session-id is required"
        STDERR.puts "Run 'galaxy-ledger list-files --help' for usage"
        exit(1)
      end

      files = Database.session_files(ledger_session_id)

      if json_output
        JSON.build(STDOUT, indent: "  ") do |json|
          json.object do
            json.field "files" do
              json.array do
                files.each do |f|
                  json.object do
                    json.field "id", f.id
                    json.field "file_path", f.file_path
                    json.field "search_pattern", f.search_pattern
                    json.field "is_read", f.is_read
                    json.field "is_edited", f.is_edited
                    json.field "is_written", f.is_written
                    json.field "is_searched", f.is_searched
                    json.field "first_seen_at", f.first_seen_at
                    json.field "last_seen_at", f.last_seen_at
                    json.field "access_count", f.access_count
                    json.field "file_type", f.file_type
                  end
                end
              end
            end
          end
        end
        puts ""
        return
      end

      if files.empty?
        puts "No session files found for session ##{ledger_session_id}"
        return
      end

      display = files.size > limit ? files[0, limit] : files
      puts "Session files for session ##{ledger_session_id} (showing #{display.size}#{files.size > limit ? " of #{files.size}" : ""}):"
      puts ""

      display.each do |f|
        # Build operation flags
        ops = [] of String
        ops << "read" if f.is_read
        ops << "edited" if f.is_edited
        ops << "written" if f.is_written
        ops << "searched" if f.is_searched
        ops_str = ops.join(", ")

        # File path or search directory + pattern
        path_str = if f.is_searched && !f.search_pattern.empty?
                     "#{Hooks::Helpers.shorten_home_path(f.file_path)} (pattern: \"#{f.search_pattern}\")"
                   else
                     Hooks::Helpers.shorten_home_path(f.file_path)
                   end

        # Access info
        access_str = "#{f.access_count} access#{f.access_count == 1 ? "" : "es"}"
        time_str = f.last_seen_at ? ", last: #{f.last_seen_at}" : ""
        type_str = f.file_type == "other" ? "" : " [#{f.file_type}]"

        puts "  [#{ops_str}]  #{path_str}#{type_str}"
        puts "              (#{access_str}#{time_str})"
      end
    end

    private def self.show_list_files_help
      puts <<-HELP
      galaxy-ledger list-files - List session file access records

      USAGE:
        galaxy-ledger list-files --pid PID [options]
        galaxy-ledger list-files --session SESSION_ID [options]
        galaxy-ledger list-files --ledger-session-id N [options]

      REQUIRED (one of):
        --pid PID               Session by Claude Code process PID
        --session SESSION_ID    Session by identifier (backward compat)
        --ledger-session-id N   Session by internal ledger session ID

      OPTIONS:
        --limit N               Maximum files to show (default: 50, all with --json)
        --json                  Output as JSON
        -h, --help              Show this help

      OUTPUT:
        Shows each file with operation flags (read, edited, written, searched),
        the file path, access count, and last access timestamp.

      EXAMPLES:
        galaxy-ledger list-files --session abc123
        galaxy-ledger list-files --session abc123 --limit 10
        galaxy-ledger list-files --json --ledger-session-id 42
      HELP
    end

    private def self.handle_add_command(args : Array(String))
      # Check for help flag first (only if it's a standalone argument, not a value)
      if args.empty? || args.first? == "-h" || args.first? == "--help"
        show_add_help
        return
      end

      # Parse options
      entry_type : String? = nil
      content : String? = nil
      importance = "medium"
      session_id = "manual-#{Time.utc.to_unix}"

      i = 0
      while i < args.size
        arg = args[i]
        if arg == "--type" && i + 1 < args.size
          entry_type = args[i + 1]
          unless ENTRY_TYPES.includes?(entry_type)
            STDERR.puts "Error: Invalid type '#{entry_type}'"
            STDERR.puts "Valid types: #{ENTRY_TYPES.join(", ")}"
            exit(1)
          end
          i += 2
        elsif arg == "--content" && i + 1 < args.size
          content = args[i + 1]
          i += 2
        elsif arg == "--importance" && i + 1 < args.size
          importance = args[i + 1]
          unless IMPORTANCE_LEVELS.includes?(importance)
            STDERR.puts "Error: Invalid importance '#{importance}'"
            STDERR.puts "Valid levels: #{IMPORTANCE_LEVELS.join(", ")}"
            exit(1)
          end
          i += 2
        elsif arg == "--session" && i + 1 < args.size
          session_id = args[i + 1]
          i += 2
        else
          # Unknown argument
          STDERR.puts "Error: Unknown option '#{arg}'"
          STDERR.puts "Run 'galaxy-ledger add --help' for usage"
          exit(1)
        end
      end

      unless entry_type
        STDERR.puts "Error: --type is required"
        STDERR.puts "Run 'galaxy-ledger add --help' for usage"
        exit(1)
      end

      unless content
        STDERR.puts "Error: --content is required"
        STDERR.puts "Run 'galaxy-ledger add --help' for usage"
        exit(1)
      end

      # Ensure session record exists (FK constraint)
      ledger_session_id = Database.ensure_session(session_id)

      if ledger_session_id <= 0
        STDERR.puts "Error: failed to create or resolve session"
        exit(1)
      end

      # Create entry and insert directly into database
      entry = Entry.new(
        entry_type: entry_type,
        content: content,
        importance: importance,
        source: "user"
      )

      success = Database.insert(ledger_session_id, entry)

      if success
        puts "Added #{entry_type} to ledger"
        puts "  Session: #{session_id}"
        puts "  Importance: #{importance}"
        puts "  Content: #{truncate(content, 80)}"
      else
        # May be a duplicate
        puts "Entry already exists (duplicate content hash)"
      end
    end

    private def self.show_add_help
      puts <<-HELP
      galaxy-ledger add - Add an entry to the ledger

      USAGE:
        galaxy-ledger add --type TYPE --content "CONTENT" [options]

      REQUIRED:
        --type TYPE           Entry type (see ENTRY TYPES below)
        --content CONTENT     The content/text of the entry

      OPTIONS:
        --importance LEVEL    Importance level: high, medium, low (default: medium)
        --session SESSION_ID  Session ID (default: manual-{timestamp})
        -h, --help            Show this help

      ENTRY TYPES:
        learning              Key insight about the codebase
        decision              Choice made with rationale
        direction             Explicit instruction (always X, never Y)
        preference            Stated preference about style/approach
        discovery             Something learned during exploration
        guideline             Extracted guideline rule
        implementation_plan   Implementation plan context
        constraint            Limitation or requirement
        reference             URL/issue reference

      EXAMPLES:
        galaxy-ledger add --type learning --content "JWT tokens expire after 15 minutes"
        galaxy-ledger add --type decision --content "Using Redis for caching" --importance high
        galaxy-ledger add --type direction --content "Always use trailing commas"
        galaxy-ledger add --type learning --content "Test content" --session my-session-id
      HELP
    end

    private def self.handle_on_startup_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_on_startup_help
        return
      end
      handler = Hooks::OnStartup.new
      handler.run
    end

    private def self.show_on_startup_help
      puts <<-HELP
      galaxy-ledger on-startup - Handle SessionStart(startup) hook

      USAGE:
        galaxy-ledger on-startup

      DESCRIPTION:
        Called by Claude Code's SessionStart hook when a fresh session starts.
        This hook:
        - Registers session record in database with Claude Code PID
        - Injects ledger awareness prompt with PID-based lookup directives

      INPUT (stdin):
        JSON object with hook data:
        {
          "session_id": "abc123",
          "transcript_path": "/path/to/transcript.jsonl",
          "cwd": "/current/working/directory",
          "hook_event_name": "SessionStart",
          "source": "startup"
        }

      OUTPUT (stdout):
        JSON object with context to inject:
        {
          "systemMessage": "Ledger active │ New session",
          "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": "## Galaxy Ledger\\n..."
          }
        }

      HOOK CONFIGURATION:
        Add to ~/.claude/settings.json:
        {
          "hooks": {
            "SessionStart": [{
              "matcher": "startup",
              "hooks": [{
                "type": "command",
                "command": "galaxy-ledger on-startup",
                "timeout": 10
              }]
            }]
          }
        }
      HELP
    end

    private def self.handle_on_stop_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_on_stop_help
        return
      end
      handler = Hooks::OnStop.new
      handler.run
    end

    private def self.show_on_stop_help
      puts <<-HELP
      galaxy-ledger on-stop - Handle Stop hook

      USAGE:
        galaxy-ledger on-stop

      DESCRIPTION:
        Called by Claude Code's Stop hook after the agent finishes responding.
        This hook:
        - Captures the last exchange (user message + assistant response)
        - Checks context percentage thresholds
        - Shows warnings at 70% and 85% context usage
        - Spawns async extraction of learnings/decisions

      INPUT (stdin):
        JSON object with hook data:
        {
          "session_id": "abc123",
          "transcript_path": "/path/to/transcript.jsonl",
          "cwd": "/current/working/directory",
          "hook_event_name": "Stop",
          "stop_hook_active": false
        }

      OUTPUT (stdout):
        Optional warning message if context threshold exceeded.

      HOOK CONFIGURATION:
        Add to ~/.claude/settings.json:
        {
          "hooks": {
            "Stop": [{
              "hooks": [{
                "type": "command",
                "command": "galaxy-ledger on-stop",
                "timeout": 30
              }]
            }]
          }
        }
      HELP
    end

    private def self.handle_on_session_end_command(
      args : Array(String),
    )
      if args.first? == "-h" || args.first? == "--help"
        show_on_session_end_help
        return
      end
      handler = Hooks::OnSessionEnd.new
      handler.run
    end

    private def self.show_on_session_end_help
      puts <<-HELP
      galaxy-ledger on-session-end - Handle SessionEnd hook

      USAGE:
        galaxy-ledger on-session-end

      DESCRIPTION:
        Called by Claude Code's SessionEnd hook when the session
        exits. Records a single session:ended timeline event
        with final session metrics. This is the inverse of
        on-startup.

      INPUT (stdin):
        JSON object with hook data:
        {
          "session_id": "abc123",
          "cwd": "/current/working/directory",
          "hook_event_name": "SessionEnd"
        }

      HOOK CONFIGURATION:
        Add to ~/.claude/settings.json:
        {
          "hooks": {
            "SessionEnd": [{
              "hooks": [{
                "type": "command",
                "command": "galaxy-ledger on-session-end",
                "timeout": 10
              }]
            }]
          }
        }
      HELP
    end

    private def self.handle_on_clear_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_on_clear_help
        return
      end
      handler = Hooks::OnClear.new
      handler.run
    end

    private def self.show_on_clear_help
      puts <<-HELP
      galaxy-ledger on-clear - Handle SessionStart(clear) hook

      USAGE:
        galaxy-ledger on-clear

      DESCRIPTION:
        Called by Claude Code's SessionStart hook after /clear.
        This hook:
        - Resolves session via env var / PID / hook session_id
        - Queries tiered restoration data from SQLite
        - Builds systemMessage status line for user display
        - Returns additionalContext with full handoff markdown for agent restoration

      INPUT (stdin):
        JSON object with hook data:
        {
          "session_id": "abc123",
          "transcript_path": "/path/to/transcript.jsonl",
          "cwd": "/current/working/directory",
          "hook_event_name": "SessionStart",
          "source": "clear"
        }

      OUTPUT (stdout):
        JSON object with restored context:
        {
          "systemMessage": "Handoff │ 3 guidelines, 1 plan │ ...",
          "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": "## Session Context Handoff\\n..."
          }
        }

      HOOK CONFIGURATION:
        Add to ~/.claude/settings.json:
        {
          "hooks": {
            "SessionStart": [{
              "matcher": "clear",
              "hooks": [{
                "type": "command",
                "command": "galaxy-ledger on-clear",
                "timeout": 30
              }]
            }]
          }
        }
      HELP
    end

    private def self.handle_on_compact_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_on_compact_help
        return
      end
      handler = Hooks::OnCompact.new
      handler.run
    end

    private def self.show_on_compact_help
      puts <<-HELP
      galaxy-ledger on-compact - Handle SessionStart(compact) hook

      USAGE:
        galaxy-ledger on-compact

      DESCRIPTION:
        Called by Claude Code's SessionStart hook after auto/manual compact.
        This hook:
        - Resolves session via env var / PID / hook session_id
        - Queries tiered restoration data from SQLite
        - Builds systemMessage status line for user display
        - Returns additionalContext with full handoff markdown for agent restoration

      INPUT (stdin):
        JSON object with hook data:
        {
          "session_id": "abc123",
          "transcript_path": "/path/to/transcript.jsonl",
          "cwd": "/current/working/directory",
          "hook_event_name": "SessionStart",
          "source": "compact"
        }

      OUTPUT (stdout):
        JSON object with restored context:
        {
          "systemMessage": "Handoff │ 3 guidelines, 1 plan │ ...",
          "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": "## Session Context Handoff\\n..."
          }
        }

      HOOK CONFIGURATION:
        Add to ~/.claude/settings.json:
        {
          "hooks": {
            "SessionStart": [{
              "matcher": "compact",
              "hooks": [{
                "type": "command",
                "command": "galaxy-ledger on-compact",
                "timeout": 30
              }]
            }]
          }
        }
      HELP
    end

    private def self.handle_on_resume_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_on_resume_help
        return
      end
      handler = Hooks::OnResume.new
      handler.run
    end

    private def self.show_on_resume_help
      puts <<-HELP
      galaxy-ledger on-resume - Handle SessionStart(resume) hook

      USAGE:
        galaxy-ledger on-resume

      DESCRIPTION:
        Called by Claude Code's SessionStart hook when resuming a previous session.
        This hook:
        - Resolves original session via env var (preferred) or PID
        - Registers new hook session_id against the original session
        - Injects ledger awareness context with PID-based lookup directives
        - Includes condensed summary of accumulated session data

      INPUT (stdin):
        JSON object with hook data:
        {
          "session_id": "abc123",
          "transcript_path": "/path/to/transcript.jsonl",
          "cwd": "/current/working/directory",
          "hook_event_name": "SessionStart",
          "source": "resume"
        }

      OUTPUT (stdout):
        JSON object with awareness context:
        {
          "systemMessage": "Resumed │ 3 guidelines, 5 session files",
          "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": "## Galaxy Ledger\\n..."
          }
        }

      HOOK CONFIGURATION:
        Add to ~/.claude/settings.json:
        {
          "hooks": {
            "SessionStart": [{
              "matcher": "resume",
              "hooks": [{
                "type": "command",
                "command": "galaxy-ledger on-resume",
                "timeout": 30
              }]
            }]
          }
        }
      HELP
    end

    private def self.handle_on_post_tool_use_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_on_post_tool_use_help
        return
      end
      handler = Hooks::OnPostToolUse.new
      handler.run
    end

    private def self.show_on_post_tool_use_help
      puts <<-HELP
      galaxy-ledger on-post-tool-use - Handle PostToolUse hook

      USAGE:
        galaxy-ledger on-post-tool-use

      DESCRIPTION:
        Called by Claude Code's PostToolUse hook after a tool completes.
        This hook:
        - Tracks file operations (Read, Edit, Write, Glob, Grep)
        - Classifies files by type (guideline, test, source, config, etc.)
        - Detects artifacts for Write operations (delegates to galaxy-artifacts)

      INPUT (stdin):
        JSON object with hook data:
        {
          "session_id": "abc123",
          "transcript_path": "/path/to/transcript.jsonl",
          "cwd": "/current/working/directory",
          "hook_event_name": "PostToolUse",
          "tool_name": "Read|Edit|Write|Grep|Glob",
          "tool_input": {"file_path": "/path/to/file.rb"},
          "tool_result": "File contents or operation result"
        }

      OUTPUT (stdout):
        No output (async hook, non-blocking).

      FILE TRACKING:
        File operations (Read, Edit, Write, Glob, Grep) are tracked in the
        session_files table with automatic file type detection. File types
        (guideline, implementation_plan, test, script, doc, config, source,
        other) are classified by path conventions.

      HOOK CONFIGURATION:
        Add to ~/.claude/settings.json:
        {
          "hooks": {
            "PostToolUse": [{
              "matcher": "Edit|Write|Read|Grep|Glob",
              "hooks": [{
                "type": "command",
                "command": "galaxy-ledger on-post-tool-use",
                "async": true,
                "timeout": 10
              }]
            }]
          }
        }
      HELP
    end

    private def self.handle_on_user_prompt_submit_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_on_user_prompt_submit_help
        return
      end
      handler = Hooks::OnUserPromptSubmit.new
      handler.run
    end

    private def self.show_on_user_prompt_submit_help
      puts <<-HELP
      galaxy-ledger on-user-prompt-submit - Handle UserPromptSubmit hook

      USAGE:
        galaxy-ledger on-user-prompt-submit

      DESCRIPTION:
        Called by Claude Code's UserPromptSubmit hook when the user submits a prompt.
        This hook:
        - Captures user messages for potential direction extraction
        - Spawns async extraction process using Claude CLI
        - Runs async, non-blocking

      INPUT (stdin):
        JSON object with hook data:
        {
          "session_id": "abc123",
          "transcript_path": "/path/to/transcript.jsonl",
          "cwd": "/current/working/directory",
          "hook_event_name": "UserPromptSubmit",
          "prompt": "The user's message content"
        }

      OUTPUT (stdout):
        No output (async hook, non-blocking).

      BEHAVIOR:
        - Skips empty prompts
        - Skips very short prompts (<10 chars) like "yes", "ok", "continue"
        - Processes longer prompts through extraction
        - Extraction uses Claude CLI to classify and persist learnings

      ENTRY TYPES CREATED:
        - direction: User prompt (source: user, importance: medium)
          Note: Classified by extraction into specific types

      HOOK CONFIGURATION:
        Add to ~/.claude/settings.json:
        {
          "hooks": {
            "UserPromptSubmit": [{
              "hooks": [{
                "type": "command",
                "command": "galaxy-ledger on-user-prompt-submit",
                "async": true,
                "timeout": 10
              }]
            }]
          }
        }
      HELP
    end

    # ========================================
    # Hooks Management Commands
    # ========================================

    private def self.handle_install_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_install_help
        return
      end

      subcommand = args[0]? || ""

      case subcommand
      when "status"
        install_status
      when ""
        run_install
      else
        STDERR.puts "Error: Unknown install command '#{subcommand}'"
        STDERR.puts "Run 'galaxy-ledger install --help' for usage"
        exit(1)
      end
    end

    private def self.handle_uninstall_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_uninstall_help
        return
      end

      run_uninstall
    end

    private def self.show_install_help
      puts <<-HELP
      galaxy-ledger install - Install Galaxy Ledger into Claude Code

      USAGE:
        galaxy-ledger install           Install hooks and skills
        galaxy-ledger install status    Check installation status
        galaxy-ledger install --help    Show this help

      DESCRIPTION:
        Installs all Galaxy Ledger components into Claude Code:
        - Hooks: Registered in Claude Code's settings.json
        - Skills: SKILL.md files symlinked into Claude Code's discovery path

        Installation is idempotent — safe to run multiple times.

      WHAT GETS INSTALLED:
        Hooks (in #{SETTINGS_FILE}):
          - UserPromptSubmit (async): Captures user messages
          - PostToolUse (async): Tracks file operations
          - Stop: Captures last exchange, shows context warnings
          - SessionStart: Context restoration (startup, resume, clear, compact)

        Skills (symlinked to #{CLAUDE_SKILLS_DIR}):
          - handoff: Review and confirm context handoff after /clear

      SAFETY:
        Existing non-ledger hooks and skills are preserved.

      TESTING:
        To test without affecting your live configuration:
        export GALAXY_CLAUDE_CONFIG_DIR=/tmp/test-claude
        export GALAXY_DIR=/tmp/test-galaxy
        galaxy-ledger install
      HELP
    end

    private def self.show_uninstall_help
      puts <<-HELP
      galaxy-ledger uninstall - Remove Galaxy Ledger from Claude Code

      USAGE:
        galaxy-ledger uninstall
        galaxy-ledger uninstall --help

      DESCRIPTION:
        Removes all Galaxy Ledger components from Claude Code:
        - Hooks: Removed from Claude Code's settings.json
        - Skills: Symlinks and source files removed

        Non-ledger hooks and skills are preserved.

      SETTINGS FILE:
        #{SETTINGS_FILE}
        (Override with GALAXY_CLAUDE_CONFIG_DIR environment variable)
      HELP
    end

    private def self.run_install
      puts "Installing Galaxy Ledger..."
      puts "  Settings file: #{SETTINGS_FILE}"
      puts "  Skills directory: #{SKILLS_DIR}"

      result = InstallManager.install

      if result.hooks_ok
        puts ""
        puts "✅ Hooks installed successfully!"
        HooksManager::LEDGER_HOOKS.keys.each do |event|
          puts "  - #{event}"
        end
      else
        STDERR.puts ""
        STDERR.puts "❌ Failed to install hooks"
      end

      if result.skills_ok
        puts ""
        puts "✅ Skills installed successfully!"
        SkillsManager::LEDGER_SKILLS.each_key do |name|
          puts "  - #{name} → #{CLAUDE_SKILLS_DIR / name}"
        end
      else
        STDERR.puts ""
        STDERR.puts "❌ Failed to install skills"
      end

      if result.success?
        puts ""
        puts "Restart Claude Code for changes to take effect."
      else
        exit(1)
      end
    end

    private def self.run_uninstall
      puts "Uninstalling Galaxy Ledger..."

      result = InstallManager.uninstall

      if result.hooks_ok
        puts ""
        puts "✅ Hooks removed"
      else
        STDERR.puts ""
        STDERR.puts "❌ Failed to remove hooks"
      end

      if result.skills_ok
        puts "✅ Skills removed"
      else
        STDERR.puts "❌ Failed to remove skills"
      end

      if result.success?
        puts ""
        puts "Restart Claude Code for changes to take effect."
      else
        exit(1)
      end
    end

    private def self.install_status
      status = InstallManager.status

      puts "Galaxy Ledger Installation Status"
      puts "=================================="
      puts ""
      puts "Settings file: #{status.hooks.settings_path}"
      puts ""

      # Hooks status
      if status.hooks.installed
        puts "Hooks: ✅ All installed"
      elsif status.hooks.hook_events.empty?
        puts "Hooks: ❌ Not installed"
      else
        puts "Hooks: ⚠️  Partially installed (#{status.hooks.hook_events.size}/#{HooksManager::LEDGER_HOOKS.keys.size})"
      end

      HooksManager::LEDGER_HOOKS.keys.each do |event|
        if status.hooks.hook_events.includes?(event)
          puts "  ✅ #{event}"
        else
          puts "  ❌ #{event}"
        end
      end

      puts ""

      # Skills status
      if status.skills.installed
        puts "Skills: ✅ All installed"
      else
        puts "Skills: ❌ Not fully installed"
      end

      status.skills.skills.each do |skill|
        if skill.installed
          puts "  ✅ #{skill.name} → #{skill.symlink_path}"
        else
          puts "  ❌ #{skill.name}"
        end
      end

      puts ""

      if status.installed?
        puts "Overall: ✅ Fully installed"
      else
        puts "Overall: ❌ Not fully installed"
        puts ""
        puts "Run 'galaxy-ledger install' to install missing components."
      end
    end

    # ========================================
    # Extraction Commands (called by hooks)
    # ========================================

    private def self.handle_extract_user_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_extract_user_help
        return
      end

      # Parse args
      session_id : String? = nil
      i = 0
      while i < args.size
        arg = args[i]
        if arg == "--session" && i + 1 < args.size
          session_id = args[i + 1]
          i += 2
        else
          i += 1
        end
      end

      unless session_id
        STDERR.puts "Error: --session is required"
        exit(1)
      end

      # Resolve session_identifier to ledger_session_id
      ledger_session_id = Database.resolve_session_identifier(session_id)
      unless ledger_session_id
        STDERR.puts "Error: no session found for identifier '#{session_id}'"
        exit(1)
      end

      # Read prompt from stdin
      prompt = STDIN.gets_to_end

      if prompt.strip.empty?
        return # Nothing to extract
      end

      # Run extraction
      result = Extraction.extract_user_directions(prompt)

      # Write extracted entries directly to database
      if result.extractions.any?
        entries = result.extractions.select(&.valid?).map do |e|
          e.to_entry(source: "user")
        end
        inserted = Database.insert_many(ledger_session_id, entries)
        if inserted > 0
          STDERR.puts "[galaxy-ledger] Extracted #{inserted} user directions for session ##{ledger_session_id}"
        end
      end

      # Record one-shot usage
      if result.cost_usd > 0.0 || result.total_tokens > 0
        Database.record_oneshot_usage(ledger_session_id, result.cost_usd, result.total_tokens)
      end
    end

    private def self.show_extract_user_help
      puts <<-HELP
      galaxy-ledger extract-user - Extract directions from user prompt

      USAGE:
        galaxy-ledger extract-user --session SESSION_ID < prompt.txt

      DESCRIPTION:
        Called by hooks to extract directions, preferences, and constraints
        from a user prompt using Claude CLI.

        This is an internal command used by the UserPromptSubmit hook.
      HELP
    end

    # Exponential backoff delays (in seconds) for transcript reading.
    # Attempt 1: immediate, then 0.25s, 0.5s, 1.0s, 2.0s
    # Total worst case: ~3.75 seconds
    TRANSCRIPT_BACKOFF_DELAYS = [0.0, 0.25, 0.5, 1.0, 2.0]

    private def self.handle_extract_assistant_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_extract_assistant_help
        return
      end

      # Parse args
      session_id : String? = nil
      input_file : String? = nil
      transcript_path : String? = nil
      i = 0
      while i < args.size
        arg = args[i]
        if arg == "--session" && i + 1 < args.size
          session_id = args[i + 1]
          i += 2
        elsif arg == "--input-file" && i + 1 < args.size
          input_file = args[i + 1]
          i += 2
        elsif arg == "--transcript-path" && i + 1 < args.size
          transcript_path = args[i + 1]
          i += 2
        else
          i += 1
        end
      end

      unless session_id
        STDERR.puts "Error: --session is required"
        exit(1)
      end

      unless input_file || transcript_path
        STDERR.puts "Error: --input-file or --transcript-path is required"
        exit(1)
      end

      # Resolve session_identifier to ledger_session_id
      ledger_session_id = Database.resolve_session_identifier(session_id)
      unless ledger_session_id
        STDERR.puts "Error: no session found for identifier '#{session_id}'"
        exit(1)
      end

      # Get user_message and assistant_content from the appropriate source
      user_message : String = ""
      assistant_content : String = ""

      if tp = transcript_path
        # Transcript-based flow: read with exponential backoff
        user_message, assistant_content = read_transcript_with_backoff(tp, ledger_session_id)
      elsif inf = input_file
        # Input-file flow: direct read (backward compat / testing)
        user_message, assistant_content = read_input_file(inf)
      end

      if user_message.strip.empty? || assistant_content.strip.empty?
        return
      end

      # Run extraction and write results
      run_extraction_and_write(ledger_session_id, user_message, assistant_content)

      # Notify Galaxy.app to re-fetch session data (fire-and-forget).
      # This fires after both exchange capture and summary extraction
      # are complete, so the app gets the fully enriched data.
      EventPublisher.publish(
        ledger_session_id: ledger_session_id,
        event: "session.metrics",
      )
    end

    # Read transcript file with exponential backoff, waiting for a complete
    # exchange (user message + assistant response). Captures the last 3
    # exchanges and writes them as a JSON array to last_interaction.
    # Preserves summaries from previously-extracted exchanges by matching
    # on user_message content.
    private def self.read_transcript_with_backoff(
      transcript_path : String,
      ledger_session_id : Int64,
    ) : {String, String}
      user_message = ""
      assistant_content = ""

      # No point retrying if the file doesn't exist at all — it won't
      # appear between retries. The backoff is for partially-flushed files.
      return {user_message, assistant_content} unless File.exists?(transcript_path)

      TRANSCRIPT_BACKOFF_DELAYS.each_with_index do |delay, attempt|
        if delay > 0
          sleep (delay * 1000).to_i.milliseconds
        end

        entries = Transcript.parse(transcript_path)

        recent = Transcript.extract_recent_exchanges(entries, limit: 3)
        next if recent.empty?

        last = recent.last
        user_message = last.user_message
        last_exchange = Transcript.to_last_exchange(last)
        assistant_content = last_exchange.full_content

        if !assistant_content.strip.empty?
          exchanges = build_exchanges_with_preserved_summaries(
            recent: recent,
            ledger_session_id: ledger_session_id,
          )
          json = exchanges.to_pretty_json
          Database.update_session_last_interaction(ledger_session_id, json)
          return {user_message, assistant_content}
        end
      end

      # Even with incomplete data, write what we have to last_interaction
      unless user_message.strip.empty?
        entries = Transcript.parse(transcript_path)
        recent = Transcript.extract_recent_exchanges(entries, limit: 3)
        unless recent.empty?
          exchanges = build_exchanges_with_preserved_summaries(
            recent: recent,
            ledger_session_id: ledger_session_id,
          )
          json = exchanges.to_pretty_json
          Database.update_session_last_interaction(ledger_session_id, json)

          # Update return variables from the fresh parse so the caller
          # sees the actual data we just wrote, not stale loop values.
          last = recent.last
          user_message = last.user_message
          assistant_content = Transcript.to_last_exchange(last).full_content
        end
      end

      {user_message, assistant_content}
    end

    # Convert extracted exchanges to LastExchange objects, carrying forward
    # any existing summaries from the DB by matching on user_message.
    private def self.build_exchanges_with_preserved_summaries(
      recent : Array(Transcript::ExtractedExchange),
      ledger_session_id : Int64,
    ) : Array(Exchange::LastExchange)
      # Load existing exchanges from DB for summary preservation
      existing = begin
        session_record = Database.get_session_by_id(ledger_session_id)
        li_json = session_record.try(&.last_interaction)
        Exchange::LastExchange.from_json_flexible(li_json)
      rescue
        [] of Exchange::LastExchange
      end

      # Build a lookup of existing summaries by user_message
      summary_by_message = {} of String => Exchange::ExchangeSummary
      existing.each do |ex|
        if s = ex.summary
          summary_by_message[ex.user_message] = s
        end
      end

      # Convert extracted exchanges, carrying forward matched summaries
      recent.map do |extracted|
        exchange = Transcript.to_last_exchange(extracted)
        if preserved = summary_by_message[exchange.user_message]?
          Exchange::LastExchange.new(
            user_message: exchange.user_message,
            full_content: exchange.full_content,
            assistant_messages: exchange.assistant_messages,
            user_timestamp: exchange.user_timestamp,
            summary: preserved,
          )
        else
          exchange
        end
      end
    end

    # Read user_message and assistant_content from an input file (legacy/testing path)
    private def self.read_input_file(input_file : String) : {String, String}
      input_json = File.read(input_file)
      json = JSON.parse(input_json)
      user_message = json["user_message"]?.try(&.as_s?) || ""
      assistant_content = json["assistant_content"]?.try(&.as_s?) || ""

      # Clean up temp file
      File.delete(input_file) if File.exists?(input_file)

      {user_message, assistant_content}
    end

    # Run extraction via Claude CLI and write all results to DB
    private def self.run_extraction_and_write(
      ledger_session_id : Int64,
      user_message : String,
      assistant_content : String,
    )
      begin
        result = Extraction.extract_assistant_learnings(user_message, assistant_content)

        # Write extracted entries directly to database
        if result.extractions.any?
          entries = result.extractions.select(&.valid?).map do |e|
            e.to_entry(source: "assistant")
          end
          inserted = Database.insert_many(ledger_session_id, entries)
          if inserted > 0
            STDERR.puts "[galaxy-ledger] Extracted #{inserted} learnings for session ##{ledger_session_id}"
          end
        end

        # Update last interaction with summary if we got one.
        # Patches the summary onto the last element of the exchanges array.
        if summary = result.summary
          session_record = Database.get_session_by_id(ledger_session_id)
          if session_record && (li_json = session_record.last_interaction)
            begin
              exchanges = Exchange::LastExchange.from_json_flexible(li_json)
              unless exchanges.empty?
                last = exchanges.last
                updated = Exchange::LastExchange.new(
                  user_message: last.user_message,
                  full_content: last.full_content,
                  assistant_messages: last.assistant_messages,
                  user_timestamp: last.user_timestamp,
                  summary: summary,
                )
                exchanges[exchanges.size - 1] = updated
                Database.update_session_last_interaction(ledger_session_id, exchanges.to_pretty_json)
                STDERR.puts "[galaxy-ledger] Updated last interaction with summary"
              end
            rescue
              # Ignore parse errors on last_interaction
            end
          end
        end

        # Record one-shot usage
        if result.cost_usd > 0.0 || result.total_tokens > 0
          Database.record_oneshot_usage(ledger_session_id, result.cost_usd, result.total_tokens)
        end
      rescue ex
        STDERR.puts "[galaxy-ledger] Extract assistant error: #{ex.message}"
      end
    end

    private def self.show_extract_assistant_help
      puts <<-HELP
      galaxy-ledger extract-assistant - Extract learnings from assistant response

      USAGE:
        galaxy-ledger extract-assistant --session SESSION_ID --input-file FILE
        galaxy-ledger extract-assistant --session SESSION_ID --transcript-path PATH

      DESCRIPTION:
        Called by hooks to extract learnings, decisions, and discoveries
        from an assistant response using Claude CLI.

        With --transcript-path, reads the transcript file with exponential
        backoff to wait for the assistant response to be flushed. Also
        captures the last exchange and writes it to the DB.

        With --input-file, reads pre-extracted content directly (used for
        testing).

        This is an internal command used by the Stop hook.
      HELP
    end

    # ========================================
    # Spend Command
    # ========================================

    SPEND_PERIODS = ["today", "wtd", "30d", "mtd", "qtd", "ytd", "1y", "all"]

    private def self.handle_spend_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_spend_help
        return
      end

      # Parse flags
      json_output = false
      no_chart = false
      no_sparkline = false
      period_arg : String? = nil

      args.each do |arg|
        case arg
        when "--json"
          json_output = true
        when "--no-chart"
          no_chart = true
        when "--no-sparkline"
          no_sparkline = true
        else
          if period_arg.nil?
            period_arg = arg
          else
            STDERR.puts "Error: unexpected argument '#{arg}'"
            show_spend_help
            exit(1)
          end
        end
      end

      period = period_arg || "30d"

      # Resolve date range
      from_date, to_date, period_label = resolve_spend_period(period)

      # Fetch data
      summary = Database.spend_summary(from_date, to_date)
      daily = Database.spend_daily(from_date, to_date)
      avg_daily = Database.spend_avg_daily(from_date, to_date)

      # For "all" period, use earliest actual data date instead of "0000-01-01"
      # for gap-filling and total_days calculation
      effective_from = from_date
      if period == "all" && !daily.empty?
        effective_from = daily.first.date
      end

      # Calculate total days in range
      from_time = Time.parse(effective_from, "%Y-%m-%d", Time::Location::UTC)
      to_time = Time.parse(to_date, "%Y-%m-%d", Time::Location::UTC)
      total_days = ((to_time - from_time).total_days + 1).to_i

      if json_output
        render_spend_json(period, from_date, to_date, summary, daily, avg_daily, total_days)
      else
        # Gap-fill daily data for terminal visualizations
        display_daily = gap_fill_daily(daily, effective_from, to_date)

        render_spend_terminal(
          period, period_label, from_date, to_date,
          summary, display_daily, avg_daily, total_days,
          show_chart: !no_chart,
          show_sparkline: !no_sparkline,
        )
      end
    end

    private def self.resolve_spend_period(period : String) : {String, String, String}
      today = if override = ENV["GALAXY_LEDGER_TODAY"]?
                Time.parse(override, "%Y-%m-%d", Time::Location::UTC)
              else
                Time.utc
              end
      today_str = today.to_s("%Y-%m-%d")

      case period
      when "wtd"
        # Monday of current week
        days_since_monday = (today.day_of_week.value - 1) % 7
        monday = today - days_since_monday.days
        {monday.to_s("%Y-%m-%d"), today_str, "Week to Date"}
      when "30d"
        from = today - 29.days
        {from.to_s("%Y-%m-%d"), today_str, "Last 30 Days"}
      when "mtd"
        first = Time.utc(today.year, today.month, 1)
        {first.to_s("%Y-%m-%d"), today_str, "Month to Date"}
      when "qtd"
        quarter_month = ((today.month - 1) // 3) * 3 + 1
        first = Time.utc(today.year, quarter_month, 1)
        {first.to_s("%Y-%m-%d"), today_str, "Quarter to Date"}
      when "ytd"
        first = Time.utc(today.year, 1, 1)
        {first.to_s("%Y-%m-%d"), today_str, "Year to Date"}
      when "1y"
        year_ago = today - 365.days
        {year_ago.to_s("%Y-%m-%d"), today_str, "Last 1 Year"}
      when "all"
        {"0000-01-01", today_str, "All Time"}
      else
        # Custom range: YYYY-MM-DD..YYYY-MM-DD
        if period.includes?("..")
          parts = period.split("..", 2)
          if parts.size == 2
            from = parts[0]
            to = parts[1]
            # Validate format
            begin
              Time.parse(from, "%Y-%m-%d", Time::Location::UTC)
              Time.parse(to, "%Y-%m-%d", Time::Location::UTC)
            rescue
              STDERR.puts "Error: invalid date format in '#{period}'"
              STDERR.puts "Expected: YYYY-MM-DD..YYYY-MM-DD"
              exit(1)
            end
            {from, to, "#{from} to #{to}"}
          else
            STDERR.puts "Error: invalid period '#{period}'"
            show_spend_help
            exit(1)
          end
        else
          STDERR.puts "Error: unknown period '#{period}'"
          show_spend_help
          exit(1)
        end
      end
    end

    private def self.render_spend_json(
      period : String,
      from_date : String,
      to_date : String,
      summary : Database::SpendSummary,
      daily : Array(Database::SpendDay),
      avg_daily : Float64,
      total_days : Int32,
    )
      json = JSON.build do |j|
        j.object do
          j.field "period", period
          j.field "from", from_date
          j.field "to", to_date
          j.field "summary" do
            j.object do
              j.field "total_cost_usd", summary.total_cost
              j.field "total_tokens", summary.total_tokens
              j.field "active_days", summary.active_days
              j.field "total_days", total_days
              j.field "active_sessions", summary.active_sessions
              j.field "avg_daily_rate", avg_daily
            end
          end
          j.field "daily" do
            j.array do
              daily.each do |d|
                j.object do
                  j.field "date", d.date
                  j.field "cost_usd", d.cost
                  j.field "tokens", d.tokens
                end
              end
            end
          end
        end
      end
      puts json
    end

    private def self.render_spend_terminal(
      period : String,
      period_label : String,
      from_date : String,
      to_date : String,
      summary : Database::SpendSummary,
      daily : Array(Database::SpendDay),
      avg_daily : Float64,
      total_days : Int32,
      show_chart : Bool,
      show_sparkline : Bool,
    )
      # Format date range for header
      from_display = format_date_display(from_date)
      to_display = format_date_display(to_date)
      date_range = from_date == to_date ? "#{from_display} UTC" : "#{from_display} – #{to_display} UTC"

      puts "📊 Spend — #{period_label} (#{date_range})"
      puts ""
      puts "  Total Cost:       #{Chart.format_cost(summary.total_cost)}"
      puts "  Total Tokens:     #{format_number(summary.total_tokens)}"
      puts "  Active Days:      #{summary.active_days} / #{total_days}"
      puts "  Active Sessions:  #{summary.active_sessions}"
      puts "  Avg Daily Rate:   #{Chart.format_cost(avg_daily)} \u2020"

      return if daily.empty?

      # Determine grouping strategy based on period
      grouping = case period
                 when "qtd", "ytd" then :weekly
                 when "1y", "all"  then :monthly
                 else                   :daily
                 end

      if show_sparkline && daily.size > 1
        puts ""

        case grouping
        when :monthly
          monthly = group_by_month(daily)
          values = monthly.map(&.[:cost])
          spark = Chart.sparkline(values)
          puts "  Monthly:"
          puts "  #{spark}"
          nonzero = values.select { |v| v > 0.0 }
          if nonzero.empty?
            low = 0.0
            high = 0.0
            avg = 0.0
          else
            low = nonzero.min
            high = nonzero.max
            avg = nonzero.sum / nonzero.size
          end
          puts "  Low: #{Chart.format_cost(low)}/mo    High: #{Chart.format_cost(high)}/mo    Avg: #{Chart.format_cost(avg)}/mo \u2020"
        when :weekly
          weekly = group_by_week(daily)
          values = weekly.map(&.[:cost])
          spark = Chart.sparkline(values)
          puts "  Weekly:"
          puts "  #{spark}"
          nonzero = values.select { |v| v > 0.0 }
          if nonzero.empty?
            low = 0.0
            high = 0.0
            avg = 0.0
          else
            low = nonzero.min
            high = nonzero.max
            avg = nonzero.sum / nonzero.size
          end
          puts "  Low: #{Chart.format_cost(low)}/wk    High: #{Chart.format_cost(high)}/wk    Avg: #{Chart.format_cost(avg)}/wk \u2020"
        else
          values = daily.map(&.cost)
          spark = Chart.sparkline(values)
          puts "  Daily:"
          puts "  #{spark}"
          nonzero = values.select { |v| v > 0.0 }
          if nonzero.empty?
            low = 0.0
            high = 0.0
            avg = 0.0
          else
            low = nonzero.min
            high = nonzero.max
            avg = nonzero.sum / nonzero.size
          end
          puts "  Low: #{Chart.format_cost(low)}   High: #{Chart.format_cost(high)}   Avg: #{Chart.format_cost(avg)} \u2020"
        end
      end

      if show_chart && daily.size > 0
        puts ""

        # Determine UTC annotation for last bar row
        utc_today = Time.utc.to_s("%Y-%m-%d")
        local_today = Time.local.to_s("%Y-%m-%d")
        footnote = utc_bar_footnote(utc_today, local_today, grouping)

        case grouping
        when :monthly
          monthly = group_by_month(daily)
          # Pre-compute column widths for decimal-aligned cost and token columns
          cost_strs = monthly.map { |m| Chart.format_cost(m[:cost]) }
          token_strs = monthly.map { |m| Chart.format_tokens(m[:tokens]) }
          max_cost_w = cost_strs.max_of?(&.size) || 0
          max_tok_w = token_strs.max_of?(&.size) || 0
          rows = monthly.map_with_index do |m, idx|
            extra = "#{cost_strs[idx].rjust(max_cost_w)}    #{token_strs[idx].rjust(max_tok_w)}"
            extra += "  *" if footnote && idx == monthly.size - 1
            Chart::BarRow.new(
              label: m[:label],
              value: m[:cost],
              extra: extra,
            )
          end
          puts Chart.bar_chart(rows)
        when :weekly
          weekly = group_by_week(daily)
          # Pre-compute column widths for decimal-aligned cost and token columns
          cost_strs = weekly.map { |w| w[:cost] > 0.0 ? Chart.format_cost(w[:cost]) : nil }
          token_strs = weekly.map { |w| w[:cost] > 0.0 ? Chart.format_tokens(w[:tokens]) : nil }
          max_cost_w = cost_strs.compact.max_of?(&.size) || 0
          max_tok_w = token_strs.compact.max_of?(&.size) || 0
          rows = weekly.map_with_index do |w, idx|
            if w[:cost] > 0.0
              extra = "#{cost_strs[idx].not_nil!.rjust(max_cost_w)}    #{token_strs[idx].not_nil!.rjust(max_tok_w)}"
              extra += "  *" if footnote && idx == weekly.size - 1
              Chart::BarRow.new(
                label: format_bar_date(w[:label]),
                value: w[:cost],
                extra: extra,
              )
            else
              Chart::BarRow.new(label: format_bar_date(w[:label]), value: 0.0)
            end
          end
          puts Chart.bar_chart(rows)
        else
          # Pre-compute column widths for decimal-aligned cost and token columns
          cost_strs = daily.map { |d| d.cost > 0.0 ? Chart.format_cost(d.cost) : nil }
          token_strs = daily.map { |d| d.cost > 0.0 ? Chart.format_tokens(d.tokens) : nil }
          max_cost_w = cost_strs.compact.max_of?(&.size) || 0
          max_tok_w = token_strs.compact.max_of?(&.size) || 0
          rows = daily.map_with_index do |d, idx|
            label = format_bar_date(d.date)
            if d.cost > 0.0
              extra = "#{cost_strs[idx].not_nil!.rjust(max_cost_w)}    #{token_strs[idx].not_nil!.rjust(max_tok_w)}"
              extra += "  *" if footnote && idx == daily.size - 1
              Chart::BarRow.new(
                label: label,
                value: d.cost,
                extra: extra,
              )
            else
              Chart::BarRow.new(label: label, value: 0.0)
            end
          end
          puts Chart.bar_chart(rows)
        end

        if footnote
          puts ""
          puts "  #{footnote}"
        end
      end

      # Footnote for zero-exclusion markers
      case grouping
      when :monthly
        puts "  \u2020 excludes months with no usage"
      when :weekly
        puts "  \u2020 excludes weeks with no usage"
      else
        puts "  \u2020 excludes days with no usage"
      end

      puts ""
    end

    # Returns a UTC footnote string if the last bar chart row needs annotation,
    # nil otherwise. Annotation is needed when the UTC date/month doesn't match
    # the local date/month — only matters for the current (last) data point.
    def self.utc_bar_footnote(
      utc_today : String,
      local_today : String,
      grouping : Symbol,
    ) : String?
      case grouping
      when :daily
        if utc_today != local_today
          "* UTC — local date is still #{format_date_display(local_today)}"
        end
      when :weekly
        if utc_today != local_today
          "* UTC — local date is still #{format_date_display(local_today)}"
        end
      when :monthly
        if utc_today[0, 7] != local_today[0, 7]
          local_month = Time.parse(local_today, "%Y-%m-%d", Time::Location::UTC).to_s("%B")
          "* UTC — local month is still #{local_month}"
        end
      end
    end

    # Group daily data into weekly buckets
    private def self.group_by_week(daily : Array(Database::SpendDay)) : Array(NamedTuple(label: String, cost: Float64, tokens: Int64))
      weeks = {} of String => {cost: Float64, tokens: Int64}

      daily.each do |d|
        date = Time.parse(d.date, "%Y-%m-%d", Time::Location::UTC)
        # ISO week start (Monday)
        days_since_monday = (date.day_of_week.value - 1) % 7
        week_start = date - days_since_monday.days
        key = week_start.to_s("%Y-%m-%d")

        existing = weeks[key]? || {cost: 0.0, tokens: 0_i64}
        weeks[key] = {cost: existing[:cost] + d.cost, tokens: existing[:tokens] + d.tokens}
      end

      weeks.to_a.sort_by(&.[0]).map do |key, vals|
        {label: key, cost: vals[:cost], tokens: vals[:tokens]}
      end
    end

    # Group daily data into monthly buckets
    private def self.group_by_month(daily : Array(Database::SpendDay)) : Array(NamedTuple(label: String, cost: Float64, tokens: Int64))
      months = {} of String => {cost: Float64, tokens: Int64}

      daily.each do |d|
        key = d.date[0, 7] # "YYYY-MM"

        existing = months[key]? || {cost: 0.0, tokens: 0_i64}
        months[key] = {cost: existing[:cost] + d.cost, tokens: existing[:tokens] + d.tokens}
      end

      months.to_a.sort_by(&.[0]).map do |key, vals|
        # Format label as "Mon YY"
        date = Time.parse("#{key}-01", "%Y-%m-%d", Time::Location::UTC)
        label = date.to_s("%b %y")
        {label: label, cost: vals[:cost], tokens: vals[:tokens]}
      end
    end

    # Fill calendar gaps in daily data so every date from from_date to to_date
    # has an entry. Missing dates get SpendDay with zero cost/tokens.
    private def self.gap_fill_daily(
      daily : Array(Database::SpendDay),
      from_date : String,
      to_date : String,
    ) : Array(Database::SpendDay)
      return daily if daily.empty?

      existing = {} of String => Database::SpendDay
      daily.each { |d| existing[d.date] = d }

      filled = [] of Database::SpendDay
      current = Time.parse(from_date, "%Y-%m-%d", Time::Location::UTC)
      end_date = Time.parse(to_date, "%Y-%m-%d", Time::Location::UTC)

      while current <= end_date
        key = current.to_s("%Y-%m-%d")
        if found = existing[key]?
          filled << found
        else
          filled << Database::SpendDay.new(date: key, cost: 0.0, tokens: 0_i64)
        end
        current += 1.day
      end

      filled
    end

    # Format a date for display (e.g., "Feb 17, 2025")
    private def self.format_date_display(date_str : String) : String
      return date_str if date_str.starts_with?("0000")
      begin
        date = Time.parse(date_str, "%Y-%m-%d", Time::Location::UTC)
        date.to_s("%b %-d, %Y")
      rescue
        date_str
      end
    end

    # Format a date for bar chart labels (e.g., "Feb 01")
    private def self.format_bar_date(date_str : String) : String
      begin
        date = Time.parse(date_str, "%Y-%m-%d", Time::Location::UTC)
        date.to_s("%b %d")
      rescue
        date_str
      end
    end

    # Format a number with comma separators
    private def self.format_number(n : Int64) : String
      s = n.to_s
      groups = [] of String
      while s.size > 3
        groups.unshift(s[-3..])
        s = s[0...-3]
      end
      groups.unshift(s) unless s.empty?
      groups.join(",")
    end

    private def self.show_spend_help
      puts <<-HELP
      galaxy-ledger spend - Show token and cost usage over time

      USAGE:
        galaxy-ledger spend [PERIOD] [options]

      PERIODS:
        wtd                          Week to date (Monday → today)
        30d                          Last 30 days (default)
        mtd                          Month to date
        qtd                          Quarter to date
        ytd                          Year to date
        1y                           Last 365 days
        all                          All time
        YYYY-MM-DD..YYYY-MM-DD       Custom range

      OPTIONS:
        --json                       Output as JSON
        --no-chart                   Hide bar chart
        --no-sparkline               Hide sparkline
        -h, --help                   Show this help

      EXAMPLES:
        galaxy-ledger spend
        galaxy-ledger spend ytd
        galaxy-ledger spend ytd --json
        galaxy-ledger spend 2025-01-01..2025-01-31
        galaxy-ledger spend mtd --no-sparkline
      HELP
    end

    # ========================================
    # Session Metrics Command
    # ========================================

    private def self.handle_update_session_metrics_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_update_session_metrics_help
        return
      end

      # Parse args
      session_id : String? = nil
      pid_str : String? = nil
      i = 0
      while i < args.size
        arg = args[i]
        if arg == "--session" && i + 1 < args.size
          session_id = args[i + 1]
          i += 2
        elsif arg == "--pid" && i + 1 < args.size
          pid_str = args[i + 1]
          i += 2
        else
          i += 1
        end
      end

      # Resolve --pid or --session to ledger_session_id
      ledger_session_id : Int64? = nil
      if ps = pid_str
        ledger_session_id = resolve_pid_to_ledger_session_id(ps)
      elsif sid = session_id
        ledger_session_id = resolve_session_to_ledger_session_id(sid)
      end

      unless ledger_session_id
        STDERR.puts "Error: --session or --pid is required"
        exit(1)
      end

      # Read JSON from stdin
      begin
        json_str = STDIN.gets_to_end
        if json_str.strip.empty?
          STDERR.puts "Error: no JSON provided on stdin"
          exit(1)
        end

        status = ContextStatus.from_json(json_str)

        success = Database.update_session_metrics(ledger_session_id, status)

        unless success
          exit(1)
        end

        # Publish event notification to Galaxy.app (fire-and-forget)
        EventPublisher.publish(
          ledger_session_id: ledger_session_id,
          event: "session.metrics",
        )
      rescue ex
        STDERR.puts "Error: #{ex.message}"
        exit(1)
      end
    end

    private def self.show_update_session_metrics_help
      puts <<-HELP
      galaxy-ledger update-session-metrics - Update session metrics from stdin

      USAGE:
        galaxy-ledger update-session-metrics --pid PID < metrics.json
        galaxy-ledger update-session-metrics --session SESSION_ID < metrics.json

      REQUIRED (one of):
        --pid PID               Session by Claude Code process PID
        --session SESSION_ID    Session by identifier (backward compat)

      DESCRIPTION:
        Reads a ContextStatus JSON object from stdin and updates the session
        metrics in the database. Called by the statusline tool on every render
        as a fire-and-forget subprocess. Updates context percentage, token usage,
        cost, model info, project directory, and git branch.

        Silent on success (exit 0). Non-zero exit on failure.

      INPUT (stdin):
        A ContextStatus JSON object, e.g.:
        {
          "session_id": "abc123",
          "timestamp": 1234567890,
          "git_branch": "main",
          "workspace": {
            "project_dir": "/path/to/project"
          },
          "context": {
            "percentage": 45.2,
            "tokens_used": 50000,
            "tokens_max": 200000
          },
          "cost": {
            "usd": 0.15
          }
        }
      HELP
    end

    # ========================================
    # Event Publishing
    # ========================================

    private def self.handle_publish_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_publish_help
        return
      end

      # Parse args
      event : String? = nil
      session_id : String? = nil
      pid_str : String? = nil
      ref : String? = nil
      i = 0
      while i < args.size
        arg = args[i]
        if arg == "--event" && i + 1 < args.size
          event = args[i + 1]
          i += 2
        elsif arg == "--session" && i + 1 < args.size
          session_id = args[i + 1]
          i += 2
        elsif arg == "--pid" && i + 1 < args.size
          pid_str = args[i + 1]
          i += 2
        elsif arg == "--ref" && i + 1 < args.size
          ref = args[i + 1]
          i += 2
        else
          i += 1
        end
      end

      # Validate --event is required
      unless event
        STDERR.puts "Error: --event is required"
        STDERR.puts "Run 'galaxy-ledger publish --help' for usage"
        exit(1)
      end

      # Resolve --pid or --session to ledger_session_id
      ledger_session_id : Int64? = nil
      if ps = pid_str
        ledger_session_id = resolve_pid_to_ledger_session_id(ps)
      elsif sid = session_id
        ledger_session_id = resolve_session_to_ledger_session_id(sid)
      end

      unless ledger_session_id
        STDERR.puts "Error: --session or --pid is required"
        STDERR.puts "Run 'galaxy-ledger publish --help' for usage"
        exit(1)
      end

      EventPublisher.publish(
        ledger_session_id: ledger_session_id,
        event: event,
        ref: ref,
      )
    end

    private def self.show_publish_help
      puts <<-HELP
      galaxy-ledger publish - Publish an event to Galaxy.app

      USAGE:
        galaxy-ledger publish --event EVENT --pid PID [--ref REF]
        galaxy-ledger publish --event EVENT --session SESSION_ID [--ref REF]

      REQUIRED:
        --event EVENT           Event name (e.g., session.metrics, snapshot.created)

      REQUIRED (one of):
        --pid PID               Session by Claude Code process PID
        --session SESSION_ID    Session by identifier

      OPTIONAL:
        --ref REF               Supplemental reference (snapshot number, entry ID, etc.)

      DESCRIPTION:
        Publishes an event notification over the Galaxy Unix domain socket
        to Galaxy.app for real-time UI updates. Events are thin signals —
        they carry session identity and event name but no data payload.

        Silent on success (exit 0) whether or not Galaxy.app is running.
        Non-zero exit only if the session cannot be resolved.

      EXAMPLES:
        galaxy-ledger publish --event session.metrics --pid 12345
        galaxy-ledger publish --event snapshot.created --pid 12345 --ref 3
        galaxy-ledger publish --event session.metrics --session abc-123-def
      HELP
    end

    # ========================================
    # Session Data
    # ========================================

    private def self.handle_sessions_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_sessions_help
        return
      end

      # Parse args — --session is repeatable, --json is required,
      # --ledger-session-id is an alternative to --session
      session_ids = [] of String
      ledger_session_id_str : String? = nil
      json_flag = false
      i = 0
      while i < args.size
        arg = args[i]
        if arg == "--session" && i + 1 < args.size
          session_ids << args[i + 1]
          i += 2
        elsif arg == "--ledger-session-id" && i + 1 < args.size
          ledger_session_id_str = args[i + 1]
          i += 2
        elsif arg == "--json"
          json_flag = true
          i += 1
        else
          i += 1
        end
      end

      unless json_flag
        STDERR.puts "Error: --json is required"
        STDERR.puts "Run 'galaxy-ledger sessions --help' for usage"
        exit(1)
      end

      if session_ids.empty? && ledger_session_id_str.nil?
        STDERR.puts "Error: at least one --session or --ledger-session-id is required"
        STDERR.puts "Run 'galaxy-ledger sessions --help' for usage"
        exit(1)
      end

      # Resolve each session identifier to a ledger_session_id, deduplicate
      resolved = {} of Int64 => Database::SessionRecord

      # Direct ledger session ID lookup (bypasses identifier resolution)
      if lsid_str = ledger_session_id_str
        lsid = resolve_ledger_session_id_str(lsid_str)
        record = Database.get_session_by_id(lsid)
        resolved[lsid] = record if record
      end

      session_ids.each do |sid|
        ledger_session_id = Database.resolve_session_identifier(sid)
        next unless ledger_session_id
        next if resolved.has_key?(ledger_session_id)

        record = Database.get_session_by_id(ledger_session_id)
        next unless record

        resolved[ledger_session_id] = record
      end

      # Build JSON output
      io = IO::Memory.new
      builder = JSON::Builder.new(io)
      builder.document do
        builder.object do
          builder.field("sessions") do
            builder.array do
              resolved.each do |ledger_session_id, record|
                identifiers = Database.session_identifiers(ledger_session_id)
                pids = Database.session_pids(ledger_session_id)

                builder.object do
                  builder.field("ledger_session_id", record.id)
                  builder.field("suggested_name", record.suggested_name)
                  builder.field("suggested_name_data", record.suggested_name_data)
                  builder.field("session_identifiers") do
                    builder.array do
                      identifiers.each { |sid| builder.scalar(sid) }
                    end
                  end
                  builder.field("current_session_identifier", record.current_session_identifier)
                  builder.field("claude_pids") do
                    builder.array do
                      pids.each { |pid| builder.number(pid) }
                    end
                  end
                  builder.field("current_claude_pid", record.current_claude_pid)
                  builder.field("cwd", record.cwd)
                  builder.field("project_dir", record.project_dir)
                  builder.field("git_branch", record.git_branch)
                  builder.field("model_id", record.model_id)
                  builder.field("model_display_name", record.model_display_name)
                  builder.field("claude_version", record.claude_version)
                  builder.field("context_percentage", record.context_percentage)
                  builder.field("tokens_used", record.tokens_used)
                  builder.field("tokens_max", record.tokens_max)
                  builder.field("cost_usd", record.cost_usd)
                  builder.field("lines_added", record.lines_added)
                  builder.field("lines_removed", record.lines_removed)
                  builder.field("started_at", record.started_at)
                  builder.field("updated_at", record.updated_at)
                  builder.field("last_interaction", record.last_interaction)
                end
              end
            end
          end
        end
      end

      puts io.to_s
    end

    private def self.show_sessions_help
      puts <<-HELP
      galaxy-ledger sessions - Query session state as JSON

      USAGE:
        galaxy-ledger sessions --json --session ID1 [--session ID2 ...]
        galaxy-ledger sessions --json --ledger-session-id N

      REQUIRED:
        --json                  Output format (currently the only format)

      REQUIRED (one of):
        --session SESSION_ID    Session identifier to query (repeatable)
        --ledger-session-id N   Query by internal ledger session ID

      DESCRIPTION:
        Returns session state data in JSON format for Galaxy.app enrichment.
        Each --session flag specifies a Claude session identifier that gets
        resolved through the ledger_session_identifiers table.

        --ledger-session-id bypasses identifier resolution and queries by
        internal database ID directly. Used by Galaxy.app when the ledger
        session ID is already known.

        Multiple identifiers that resolve to the same ledger session are
        deduplicated in the output. Unknown session identifiers are silently
        omitted (no error).

        Used by Galaxy.app for:
        - Startup sync (passing all known session UUIDs)
        - Event enrichment (passing identifiers from received events)
        - JIT data fetching in LedgerView subtabs

      OUTPUT:
        {
          "sessions": [
            {
              "ledger_session_id": 42,
              "session_identifiers": ["abc-123", "def-456"],
              "current_session_identifier": "def-456",
              "claude_pids": [12345, 11000],
              "current_claude_pid": 12345,
              "cwd": "/Users/kelly/projects/kajabi",
              ...
            }
          ]
        }

      EXAMPLES:
        galaxy-ledger sessions --json --session abc-123
        galaxy-ledger sessions --json --session abc-123 --session def-456
        galaxy-ledger sessions --json --ledger-session-id 42
      HELP
    end

    # ========================================
    # Resolve Session Command
    # ========================================

    private def self.handle_resolve_session_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_resolve_session_help
        return
      end

      pid_str : String? = nil
      session_id : String? = nil
      i = 0
      while i < args.size
        arg = args[i]
        if arg == "--pid" && i + 1 < args.size
          pid_str = args[i + 1]
          i += 2
        elsif arg == "--session" && i + 1 < args.size
          session_id = args[i + 1]
          i += 2
        else
          i += 1
        end
      end

      ledger_session_id : Int64? = nil
      if ps = pid_str
        ledger_session_id = resolve_pid_to_ledger_session_id(ps)
      elsif sid = session_id
        ledger_session_id = resolve_session_to_ledger_session_id(sid)
      end

      unless ledger_session_id
        STDERR.puts "Error: --pid or --session is required"
        STDERR.puts "Run 'galaxy-ledger resolve-session --help' for usage"
        exit(1)
      end

      puts ledger_session_id
    end

    private def self.show_resolve_session_help
      puts <<-HELP
      galaxy-ledger resolve-session - Resolve a PID or session identifier to a ledger session ID

      USAGE:
        galaxy-ledger resolve-session --pid PID
        galaxy-ledger resolve-session --session SESSION_IDENTIFIER

      REQUIRED (one of):
        --pid PID                  Claude Code process ID
        --session SESSION_ID       Session identifier string

      OUTPUT:
        Prints the ledger session ID (integer) to stdout.
        Exits non-zero if not found.

      EXAMPLES:
        galaxy-ledger resolve-session --pid 12345
        galaxy-ledger resolve-session --session abc-123-def-456
      HELP
    end

    # ========================================
    # Session Identifiers Command
    # ========================================

    private def self.handle_session_identifiers_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_session_identifiers_help
        return
      end

      ledger_session_id_str : String? = nil
      json_flag = false
      i = 0
      while i < args.size
        arg = args[i]
        if arg == "--ledger-session-id" && i + 1 < args.size
          ledger_session_id_str = args[i + 1]
          i += 2
        elsif arg == "--json"
          json_flag = true
          i += 1
        else
          i += 1
        end
      end

      unless json_flag
        STDERR.puts "Error: --json is required"
        STDERR.puts "Run 'galaxy-ledger session-identifiers --help' for usage"
        exit(1)
      end

      unless ledger_session_id_str
        STDERR.puts "Error: --ledger-session-id is required"
        STDERR.puts "Run 'galaxy-ledger session-identifiers --help' for usage"
        exit(1)
      end

      ledger_session_id = resolve_ledger_session_id_str(ledger_session_id_str)
      identifiers = Database.session_identifiers(ledger_session_id)

      io = IO::Memory.new
      builder = JSON::Builder.new(io)
      builder.document do
        builder.object do
          builder.field("session_identifiers") do
            builder.array do
              identifiers.each { |sid| builder.scalar(sid) }
            end
          end
        end
      end

      puts io.to_s
    end

    private def self.show_session_identifiers_help
      puts <<-HELP
      galaxy-ledger session-identifiers - List session identifiers for a ledger session

      USAGE:
        galaxy-ledger session-identifiers --json --ledger-session-id N

      REQUIRED:
        --json                     Output format (required)
        --ledger-session-id N      Ledger session ID

      OUTPUT:
        JSON object with session_identifiers array:
        {"session_identifiers": ["abc-123", "def-456"]}

      EXAMPLES:
        galaxy-ledger session-identifiers --json --ledger-session-id 42
      HELP
    end

    # ========================================
    # Suggest Name Command
    # ========================================

    private def self.handle_suggest_name_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_suggest_name_help
        return
      end

      # Parse args
      session_id : String? = nil
      transcript_path : String? = nil
      i = 0
      while i < args.size
        arg = args[i]
        if arg == "--session" && i + 1 < args.size
          session_id = args[i + 1]
          i += 2
        elsif arg == "--transcript-path" && i + 1 < args.size
          transcript_path = args[i + 1]
          i += 2
        else
          i += 1
        end
      end

      unless session_id
        STDERR.puts "Error: --session is required"
        exit(1)
      end

      unless transcript_path
        STDERR.puts "Error: --transcript-path is required"
        exit(1)
      end

      # Check config
      config = Config.load
      return unless config.suggested_name.enabled

      # Resolve session
      ledger_session_id = Database.resolve_session_identifier(session_id)
      unless ledger_session_id
        STDERR.puts "Error: no session found for identifier '#{session_id}'"
        exit(1)
      end

      # Load current state — short-circuit if finalized
      session = Database.get_session_by_id(ledger_session_id)
      return unless session

      state = SuggestedName::StateData.from_json_safe(session.suggested_name_data)
      unless state.should_suggest?
        STDERR.puts "[galaxy-ledger] Name suggestion complete (#{state.status}), skipping"
        return
      end

      # Parse transcript and extract recent exchanges
      entries = read_transcript_entries_with_backoff(transcript_path)
      return if entries.empty?

      exchanges = Transcript.extract_recent_exchanges(entries, SuggestedName::MAX_EXCHANGES_FOR_CONTEXT)
      if exchanges.empty?
        STDERR.puts "[galaxy-ledger] No exchanges found in transcript, skipping"
        return
      end

      # Build context
      context, exchange_count = SuggestedName.build_context(exchanges)
      if context.strip.empty?
        return
      end

      # Call Claude Haiku one-shot
      begin
        run_result = Extraction::ClaudeCLI.run(
          content: context,
          prompt: SuggestedName.suggestion_prompt,
          model: SuggestedName::SUGGESTION_MODEL,
        )

        suggestion = SuggestedName.parse_response(run_result[:result])

        if suggestion.needs_more_context
          state.set_needs_more_context
          Database.update_suggested_name_data(ledger_session_id, state.to_json)
          STDERR.puts "[galaxy-ledger] Name suggestion: needs more context"
        elsif SuggestedName.name_appears_to_be_code?(suggestion.name)
          state.set_code_detected
          Database.update_suggested_name_data(ledger_session_id, state.to_json)
          STDERR.puts "[galaxy-ledger] Name suggestion: code detected, rejected"
        elsif name = suggestion.name
          should_save = state.set_name_generated(suggestion.quality, exchange_count)
          if should_save
            Database.update_suggested_name_with_data(ledger_session_id, name, state.to_json)
            STDERR.puts "[galaxy-ledger] Suggested name: #{name} (quality: #{suggestion.quality})"

            # Notify Galaxy.app so it re-fetches session data with the new name
            EventPublisher.publish(
              ledger_session_id: ledger_session_id,
              event: "session.metrics",
            )
          else
            Database.update_suggested_name_data(ledger_session_id, state.to_json)
            STDERR.puts "[galaxy-ledger] Name suggestion: quality #{suggestion.quality} < current #{state.quality}, keeping existing"
          end
        else
          STDERR.puts "[galaxy-ledger] Name suggestion: empty result"
        end

        # Record one-shot usage
        if run_result[:cost_usd] > 0.0
          total_tokens = run_result[:input_tokens] + run_result[:output_tokens] +
                         run_result[:cache_creation_tokens] + run_result[:cache_read_tokens]
          Database.record_oneshot_usage(ledger_session_id, run_result[:cost_usd], total_tokens)
        end
      rescue ex
        STDERR.puts "[galaxy-ledger] Name suggestion error: #{ex.message}"
      end
    end

    private def self.show_suggest_name_help
      puts <<-HELP
      Usage: galaxy-ledger suggest-name --session <ID> --transcript-path <PATH>

      Generate or improve a suggested session name using a Claude Haiku one-shot.
      Spawned as a subprocess by the on-stop hook. Short-circuits immediately if
      the session name is already finalized (quality >= 4 or max attempts reached).

      Options:
        --session          Claude session identifier (required)
        --transcript-path  Path to the session transcript JSONL file (required)
        -h, --help         Show this help
      HELP
    end

    # ── session-name subcommand ──────────────────────────────────────────

    private def self.handle_session_name_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_session_name_help
        return
      end

      # Parse --pid
      pid_str : String? = nil
      i = 0
      while i < args.size
        arg = args[i]
        if arg == "--pid" && i + 1 < args.size
          pid_str = args[i + 1]
          i += 2
        else
          i += 1
        end
      end

      unless pid_str
        STDERR.puts "Error: --pid is required"
        show_session_name_help
        exit(1)
      end

      # resolve_pid_to_ledger_session_id exits with
      # "Error: no session found for PID ..." if PID is unknown
      ledger_session_id = resolve_pid_to_ledger_session_id(pid_str)

      session = Database.get_session_by_id(ledger_session_id)
      project_dir = session.try(&.project_dir)

      unless project_dir
        puts "(unnamed)"
        return
      end

      # Build JSONL paths for every session identifier (the rename
      # custom-title entry may live under an earlier UUID).
      identifiers = Database.session_identifiers(ledger_session_id)
      encoded_dir = project_dir.gsub(/[\/.]/, "-")
      claude_projects_dir = CLAUDE_CONFIG_DIR / "projects" / encoded_dir

      jsonl_paths = identifiers.map { |id| claude_projects_dir / "#{id}.jsonl" }
      puts find_custom_title(jsonl_paths) || "(unnamed)"
    end

    private def self.show_session_name_help
      puts <<-HELP
      Usage: galaxy-ledger session-name --pid PID

      Look up the current Claude Code session name (custom title) from
      the session transcript JSONL file.

      Options:
        --pid PID    Session by Claude Code process PID (required)
        -h, --help   Show this help
      HELP
    end

    # Scan JSONL files for the last custom-title entry.
    # Exposed as a class method for unit testing.
    def self.find_custom_title(jsonl_paths : Array(Path)) : String?
      custom_title : String? = nil

      jsonl_paths.each do |jsonl_path|
        next unless File.exists?(jsonl_path)

        File.each_line(jsonl_path) do |line|
          if line.includes?("\"custom-title\"")
            begin
              parsed = JSON.parse(line)
              if title = parsed["customTitle"]?.try(&.as_s?)
                custom_title = title
              end
            rescue
              # Skip malformed JSON lines
            end
          end
        end
      end

      custom_title
    end

    # Read transcript entries with backoff (reusable for extraction and suggest-name)
    private def self.read_transcript_entries_with_backoff(transcript_path : String) : Array(Transcript::TranscriptEntry)
      # No point retrying if the file doesn't exist at all — it won't
      # appear between retries. The backoff is for partially-flushed files.
      return [] of Transcript::TranscriptEntry unless File.exists?(transcript_path)

      TRANSCRIPT_BACKOFF_DELAYS.each_with_index do |delay, attempt|
        sleep (delay * 1000).to_i.milliseconds if delay > 0

        entries = Transcript.parse(transcript_path)
        return entries if entries.any?
      end

      [] of Transcript::TranscriptEntry
    end

    # ================================================================
    # Backup Command
    # ================================================================

    private def self.handle_backup_command(args : Array(String))
      if args.includes?("-h") || args.includes?("--help")
        show_backup_help
        return
      end

      list_mode = false
      prune_only = false
      session_id = 0_i64

      i = 0
      while i < args.size
        case args[i]
        when "--list"
          list_mode = true
        when "--prune-only"
          prune_only = true
        when "--session-id"
          if i + 1 < args.size
            session_id = args[i + 1].to_i64? || 0_i64
            i += 1
          end
        end
        i += 1
      end

      config = Config.load

      if list_mode
        backup_list(config)
      elsif prune_only
        backup_prune_only(config)
      else
        backup_create_and_prune(config, session_id)
      end
    end

    private def self.backup_list(config : Config)
      backup_dir = config.effective_backup_path

      unless Dir.exists?(backup_dir)
        puts "No backups found."
        puts "Backup directory: #{Hooks::Helpers.shorten_home_path(backup_dir.to_s)}"
        return
      end

      # Collect date directories, sorted descending
      date_dirs = [] of String
      Dir.each_child(backup_dir) do |entry|
        entry_path = backup_dir / entry
        next unless File.directory?(entry_path)
        # Only include date-named directories
        begin
          Time.parse(entry, "%Y-%m-%d", Time::Location.local)
          date_dirs << entry
        rescue Time::Format::Error
          # Skip non-date directories
        end
      end

      if date_dirs.empty?
        puts "No backups found."
        puts "Backup directory: #{Hooks::Helpers.shorten_home_path(backup_dir.to_s)}"
        return
      end

      date_dirs.sort!.reverse!

      puts "Backups in #{Hooks::Helpers.shorten_home_path(backup_dir.to_s)} (retention: #{config.backups.retention_days} days)"
      puts ""

      total_count = 0
      total_bytes = 0_i64

      date_dirs.each do |date_dir|
        dir_path = backup_dir / date_dir
        files = [] of {name: String, size: Int64, time: Time}

        Dir.each_child(dir_path) do |file|
          file_path = dir_path / file
          next unless File.file?(file_path) && file.ends_with?(".db")
          info = File.info(file_path)
          files << {name: file, size: info.size, time: info.modification_time}
        end

        next if files.empty?
        files.sort_by! { |f| f[:time] }.reverse!

        dir_size = files.sum(&.[:size])
        puts "  #{date_dir}/ (#{files.size} #{files.size == 1 ? "backup" : "backups"}, #{format_size(dir_size)})"

        files.each do |f|
          time_str = f[:time].to_s("%l:%M %p").strip
          puts "    %-25s %8s   %s" % [f[:name], format_size(f[:size]), time_str]
        end
        puts ""

        total_count += files.size
        total_bytes += dir_size
      end

      puts "  Total: #{total_count} #{total_count == 1 ? "backup" : "backups"}, #{format_size(total_bytes)}"
    end

    private def self.backup_create_and_prune(config : Config, session_id : Int64)
      unless config.backups.enabled
        puts "Backups are disabled. Enable with: galaxy-ledger config set backups.enabled true"
        return
      end

      backup_dir = config.effective_backup_path

      result = Database.backup(backup_dir, session_id)
      if result
        size = File.size(result)
        puts "Backup created: #{Hooks::Helpers.shorten_home_path(result.to_s)} (#{format_size(size)})"
      else
        STDERR.puts "Backup failed."
      end

      pruned = Database.prune_backups(backup_dir, config.backups.retention_days)
      if pruned > 0
        puts "Pruned #{pruned} old backup #{pruned == 1 ? "directory" : "directories"}."
      end
    end

    private def self.backup_prune_only(config : Config)
      backup_dir = config.effective_backup_path
      pruned = Database.prune_backups(backup_dir, config.backups.retention_days)
      if pruned > 0
        puts "Pruned #{pruned} old backup #{pruned == 1 ? "directory" : "directories"}."
      else
        puts "No backups to prune."
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

    private def self.show_backup_help
      puts <<-HELP
      galaxy-ledger backup - Manage database backups

      USAGE:
        galaxy-ledger backup                        Create a backup and prune old ones
        galaxy-ledger backup --list                 List all backups
        galaxy-ledger backup --prune-only           Prune old backups without creating new one

      OPTIONS:
        --session-id ID   Session record ID for backup filename (default: 0)
        --list            List all existing backups
        --prune-only      Only prune old backups, don't create a new one
        -h, --help        Show this help

      CONFIGURATION:
        backups.enabled          Enable/disable automatic backups (default: true)
        backups.retention_days   Days of backups to keep (default: 3)
        backups.path             Custom backup directory (default: ~/.claude/galaxy/data/backups)

      DESCRIPTION:
        Creates point-in-time database backups using SQLite VACUUM INTO.
        Backups are organized in date directories with session IDs in
        filenames. Old backups are automatically pruned based on the
        configured retention period.

        Backups run automatically on every session start via the startup
        hook. This command provides manual control for on-demand backups,
        listing, and pruning.

      EXAMPLES:
        galaxy-ledger backup                   # Create backup + prune
        galaxy-ledger backup --list            # See all backups
        galaxy-ledger backup --prune-only      # Clean up old backups
        galaxy-ledger config set backups.retention_days 7
      HELP
    end

    # ================================================================
    # Prune Command
    # ================================================================

    private def self.handle_prune_command(args : Array(String))
      if args.includes?("-h") || args.includes?("--help")
        show_prune_help
        return
      end

      summary_mode = false
      older_than : String? = nil
      apply = false

      i = 0
      while i < args.size
        case args[i]
        when "--summary"
          summary_mode = true
        when "--older-than"
          if i + 1 < args.size
            older_than = args[i + 1]
            i += 1
          else
            STDERR.puts "Error: --older-than requires a duration argument"
            STDERR.puts "Valid durations: 1w, 2w, 1m, 2m, 3m, 6m, 1y, 2y, 5y"
            exit(1)
          end
        when "--apply"
          apply = true
        end
        i += 1
      end

      if summary_mode
        prune_summary
      elsif older_than
        days = parse_prune_duration(older_than)
        unless days
          STDERR.puts "Error: Invalid duration '#{older_than}'"
          STDERR.puts "Valid durations: 1w, 2w, 1m, 2m, 3m, 6m, 1y, 2y, 5y"
          exit(1)
        end

        if apply
          prune_apply(older_than, days)
        else
          prune_preview(older_than, days)
        end
      else
        show_prune_help
      end
    end

    # Parse a prune duration string into number of days.
    # Returns nil for unrecognized input.
    def self.parse_prune_duration(duration : String) : Int32?
      Database::PRUNE_PERIODS[duration]?
    end

    private def self.prune_summary
      summary = Database.count_prunable_summary
      db_size = Database.database_file_size

      puts "Prunable session data (by last-active date):"
      puts ""
      puts "  %-20s %10s %10s %10s" % ["Period", "Sessions", "Entries", "Files"]
      puts "  " + "─" * 52

      Database::PRUNE_PERIODS.each_key do |label|
        counts = summary[label]?
        next unless counts
        next if counts.sessions == 0 && counts.entries == 0 && counts.files == 0

        puts "  %-20s %10s %10s %10s" % [
          "Older than #{label}",
          format_number(counts.sessions),
          format_number(counts.entries),
          format_number(counts.files),
        ]
      end

      puts ""
      puts "Database size: #{format_size(db_size)}"
      puts ""
      puts "Preserved per session: session record, daily usages"
      puts ""
      puts "To prune: galaxy-ledger prune --older-than PERIOD --apply"
    end

    private def self.prune_preview(duration_label : String, days : Int32)
      cutoff = (Time.utc - days.days).to_s("%Y-%m-%d %H:%M:%S")
      cutoff_display = (Time.utc - days.days).to_s("%Y-%m-%d")
      counts = Database.count_prunable_data(cutoff)

      if counts.sessions == 0
        puts "No sessions older than #{duration_label} (#{days} days). Nothing to prune."
        return
      end

      puts "Sessions last active before #{cutoff_display} (#{days} days): #{format_number(counts.sessions)}"
      puts ""
      puts "Would prune:"
      puts "  Entries:  #{format_number(counts.entries)}"
      puts "  Files:    #{format_number(counts.files)}"
      puts ""
      puts "Preserved:"
      puts "  Session records:  #{format_number(counts.sessions)}"
      puts "  Daily usages:     #{format_number(counts.daily_usages)}"
      puts ""
      puts "Run with --apply to execute."
    end

    private def self.prune_apply(duration_label : String, days : Int32)
      cutoff = (Time.utc - days.days).to_s("%Y-%m-%d %H:%M:%S")

      # Warn if active sessions exist
      active = Database.active_session_count
      if active > 0
        puts "Note: #{active} active #{active == 1 ? "session" : "sessions"} detected. VACUUM may fail if database is locked."
      end

      result = Database.prune_session_data(cutoff)

      if result[:entries] == 0 && result[:files] == 0
        puts "No data to prune for sessions older than #{duration_label} (#{days} days)."
        return
      end

      puts "Pruned session data older than #{duration_label} (#{days} days):"
      puts "  Entries deleted:  #{format_number(result[:entries])}"
      puts "  Files deleted:    #{format_number(result[:files])}"

      vacuum_result = Database.vacuum_database
      puts ""
      puts "Database: #{format_size(vacuum_result[:before])} → #{format_size(vacuum_result[:after])}"
      puts ""
      puts "Session records and daily usages preserved."
    end

    private def self.show_prune_help
      puts <<-HELP
      galaxy-ledger prune - Prune old session entries and files

      USAGE:
        galaxy-ledger prune --summary                    Show all pruning options
        galaxy-ledger prune --older-than PERIOD          Preview what would be pruned
        galaxy-ledger prune --older-than PERIOD --apply  Execute the prune

      PERIODS:
        1w, 2w, 1m, 2m, 3m, 6m, 1y, 2y, 5y

      OPTIONS:
        --summary            Show prunable data for all periods
        --older-than PERIOD  Target sessions last active before PERIOD ago
        --apply              Execute the prune (default is preview only)
        -h, --help           Show this help

      DESCRIPTION:
        Prunes entries and file-access records from sessions that haven't
        been active within the specified period. Session records, daily
        usage metrics are always preserved.

        Default mode is preview (dry run). Use --apply to execute.
        After pruning, the database is automatically vacuumed to
        reclaim disk space.

      EXAMPLES:
        galaxy-ledger prune --summary                # See what can be pruned
        galaxy-ledger prune --older-than 3m          # Preview 3-month prune
        galaxy-ledger prune --older-than 3m --apply  # Execute 3-month prune
      HELP
    end
  end
end
