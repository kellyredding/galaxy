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
      when "session"
        handle_session_command(rest)
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
      when "on-session-start"
        handle_on_session_start_command(rest)
      when "on-post-tool-use"
        handle_on_post_tool_use_command(rest)
      when "on-user-prompt-submit"
        handle_on_user_prompt_submit_command(rest)
      when "hooks"
        handle_hooks_command(rest)
      when "extract-user"
        handle_extract_user_command(rest)
      when "extract-assistant"
        handle_extract_assistant_command(rest)
      when "extract-file"
        handle_extract_file_command(rest)
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
        add                 Add an entry (learning, decision, direction, etc.)
        config              Manage configuration
        session             Manage sessions
        hooks               Install/uninstall Claude Code hooks
        version             Show version
        help                Show this help

      Hook Commands (called by Claude Code hooks):
        on-startup          Fresh session startup (ledger awareness)
        on-stop             Capture last exchange, check thresholds
        on-session-start    Restore context after clear/compact
        on-post-tool-use    Track file operations, detect guidelines
        on-user-prompt-submit  Capture user directions/preferences

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

    private def self.handle_session_command(args : Array(String))
      if args.empty?
        show_session_help
        return
      end

      subcommand = args[0]
      rest = args[1..]? || [] of String

      case subcommand
      when "list"
        if rest.includes?("-h") || rest.includes?("--help")
          show_session_list_help
        else
          session_list
        end
      when "show"
        if rest.includes?("-h") || rest.includes?("--help")
          show_session_show_help
        else
          session_show(rest)
        end
      when "remove"
        if rest.includes?("-h") || rest.includes?("--help")
          show_session_remove_help
        else
          session_remove(rest)
        end
      when "help", "-h", "--help"
        show_session_help
      else
        STDERR.puts "Error: Unknown session command '#{subcommand}'"
        STDERR.puts "Run 'galaxy-ledger session --help' for usage"
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
          - context-status.json        Context percentage (from statusline)
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

    private def self.show_session_list_help
      puts <<-HELP
      galaxy-ledger session list - List all sessions

      USAGE:
        galaxy-ledger session list

      DESCRIPTION:
        Lists all sessions in #{SESSIONS_DIR}/.

      OUTPUT:
        For each session shows: session_id | context% | file count | size | age
      HELP
    end

    private def self.show_session_show_help
      puts <<-HELP
      galaxy-ledger session show - Show session details

      USAGE:
        galaxy-ledger session show SESSION_ID

      ARGUMENTS:
        SESSION_ID    The session ID to show details for

      DESCRIPTION:
        Shows detailed information about a session including:
        - Session path and file list
        - Context status (if available)
        - Database entry count
        - Last exchange status
      HELP
    end

    private def self.show_session_remove_help
      puts <<-HELP
      galaxy-ledger session remove - Remove a session completely

      USAGE:
        galaxy-ledger session remove SESSION_ID

      ARGUMENTS:
        SESSION_ID    The session ID to remove

      DESCRIPTION:
        Completely removes a session:
        - Deletes the session folder and all its files
        - Purges entries from SQLite database
        - Purges entries from PostgreSQL (if enabled)

      WARNING:
        This action cannot be undone.
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
      puts "  SQLite purged: #{result.sqlite_purged ? "yes" : "no"}"
      if Config.load.storage.postgres_enabled
        puts "  PostgreSQL purged: #{result.postgres_purged ? "yes" : "no (not implemented yet)"}"
      end
    end

    private def self.truncate(text : String, max_length : Int32) : String
      if text.size <= max_length
        text.gsub("\n", "\\n")
      else
        text[0, max_length - 3].gsub("\n", "\\n") + "..."
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

      entries = Database.search(query, entry_type: entry_type, importance: importance, category: category, prefix_match: prefix_match)

      if entries.empty?
        puts "No results found for: #{query}"
        if entry_type || importance || category
          filters = [] of String
          filters << "type=#{entry_type}" if entry_type
          filters << "importance=#{importance}" if importance
          filters << "category=#{category}" if category
          puts "  Filters: #{filters.join(", ")}"
        end
        return
      end

      puts "Search results for: #{query}"
      if entry_type || importance || category
        filters = [] of String
        filters << "type=#{entry_type}" if entry_type
        filters << "importance=#{importance}" if importance
        filters << "category=#{category}" if category
        puts "  Filters: #{filters.join(", ")}"
      end
      puts "  Found: #{entries.size} entries"
      puts ""

      entries.each_with_index do |entry, idx|
        # Phase 6.2: Show category in header if present
        header = "[#{idx + 1}] #{entry.entry_type} (#{entry.importance})"
        header += " [#{entry.category}]" if entry.category
        puts header
        if source = entry.source
          puts "    Source: #{source}"
        end
        if source_file = entry.source_file
          puts "    File: #{source_file}"
        end
        puts "    Session: #{entry.session_id[0, 8]}..."
        puts "    Content: #{truncate(entry.content, 100)}"
        # Phase 6.2: Show keywords if present
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

      entries = Database.query_recent_filtered(limit, entry_type, importance)

      if entries.empty?
        puts "No entries in ledger."
        if entry_type || importance
          filters = [] of String
          filters << "type=#{entry_type}" if entry_type
          filters << "importance=#{importance}" if importance
          puts "  Filters: #{filters.join(", ")}"
        end
        puts "  Database: #{Database.database_path}"
        return
      end

      total = Database.count
      header = "Recent ledger entries (showing #{entries.size}"
      header += " of #{total}" unless entry_type || importance
      header += "):"
      puts header
      if entry_type || importance
        filters = [] of String
        filters << "type=#{entry_type}" if entry_type
        filters << "importance=#{importance}" if importance
        puts "  Filters: #{filters.join(", ")}"
      end
      puts ""

      entries.each_with_index do |entry, idx|
        # Phase 6.2: Show category in header if present
        header = "[#{idx + 1}] #{entry.entry_type} (#{entry.importance})"
        header += " [#{entry.category}]" if entry.category
        puts header
        if source = entry.source
          puts "    Source: #{source}"
        end
        if source_file = entry.source_file
          puts "    File: #{source_file}"
        end
        puts "    Session: #{entry.session_id[0, 8]}..."
        puts "    Content: #{truncate(entry.content, 100)}"
        # Phase 6.2: Show keywords if present
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

      # Create entry and insert directly into database
      entry = Entry.new(
        entry_type: entry_type,
        content: content,
        importance: importance,
        source: "user"
      )

      success = Database.insert(session_id, entry)

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
        file_read             File read operation
        file_edit             File edit operation
        file_write            File write operation
        search                Search performed
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
        - Creates the session folder if needed
        - Cleans up any orphaned flushing files
        - Injects ledger awareness into the agent context

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
          "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": "## Galaxy Ledger Available\\n..."
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

    private def self.handle_on_session_start_command(args : Array(String))
      if args.first? == "-h" || args.first? == "--help"
        show_on_session_start_help
        return
      end
      handler = Hooks::OnSessionStart.new
      handler.run
    end

    private def self.show_on_session_start_help
      puts <<-HELP
      galaxy-ledger on-session-start - Handle SessionStart(clear|compact) hook

      USAGE:
        galaxy-ledger on-session-start

      DESCRIPTION:
        Called by Claude Code's SessionStart hook after /clear or auto-compact.
        This hook:
        - Prints the last exchange to terminal for user visibility
        - Queries the ledger for context to restore
        - Injects restored context into the agent

      INPUT (stdin):
        JSON object with hook data:
        {
          "session_id": "abc123",
          "transcript_path": "/path/to/transcript.jsonl",
          "cwd": "/current/working/directory",
          "hook_event_name": "SessionStart",
          "source": "clear" | "compact"
        }

      OUTPUT (stdout):
        JSON object with restored context:
        {
          "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": "## Restored Context\\n..."
          }
        }

      HOOK CONFIGURATION:
        Add to ~/.claude/settings.json:
        {
          "hooks": {
            "SessionStart": [{
              "matcher": "clear|compact",
              "hooks": [{
                "type": "command",
                "command": "galaxy-ledger on-session-start",
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

      ENTRY TYPES CREATED:
        - file_read: When a file is read (importance: low)
        - file_edit: When a file is edited (importance: medium)
        - file_write: When a file is created (importance: medium)
        - search: When Glob/Grep is used (importance: low)
        - guideline: When an agent-guideline or *-style.md is read (importance: medium)
        - implementation_plan: When an implementation-plans file is read (importance: medium)

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
          Note: Will be properly classified in Phase 6 extraction

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

    private def self.handle_hooks_command(args : Array(String))
      if args.empty?
        show_hooks_help
        return
      end

      subcommand = args[0]
      rest = args[1..]? || [] of String

      case subcommand
      when "install"
        if rest.includes?("-h") || rest.includes?("--help")
          show_hooks_install_help
        else
          hooks_install
        end
      when "uninstall"
        if rest.includes?("-h") || rest.includes?("--help")
          show_hooks_uninstall_help
        else
          hooks_uninstall
        end
      when "status"
        if rest.includes?("-h") || rest.includes?("--help")
          show_hooks_status_help
        else
          hooks_status
        end
      when "help", "-h", "--help"
        show_hooks_help
      else
        STDERR.puts "Error: Unknown hooks command '#{subcommand}'"
        STDERR.puts "Run 'galaxy-ledger hooks --help' for usage"
        exit(1)
      end
    end

    private def self.show_hooks_help
      puts <<-HELP
      galaxy-ledger hooks - Manage Claude Code hook installation

      USAGE:
        galaxy-ledger hooks install     Install ledger hooks to settings.json
        galaxy-ledger hooks uninstall   Remove ledger hooks from settings.json
        galaxy-ledger hooks status      Check which hooks are installed
        galaxy-ledger hooks help        Show this help

      DESCRIPTION:
        These commands manage the installation of Galaxy Ledger hooks into
        Claude Code's settings.json file. Hooks enable automatic context
        tracking, file operation logging, and context restoration.

      SETTINGS FILE:
        Default: ~/.claude/settings.json
        Override: Set GALAXY_CLAUDE_CONFIG_DIR environment variable

      INSTALLED HOOKS:
        - UserPromptSubmit: Capture user directions/preferences
        - PostToolUse: Track file operations, detect guidelines
        - Stop: Capture last exchange, check context thresholds
        - PreCompact: Sync flush before compaction
        - SessionStart: Restore context after clear/compact, startup awareness
        - SessionEnd: Sync flush on session end

      EXAMPLES:
        galaxy-ledger hooks status
        galaxy-ledger hooks install
        galaxy-ledger hooks uninstall

      TESTING:
        To test without affecting your live Claude Code configuration:
        export GALAXY_CLAUDE_CONFIG_DIR=/tmp/test-claude
        galaxy-ledger hooks install
        cat /tmp/test-claude/settings.json
      HELP
    end

    private def self.show_hooks_install_help
      puts <<-HELP
      galaxy-ledger hooks install - Install ledger hooks

      USAGE:
        galaxy-ledger hooks install

      DESCRIPTION:
        Installs all Galaxy Ledger hooks into Claude Code's settings.json file.
        If hooks are already installed, they will be updated to the latest version.

      SETTINGS FILE:
        #{SETTINGS_FILE}
        (Override with GALAXY_CLAUDE_CONFIG_DIR environment variable)

      WHAT GETS INSTALLED:
        - UserPromptSubmit hook (async): Captures user messages
        - PostToolUse hook (async): Tracks file operations
        - Stop hook: Captures last exchange, shows context warnings
        - PreCompact hook: Reserved for pre-compaction tasks
        - SessionStart hooks: Context restoration and awareness
        - SessionEnd hook: Reserved for session end tasks

      SAFETY:
        Existing non-ledger hooks are preserved.
        To test first, use GALAXY_CLAUDE_CONFIG_DIR=/tmp/test-claude
      HELP
    end

    private def self.show_hooks_uninstall_help
      puts <<-HELP
      galaxy-ledger hooks uninstall - Remove ledger hooks

      USAGE:
        galaxy-ledger hooks uninstall

      DESCRIPTION:
        Removes all Galaxy Ledger hooks from Claude Code's settings.json file.
        Other hooks (non-ledger) are preserved.

      SETTINGS FILE:
        #{SETTINGS_FILE}
        (Override with GALAXY_CLAUDE_CONFIG_DIR environment variable)

      WHAT GETS REMOVED:
        Any hook with a command containing "galaxy-ledger" is removed.
      HELP
    end

    private def self.show_hooks_status_help
      puts <<-HELP
      galaxy-ledger hooks status - Check hook installation status

      USAGE:
        galaxy-ledger hooks status

      DESCRIPTION:
        Shows which Galaxy Ledger hooks are currently installed in
        Claude Code's settings.json file.

      SETTINGS FILE:
        #{SETTINGS_FILE}
        (Override with GALAXY_CLAUDE_CONFIG_DIR environment variable)

      OUTPUT:
        Lists each hook event type and whether ledger hooks are installed for it.
      HELP
    end

    private def self.hooks_install
      puts "Installing Galaxy Ledger hooks..."
      puts "  Settings file: #{SETTINGS_FILE}"

      if HooksManager.install
        puts ""
        puts "✅ Hooks installed successfully!"
        puts ""
        puts "Installed hooks:"
        HooksManager::LEDGER_HOOKS.keys.each do |event|
          puts "  - #{event}"
        end
        puts ""
        puts "Restart Claude Code for hooks to take effect."
      else
        STDERR.puts "❌ Failed to install hooks"
        exit(1)
      end
    end

    private def self.hooks_uninstall
      puts "Uninstalling Galaxy Ledger hooks..."
      puts "  Settings file: #{SETTINGS_FILE}"

      if HooksManager.uninstall
        puts ""
        puts "✅ Hooks uninstalled successfully!"
        puts ""
        puts "Restart Claude Code for changes to take effect."
      else
        STDERR.puts "❌ Failed to uninstall hooks"
        exit(1)
      end
    end

    private def self.hooks_status
      status = HooksManager.status

      puts "Galaxy Ledger Hook Status"
      puts "========================="
      puts ""
      puts "Settings file: #{status.settings_path}"
      puts ""

      if status.installed
        puts "Status: ✅ All hooks installed"
      elsif status.hook_events.empty?
        puts "Status: ❌ No hooks installed"
      else
        puts "Status: ⚠️  Partially installed (#{status.hook_events.size}/#{HooksManager::LEDGER_HOOKS.keys.size})"
      end

      puts ""
      puts "Hook events:"
      HooksManager::LEDGER_HOOKS.keys.each do |event|
        if status.hook_events.includes?(event)
          puts "  ✅ #{event}"
        else
          puts "  ❌ #{event}"
        end
      end

      unless status.installed
        puts ""
        puts "Run 'galaxy-ledger hooks install' to install missing hooks."
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
        inserted = Database.insert_many(session_id, entries)
        if inserted > 0
          STDERR.puts "[galaxy-ledger] Extracted #{inserted} user directions for session #{session_id[0, 8]}..."
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
          inserted = Database.insert_many(session_id, entries)
          if inserted > 0
            STDERR.puts "[galaxy-ledger] Extracted #{inserted} learnings for session #{session_id[0, 8]}..."
          end
        end

        # Update last exchange with summary if we got one
        if summary = result.summary
          last_exchange = Exchange.read(session_id)
          if last_exchange
            # Create updated exchange with summary
            updated = Exchange::LastExchange.new(
              user_message: last_exchange.user_message,
              full_content: last_exchange.full_content,
              assistant_messages: last_exchange.assistant_messages,
              user_timestamp: last_exchange.user_timestamp,
              summary: summary,
            )
            Exchange.write(session_id, updated)
            STDERR.puts "[galaxy-ledger] Updated last exchange with summary"
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
      # Phase 6.2: Entries now include category, keywords, applies_when, source_file
      if result.extractions.any?
        entries = result.extractions.select(&.valid?).map do |e|
          e.to_entry
        end
        inserted = Database.insert_many(session_id, entries)
        if inserted > 0
          STDERR.puts "[galaxy-ledger] Extracted #{inserted} #{extraction_type} entries from #{File.basename(file_path)}"
        end
      end
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
