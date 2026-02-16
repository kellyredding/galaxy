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

      case command
      when "config"
        handle_config_command(rest)
      when "search"
        handle_search_command(rest)
      when "list"
        handle_list_command(rest)
      when "add"
        handle_add_command(rest)
      when "on-startup"
        handle_on_startup_command(rest)
      when "on-stop"
        handle_on_stop_command(rest)
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
      when "extract-file"
        handle_extract_file_command(rest)
      when "list-files"
        handle_list_files_command(rest)
      when "update-session-metrics"
        handle_update_session_metrics_command(rest)
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
        list                List recent entries
        list-files          List session file access records
        add                 Add an entry (learning, decision, direction, etc.)
        config              Manage configuration
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
        on-post-tool-use    Track file operations, detect guidelines
        on-user-prompt-submit  Capture user directions/preferences

      Session Metrics:
        update-session-metrics  Update session metrics from stdin JSON

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
      prefix_match = true
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

      # Resolve --pid or --session to ledger_session_id
      ledger_session_id : Int64? = nil
      if ps = pid_str
        ledger_session_id = resolve_pid_to_ledger_session_id(ps)
      elsif sid = session_id
        ledger_session_id = resolve_session_to_ledger_session_id(sid)
      end

      entries = if lsid = ledger_session_id
                  Database.search_in_session(lsid, query, entry_type: entry_type, importance: importance, category: category, prefix_match: prefix_match)
                else
                  Database.search(query, entry_type: entry_type, importance: importance, category: category, prefix_match: prefix_match)
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
        --type TYPE           Filter by entry type
        --importance LEVEL    Filter by importance (high, medium, low)
        --category CATEGORY   Filter by category (e.g., ruby-style, rspec, git-workflow)
        --exact               Disable prefix matching (exact word match only)
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
      HELP
    end

    private def self.handle_list_command(args : Array(String))
      # Check for help flag first (only if it's a standalone argument, not a value)
      if args.first? == "-h" || args.first? == "--help"
        show_list_help
        return
      end

      # Parse options
      limit = 20
      entry_type : String? = nil
      importance : String? = nil
      session_id : String? = nil
      pid_str : String? = nil

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

      # Resolve --pid or --session to ledger_session_id
      ledger_session_id : Int64? = nil
      if ps = pid_str
        ledger_session_id = resolve_pid_to_ledger_session_id(ps)
      elsif sid = session_id
        ledger_session_id = resolve_session_to_ledger_session_id(sid)
      end

      entries = Database.query_recent_filtered(limit, entry_type, importance, ledger_session_id: ledger_session_id)

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

    private def self.show_list_help
      puts <<-HELP
      galaxy-ledger list - List recent ledger entries

      USAGE:
        galaxy-ledger list [options]

      OPTIONS:
        --pid PID               Scope listing to session by Claude Code PID
        --session ID            Scope listing to a specific session (backward compat)
        --limit N               Number of entries to show (default: 20)
        --type TYPE             Filter by entry type
        --importance LEVEL      Filter by importance (high, medium, low)
        -h, --help              Show this help

      ENTRY TYPES:
        #{ENTRY_TYPES.join(", ")}

      EXAMPLES:
        galaxy-ledger list
        galaxy-ledger list --limit 50
        galaxy-ledger list --type guideline
        galaxy-ledger list --importance high
        galaxy-ledger list --limit 10 --type learning --importance medium
        galaxy-ledger list --session abc123                    # Session-scoped listing
        galaxy-ledger list --session abc123 --type learning    # Session + type filter
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
      limit = 50

      i = 0
      while i < args.size
        arg = args[i]
        if arg == "--session" && i + 1 < args.size
          session_id = args[i + 1]
          i += 2
        elsif arg == "--pid" && i + 1 < args.size
          pid_str = args[i + 1]
          i += 2
        elsif arg == "--limit" && i + 1 < args.size
          limit = args[i + 1].to_i? || 50
          i += 2
        else
          STDERR.puts "Error: Unknown option '#{arg}'"
          STDERR.puts "Run 'galaxy-ledger list-files --help' for usage"
          exit(1)
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
        STDERR.puts "Run 'galaxy-ledger list-files --help' for usage"
        exit(1)
      end

      files = Database.session_files(ledger_session_id)

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

        puts "  [#{ops_str}]  #{path_str}"
        puts "              (#{access_str}#{time_str})"
      end
    end

    private def self.show_list_files_help
      puts <<-HELP
      galaxy-ledger list-files - List session file access records

      USAGE:
        galaxy-ledger list-files --pid PID [options]
        galaxy-ledger list-files --session SESSION_ID [options]

      REQUIRED (one of):
        --pid PID               Session by Claude Code process PID
        --session SESSION_ID    Session by identifier (backward compat)

      OPTIONS:
        --limit N               Maximum files to show (default: 50)
        -h, --help              Show this help

      OUTPUT:
        Shows each file with operation flags (read, edited, written, searched),
        the file path, access count, and last access timestamp.

      EXAMPLES:
        galaxy-ledger list-files --session abc123
        galaxy-ledger list-files --session abc123 --limit 10
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
        - Detects guideline files (**/agent-guidelines/**, **/*-style.md)
        - Detects implementation plan files (**/implementation-plans/**)
        - Writes entries directly to SQLite

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
        session_files table for deduplication and context awareness.

      ENTRY TYPES CREATED:
        - extraction_marker: Marker entry when a guideline or implementation plan is read.
          Stores the full file path in source_file and the original extraction type
          (guideline or implementation_plan) in metadata. (importance: medium)

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

    private def self.handle_extract_assistant_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_extract_assistant_help
        return
      end

      # Parse args
      session_id : String? = nil
      input_file : String? = nil
      i = 0
      while i < args.size
        arg = args[i]
        if arg == "--session" && i + 1 < args.size
          session_id = args[i + 1]
          i += 2
        elsif arg == "--input-file" && i + 1 < args.size
          input_file = args[i + 1]
          i += 2
        else
          i += 1
        end
      end

      unless session_id
        STDERR.puts "Error: --session is required"
        exit(1)
      end

      unless input_file
        STDERR.puts "Error: --input-file is required"
        exit(1)
      end

      # Resolve session_identifier to ledger_session_id
      ledger_session_id = Database.resolve_session_identifier(session_id)
      unless ledger_session_id
        STDERR.puts "Error: no session found for identifier '#{session_id}'"
        exit(1)
      end

      # Read input file
      begin
        input_json = File.read(input_file)
        json = JSON.parse(input_json)
        user_message = json["user_message"]?.try(&.as_s?) || ""
        assistant_content = json["assistant_content"]?.try(&.as_s?) || ""

        # Clean up temp file
        File.delete(input_file) if File.exists?(input_file)

        if user_message.strip.empty? || assistant_content.strip.empty?
          return # Nothing to extract
        end

        # Run extraction
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

        # Update last interaction with summary if we got one
        if summary = result.summary
          session_record = Database.get_session_by_id(ledger_session_id)
          if session_record && (li_json = session_record.last_interaction)
            begin
              last_exchange = Exchange::LastExchange.from_json(li_json)
              # Create updated exchange with summary
              updated = Exchange::LastExchange.new(
                user_message: last_exchange.user_message,
                full_content: last_exchange.full_content,
                assistant_messages: last_exchange.assistant_messages,
                user_timestamp: last_exchange.user_timestamp,
                summary: summary,
              )
              Database.update_session_last_interaction(ledger_session_id, updated.to_pretty_json)
              STDERR.puts "[galaxy-ledger] Updated last interaction with summary"
            rescue
              # Ignore parse errors on last_interaction
            end
          end
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

      DESCRIPTION:
        Called by hooks to extract learnings, decisions, and discoveries
        from an assistant response using Claude CLI.

        This is an internal command used by the Stop hook.
      HELP
    end

    private def self.handle_extract_file_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_extract_file_help
        return
      end

      # Parse args
      session_id : String? = nil
      extraction_type : String? = nil
      file_path : String? = nil
      i = 0
      while i < args.size
        arg = args[i]
        if arg == "--session" && i + 1 < args.size
          session_id = args[i + 1]
          i += 2
        elsif arg == "--type" && i + 1 < args.size
          extraction_type = args[i + 1]
          i += 2
        elsif arg == "--path" && i + 1 < args.size
          file_path = args[i + 1]
          i += 2
        else
          i += 1
        end
      end

      unless session_id
        STDERR.puts "Error: --session is required"
        exit(1)
      end

      unless extraction_type
        STDERR.puts "Error: --type is required"
        exit(1)
      end

      unless file_path
        STDERR.puts "Error: --path is required"
        exit(1)
      end

      # Resolve session_identifier to ledger_session_id
      ledger_session_id = Database.resolve_session_identifier(session_id)
      unless ledger_session_id
        STDERR.puts "Error: no session found for identifier '#{session_id}'"
        exit(1)
      end

      # Read content from stdin
      content = STDIN.gets_to_end

      if content.strip.empty?
        return # Nothing to extract
      end

      # Run appropriate extraction
      result = case extraction_type
               when "guideline"
                 Extraction.extract_guidelines(file_path, content)
               when "implementation_plan"
                 Extraction.extract_implementation_plan(file_path, content)
               else
                 STDERR.puts "Error: Unknown extraction type '#{extraction_type}'"
                 exit(1)
               end

      # Write extracted entries directly to database
      if result.extractions.any?
        entries = result.extractions.select(&.valid?).map do |e|
          e.to_entry
        end
        inserted = Database.insert_many(ledger_session_id, entries)
        if inserted > 0
          STDERR.puts "[galaxy-ledger] Extracted #{inserted} #{extraction_type} entries from #{File.basename(file_path)}"
        end
      end
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

    private def self.show_extract_file_help
      puts <<-HELP
      galaxy-ledger extract-file - Extract from guideline/implementation plan

      USAGE:
        galaxy-ledger extract-file --session SESSION_ID --type TYPE --path PATH < content

      DESCRIPTION:
        Called by hooks to extract rules or context from special files
        using Claude CLI.

        This is an internal command used by the PostToolUse hook.

      TYPES:
        guideline           Extract coding guidelines and rules
        implementation_plan Extract project context and progress
      HELP
    end
  end
end
