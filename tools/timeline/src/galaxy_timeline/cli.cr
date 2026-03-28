require "json"

module GalaxyTimeline
  module CLI
    def self.run(args : Array(String))
      if args.empty?
        show_help
        return
      end

      command = args.first
      rest = args[1..]

      case command
      when "record"
        if rest.includes?("-h") || rest.includes?("--help")
          show_record_help
        else
          handle_record(rest)
        end
      when "list"
        if rest.includes?("-h") || rest.includes?("--help")
          show_list_help
        else
          handle_list(rest)
        end
      when "show"
        if rest.includes?("-h") || rest.includes?("--help")
          show_show_help
        else
          handle_show(rest)
        end
      when "update"
        if rest.includes?("-h") || rest.includes?("--help")
          show_update_help
        else
          handle_update(rest)
        end
      when "delete"
        if rest.includes?("-h") || rest.includes?("--help")
          show_delete_help
        else
          handle_delete(rest)
        end
      when "stats"
        if rest.includes?("-h") || rest.includes?("--help")
          show_stats_help
        else
          handle_stats(rest)
        end
      when "backup"
        handle_backup_command(rest)
      when "version"
        puts "galaxy-timeline #{VERSION}"
      when "help", "-h", "--help"
        show_help
      when "-v", "--version"
        puts "galaxy-timeline #{VERSION}"
      else
        STDERR.puts "Error: Unknown command '#{command}'"
        STDERR.puts "Run 'galaxy-timeline --help' for usage"
        exit(1)
      end
    end

    # ========================================================
    # record
    # ========================================================

    private def self.handle_record(args : Array(String))
      pid_str : String? = nil
      ledger_session_id_str : String? = nil
      event_type : String? = nil
      source : String? = nil
      occurred_at : String? = nil
      detail_data : String? = nil
      json_mode = false

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--pid"
          if i + 1 < args.size
            pid_str = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --pid requires a value"
            exit(1)
          end
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --ledger-session-id requires a value"
            exit(1)
          end
        when "--event-type"
          if i + 1 < args.size
            event_type = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --event-type requires a value"
            exit(1)
          end
        when "--source"
          if i + 1 < args.size
            source = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --source requires a value"
            exit(1)
          end
        when "--occurred-at"
          if i + 1 < args.size
            occurred_at = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --occurred-at requires a value"
            exit(1)
          end
        when "--detail-data"
          if i + 1 < args.size
            detail_data = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --detail-data requires a value"
            exit(1)
          end
        when "--json"
          json_mode = true
          i += 1
        else
          STDERR.puts "Error: Unknown option '#{arg}'"
          STDERR.puts "Run 'galaxy-timeline record --help' for usage"
          exit(1)
        end
      end

      # Resolve ledger_session_id
      ledger_session_id : Int64? = nil
      if lsid_str = ledger_session_id_str
        ledger_session_id = resolve_ledger_session_id_str(lsid_str)
      elsif ps = pid_str
        ledger_session_id = resolve_pid_to_ledger_session_id(ps)
      end

      unless ledger_session_id
        STDERR.puts "Error: --pid or --ledger-session-id is required"
        exit(1)
      end

      unless event_type
        STDERR.puts "Error: --event-type is required"
        exit(1)
      end

      unless source
        STDERR.puts "Error: --source is required"
        exit(1)
      end

      id = Database.record_event(
        ledger_session_id,
        event_type: event_type,
        source: source,
        occurred_at: occurred_at,
        detail_data: detail_data,
      )

      if id > 0
        EventPublisher.publish(
          ledger_session_id,
          "timeline.event_recorded",
          ref: id.to_s,
        )
        if json_mode
          puts ({id: id}).to_json
        else
          puts "Event ##{id} recorded " \
               "(type: #{event_type}, source: #{source})"
        end
      else
        STDERR.puts "Error: failed to record event"
        exit(1)
      end
    end

    # ========================================================
    # list
    # ========================================================

    private def self.handle_list(args : Array(String))
      pid_str : String? = nil
      session_id : String? = nil
      ledger_session_id_str : String? = nil
      event_type_filter : String? = nil
      json_mode = false

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--pid"
          if i + 1 < args.size
            pid_str = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --pid requires a value"
            exit(1)
          end
        when "--session"
          if i + 1 < args.size
            session_id = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --session requires a value"
            exit(1)
          end
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --ledger-session-id requires a value"
            exit(1)
          end
        when "--event-type"
          if i + 1 < args.size
            event_type_filter = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --event-type requires a value"
            exit(1)
          end
        when "--json"
          json_mode = true
          i += 1
        else
          STDERR.puts "Error: Unknown option '#{arg}'"
          STDERR.puts "Run 'galaxy-timeline list --help' for usage"
          exit(1)
        end
      end

      ledger_session_id : Int64? = nil
      if lsid_str = ledger_session_id_str
        ledger_session_id = resolve_ledger_session_id_str(lsid_str)
      elsif ps = pid_str
        ledger_session_id = resolve_pid_to_ledger_session_id(ps)
      elsif sid = session_id
        ledger_session_id = resolve_session_to_ledger_session_id(sid)
      end

      unless ledger_session_id
        STDERR.puts "Error: --pid, --session, or --ledger-session-id is required"
        exit(1)
      end

      events = Database.list_events(
        ledger_session_id,
        event_type: event_type_filter,
      )

      if json_mode
        JSON.build(STDOUT) do |json|
          json.object do
            json.field "events" do
              json.array do
                events.each do |ev|
                  json.object do
                    json.field "id", ev.id
                    json.field "event_type", ev.event_type
                    json.field "occurred_at", ev.occurred_at
                    json.field "source", ev.source
                    json.field "detail_data", ev.detail_data
                    json.field "created_at", ev.created_at
                    json.field "updated_at", ev.updated_at
                  end
                end
              end
            end
          end
        end
        puts ""
        return
      end

      if events.empty?
        puts "No events for this session."
        return
      end

      puts "Events for session (#{events.size} total):"
      puts ""

      events.each do |ev|
        ts = format_timestamp(ev.occurred_at)
        puts "  ##{ev.id}  [#{ev.event_type}]  #{ts}  (#{ev.source})"
      end
    end

    # ========================================================
    # show
    # ========================================================

    private def self.handle_show(args : Array(String))
      event_id : Int64? = nil
      json_mode = false

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--json"
          json_mode = true
          i += 1
        else
          if n = arg.to_i64?
            event_id = n
          else
            STDERR.puts "Error: Unknown option '#{arg}'"
            STDERR.puts "Run 'galaxy-timeline show --help' for usage"
            exit(1)
          end
          i += 1
        end
      end

      unless event_id
        STDERR.puts "Error: event ID is required"
        exit(1)
      end

      event = Database.get_event(event_id)

      unless event
        STDERR.puts "Error: event ##{event_id} not found"
        exit(1)
      end

      if json_mode
        JSON.build(STDOUT) do |json|
          json.object do
            json.field "id", event.id
            json.field "event_type", event.event_type
            json.field "occurred_at", event.occurred_at
            json.field "source", event.source
            json.field "detail_data", event.detail_data
            json.field "ledger_session_id", event.ledger_session_id
            json.field "created_at", event.created_at
            json.field "updated_at", event.updated_at
          end
        end
        puts ""
      else
        puts "Event ##{event.id}"
        puts "  Type:       #{event.event_type}"
        puts "  Occurred:   #{format_timestamp(event.occurred_at)}"
        puts "  Source:     #{event.source}"
        puts "  Session:    #{event.ledger_session_id}"
        puts "  Created:    #{format_timestamp(event.created_at)}"
        puts "  Updated:    #{format_timestamp(event.updated_at)}"
        if dd = event.detail_data
          puts "  Detail:     #{dd}"
        end
      end
    end

    # ========================================================
    # update
    # ========================================================

    private def self.handle_update(args : Array(String))
      event_id : Int64? = nil
      detail_data : String? = nil
      detail_data_stdin = false

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--detail-data"
          if i + 1 < args.size
            detail_data = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --detail-data requires a value"
            exit(1)
          end
        when "--detail-data-stdin"
          detail_data_stdin = true
          i += 1
        else
          if n = arg.to_i64?
            event_id = n
          else
            STDERR.puts "Error: Unknown option '#{arg}'"
            STDERR.puts "Run 'galaxy-timeline update --help' for usage"
            exit(1)
          end
          i += 1
        end
      end

      unless event_id
        STDERR.puts "Error: event ID is required"
        exit(1)
      end

      # --detail-data-stdin takes precedence over --detail-data
      if detail_data_stdin
        stdin_content = STDIN.gets_to_end
        unless stdin_content.strip.empty?
          detail_data = stdin_content
        end
      end

      result = Database.update_event(event_id, detail_data)

      if result
        puts "Event ##{event_id} updated"
      else
        STDERR.puts "Error: event ##{event_id} not found"
        exit(1)
      end
    end

    # ========================================================
    # delete
    # ========================================================

    private def self.handle_delete(args : Array(String))
      event_id : Int64? = nil

      i = 0
      while i < args.size
        arg = args[i]
        if n = arg.to_i64?
          event_id = n
        else
          STDERR.puts "Error: Unknown option '#{arg}'"
          STDERR.puts "Run 'galaxy-timeline delete --help' for usage"
          exit(1)
        end
        i += 1
      end

      unless event_id
        STDERR.puts "Error: event ID is required"
        exit(1)
      end

      result = Database.delete_event(event_id)

      if result
        puts "Event ##{event_id} deleted"
      else
        STDERR.puts "Error: event ##{event_id} not found"
        exit(1)
      end
    end

    # ========================================================
    # stats
    # ========================================================

    private def self.handle_stats(args : Array(String))
      pid_str : String? = nil
      session_id : String? = nil
      ledger_session_id_str : String? = nil

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--pid"
          if i + 1 < args.size
            pid_str = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --pid requires a value"
            exit(1)
          end
        when "--session"
          if i + 1 < args.size
            session_id = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --session requires a value"
            exit(1)
          end
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --ledger-session-id requires a value"
            exit(1)
          end
        when "--json"
          i += 1
        else
          STDERR.puts "Error: Unknown option '#{arg}'"
          STDERR.puts "Run 'galaxy-timeline stats --help' for usage"
          exit(1)
        end
      end

      ledger_session_id : Int64? = nil
      if lsid_str = ledger_session_id_str
        ledger_session_id = resolve_ledger_session_id_str(lsid_str)
      elsif ps = pid_str
        ledger_session_id = resolve_pid_to_ledger_session_id(ps)
      elsif sid = session_id
        ledger_session_id = resolve_session_to_ledger_session_id(sid)
      end

      unless ledger_session_id
        STDERR.puts "Error: --pid, --session, or --ledger-session-id is required"
        exit(1)
      end

      count = Database.session_event_count(ledger_session_id)

      JSON.build(STDOUT) do |json|
        json.object do
          json.field "count", count
        end
      end
      puts ""
    end

    # ========================================================
    # backup
    # ========================================================

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
        puts "Backup directory: #{backup_dir}"
        return
      end

      date_dirs = [] of String
      Dir.each_child(backup_dir) do |entry|
        entry_path = backup_dir / entry
        next unless File.directory?(entry_path)
        begin
          Time.parse(entry, "%Y-%m-%d", Time::Location.local)
          date_dirs << entry
        rescue Time::Format::Error
        end
      end

      if date_dirs.empty?
        puts "No backups found."
        puts "Backup directory: #{backup_dir}"
        return
      end

      date_dirs.sort!.reverse!

      puts "Backups in #{backup_dir} (retention: #{config.backups.retention_days} days)"
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
        puts "Backups are disabled."
        return
      end

      backup_dir = config.effective_backup_path

      result = Database.backup(backup_dir, session_id)
      if result
        size = File.size(result)
        puts "Backup created: #{result} (#{format_size(size)})"
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

    # ========================================================
    # Session Resolution Helpers
    # ========================================================

    private def self.resolve_pid_to_ledger_session_id(pid_str : String) : Int64
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run(
        LEDGER_BIN.to_s,
        args: ["resolve-session", "--pid", pid_str],
        output: output,
        error: error,
      )

      unless status.success?
        err = error.to_s.strip
        if err.empty?
          STDERR.puts "Error: failed to resolve PID #{pid_str}"
        else
          STDERR.puts err
        end
        exit(1)
      end

      result = output.to_s.strip.to_i64?
      unless result
        STDERR.puts "Error: invalid response from ledger for PID #{pid_str}"
        exit(1)
      end

      result
    end

    private def self.resolve_session_to_ledger_session_id(session_identifier : String) : Int64
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run(
        LEDGER_BIN.to_s,
        args: [
          "resolve-session",
          "--session", session_identifier,
        ],
        output: output,
        error: error,
      )

      unless status.success?
        err = error.to_s.strip
        if err.empty?
          STDERR.puts "Error: failed to resolve session '#{session_identifier}'"
        else
          STDERR.puts err
        end
        exit(1)
      end

      result = output.to_s.strip.to_i64?
      unless result
        STDERR.puts "Error: invalid response from ledger for session '#{session_identifier}'"
        exit(1)
      end

      result
    end

    private def self.resolve_ledger_session_id_str(id_str : String) : Int64
      id = id_str.to_i64?
      unless id
        STDERR.puts "Error: invalid --ledger-session-id value '#{id_str}' (must be an integer)"
        exit(1)
      end
      id
    end

    # ========================================================
    # Formatting Helpers
    # ========================================================

    private def self.format_timestamp(utc_str : String) : String
      begin
        utc_time = Time.parse_utc(utc_str, "%Y-%m-%d %H:%M:%S")
        local_time = utc_time.to_local
        hour = local_time.hour % 12
        hour = 12 if hour == 0
        ampm = local_time.hour >= 12 ? "PM" : "AM"
        "#{local_time.to_s("%m/%d/%Y")} #{hour}:#{local_time.to_s("%M")} #{ampm}"
      rescue
        utc_str
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

    # ========================================================
    # Help Text
    # ========================================================

    private def self.show_help
      puts <<-HELP
      galaxy-timeline - Record and query session events

      USAGE:
        galaxy-timeline <command> [options]

      COMMANDS:
        record    Record a new timeline event
        list      List events for a session
        show      Show event details by ID
        update    Update detail_data on an event
        delete    Delete an event
        stats     Get event count (JSON)
        backup    Manage database backups
        version   Show version

      Run 'galaxy-timeline <command> --help' for details.
      HELP
    end

    private def self.show_record_help
      puts <<-HELP
      galaxy-timeline record - Record a timeline event

      USAGE:
        galaxy-timeline record [options]

      REQUIRED:
        --event-type TYPE       Subject:action format
                                (e.g. session:started)
        --source SOURCE         Tool/module that created
                                the event

      REQUIRED (one of):
        --pid PID               Claude Code process ID
        --ledger-session-id ID  Direct ledger session ID

      OPTIONS:
        --occurred-at DATETIME  When the event occurred
                                (default: now, UTC)
        --detail-data JSON      JSON blob of event details
        --json                  Output event ID as JSON
                                (e.g. {"id":1})
      HELP
    end

    private def self.show_list_help
      puts <<-HELP
      galaxy-timeline list - List session events

      USAGE:
        galaxy-timeline list [options]

      REQUIRED (one of):
        --pid PID               Claude Code process ID
        --session ID            Session identifier
        --ledger-session-id ID  Direct ledger session ID

      OPTIONS:
        --event-type TYPE  Filter by event type
        --json             Output as JSON
      HELP
    end

    private def self.show_show_help
      puts <<-HELP
      galaxy-timeline show - Show event details

      USAGE:
        galaxy-timeline show ID [--json]

      REQUIRED:
        ID                     Event ID (positional)

      OPTIONS:
        --json                 Output as JSON
      HELP
    end

    private def self.show_update_help
      puts <<-HELP
      galaxy-timeline update - Update event detail_data

      USAGE:
        galaxy-timeline update ID --detail-data JSON

      REQUIRED:
        ID                     Event ID (positional)

      OPTIONS (one of):
        --detail-data JSON     Replacement JSON blob
                               (replaces existing data)
        --detail-data-stdin    Read detail_data JSON from
                               stdin (for large payloads)
      HELP
    end

    private def self.show_delete_help
      puts <<-HELP
      galaxy-timeline delete - Delete an event

      USAGE:
        galaxy-timeline delete ID

      REQUIRED:
        ID                     Event ID (positional)
      HELP
    end

    private def self.show_stats_help
      puts <<-HELP
      galaxy-timeline stats - Event count for a session

      USAGE:
        galaxy-timeline stats [options]

      REQUIRED (one of):
        --pid PID               Claude Code process ID
        --session ID            Session identifier
        --ledger-session-id ID  Direct ledger session ID

      Output: {"count": N}
      HELP
    end

    private def self.show_backup_help
      puts <<-HELP
      galaxy-timeline backup - Manage database backups

      USAGE:
        galaxy-timeline backup [options]

      OPTIONS:
        --session-id ID   Session ID for backup filename
        --list            List all existing backups
        --prune-only      Only prune old backups
      HELP
    end
  end
end
