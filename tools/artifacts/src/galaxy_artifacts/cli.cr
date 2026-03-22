require "json"

module GalaxyArtifacts
  module CLI
    def self.run(args : Array(String))
      if args.empty?
        show_help
        return
      end

      command = args.first
      rest = args[1..]

      case command
      when "save"
        if rest.includes?("-h") || rest.includes?("--help")
          show_save_help
        else
          handle_save(rest)
        end
      when "list"
        if rest.includes?("-h") || rest.includes?("--help")
          show_list_help
        else
          handle_list(rest)
        end
      when "view"
        if rest.includes?("-h") || rest.includes?("--help")
          show_view_help
        else
          handle_view(rest)
        end
      when "open"
        if rest.includes?("-h") || rest.includes?("--help")
          show_open_help
        else
          handle_open(rest)
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
      when "install"
        if InstallManager.install
          puts "galaxy-artifacts: skills installed"
        else
          STDERR.puts "Error: install failed"
          exit(1)
        end
      when "uninstall"
        if InstallManager.uninstall
          puts "galaxy-artifacts: skills uninstalled"
        else
          STDERR.puts "Error: uninstall failed"
          exit(1)
        end
      when "version"
        puts "galaxy-artifacts #{VERSION}"
      when "help", "-h", "--help"
        show_help
      when "-v", "--version"
        puts "galaxy-artifacts #{VERSION}"
      else
        STDERR.puts "Error: Unknown command '#{command}'"
        STDERR.puts "Run 'galaxy-artifacts --help' for usage"
        exit(1)
      end
    end

    # Text-based artifact types that can be viewed inline
    VIEWABLE_ARTIFACT_TYPES = Set{"markdown", "csv", "text", "mermaid", "data", "html"}

    # ============================================================
    # save
    # ============================================================

    private def self.handle_save(args : Array(String))
      pid_str : String? = nil
      ledger_session_id_str : String? = nil
      title : String? = nil
      source_path : String? = nil
      description : String? = nil
      artifact_type : String? = nil
      mime_type : String? = nil
      content_hash_arg : String? = nil
      file_size_arg : Int64? = nil

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
        when "--title"
          if i + 1 < args.size
            title = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --title requires a value"
            exit(1)
          end
        when "--source-path"
          if i + 1 < args.size
            source_path = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --source-path requires a value"
            exit(1)
          end
        when "--description"
          if i + 1 < args.size
            description = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --description requires a value"
            exit(1)
          end
        when "--artifact-type"
          if i + 1 < args.size
            artifact_type = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --artifact-type requires a value"
            exit(1)
          end
        when "--mime-type"
          if i + 1 < args.size
            mime_type = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --mime-type requires a value"
            exit(1)
          end
        when "--content-hash"
          if i + 1 < args.size
            content_hash_arg = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --content-hash requires a value"
            exit(1)
          end
        when "--file-size"
          if i + 1 < args.size
            file_size_arg = args[i + 1].to_i64?
            i += 2
          else
            STDERR.puts "Error: --file-size requires a value"
            exit(1)
          end
        else
          STDERR.puts "Error: Unknown option '#{arg}'"
          STDERR.puts "Run 'galaxy-artifacts save --help' for usage"
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
        STDERR.puts "Run 'galaxy-artifacts save --help' for usage"
        exit(1)
      end

      unless source_path
        STDERR.puts "Error: --source-path is required"
        STDERR.puts "Run 'galaxy-artifacts save --help' for usage"
        exit(1)
      end

      unless File.exists?(source_path)
        STDERR.puts "Error: file not found: #{source_path}"
        exit(1)
      end

      original_filename = File.basename(source_path)
      artifact_title = title || ArtifactStorage.title_from_filename(original_filename)

      # Use provided type/mime or defaults
      effective_artifact_type = artifact_type || "text"
      effective_mime_type = mime_type || "application/octet-stream"

      # Compute hash and size from file if not provided
      hash = content_hash_arg || ArtifactStorage.file_hash(source_path)
      fsize = file_size_arg || ArtifactStorage.file_size(source_path)

      # Save DB record (upserts on source_path within session)
      result = Database.save_artifact(
        ledger_session_id,
        title: artifact_title,
        artifact_type: effective_artifact_type,
        mime_type: effective_mime_type,
        original_filename: original_filename,
        stored_path: "", # Placeholder
        source_path: source_path,
        file_size: fsize,
        content_hash: hash,
        description: description,
      )

      if result.action.failed?
        STDERR.puts "Error: failed to save artifact"
        exit(1)
      end

      number = result.number

      # Enrichment means same file, same content — skip file copy.
      unless result.action.enrichment?
        # Insert or VersionUpdate — store/overwrite the file.
        stored = ArtifactStorage.store(
          ledger_session_id, number, source_path, original_filename,
        )

        if stored
          Database.update_artifact_stored_path(ledger_session_id, number, stored)
        end
      end

      # Publish event
      EventPublisher.publish(
        ledger_session_id,
        "artifact.saved",
        ref: number.to_s,
      )

      action_label = result.action.insert? ? "saved" : "updated"
      puts "Artifact ##{number} #{action_label} (title: \"#{artifact_title}\", type: #{effective_artifact_type}, size: #{format_file_size(fsize)})"
    end

    # ============================================================
    # list
    # ============================================================

    private def self.handle_list(args : Array(String))
      pid_str : String? = nil
      session_id : String? = nil
      ledger_session_id_str : String? = nil
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
        when "--json"
          json_mode = true
          i += 1
        else
          STDERR.puts "Error: Unknown option '#{arg}'"
          STDERR.puts "Run 'galaxy-artifacts list --help' for usage"
          exit(1)
        end
      end

      # Resolve to ledger_session_id
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
        STDERR.puts "Run 'galaxy-artifacts list --help' for usage"
        exit(1)
      end

      artifacts = Database.list_artifacts(ledger_session_id)

      if json_mode
        JSON.build(STDOUT) do |json|
          json.object do
            json.field "artifacts" do
              json.array do
                artifacts.each do |art|
                  json.object do
                    json.field "number", art.number
                    json.field "title", art.title
                    json.field "artifact_type", art.artifact_type
                    json.field "mime_type", art.mime_type
                    json.field "original_filename", art.original_filename
                    json.field "file_size", art.file_size
                    json.field "source_path", art.source_path
                    json.field "created_at", art.created_at
                    json.field "description", art.description
                  end
                end
              end
            end
          end
        end
        puts ""
        return
      end

      if artifacts.empty?
        puts "No artifacts for this session."
        return
      end

      puts "Artifacts for session (#{artifacts.size} total):"
      puts ""

      artifacts.each do |art|
        size_formatted = format_file_size(art.file_size)
        timestamp = format_timestamp(art.created_at)
        puts "  ##{art.number}  [#{art.artifact_type}]  \"#{art.title}\"  #{size_formatted}  #{timestamp}"
      end
    end

    # ============================================================
    # view
    # ============================================================

    private def self.handle_view(args : Array(String))
      pid_str : String? = nil
      ledger_session_id_str : String? = nil
      number : Int32? = nil

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
        else
          # Try as positional number
          if n = arg.to_i?
            number = n
          else
            STDERR.puts "Error: Unknown option '#{arg}'"
            STDERR.puts "Run 'galaxy-artifacts view --help' for usage"
            exit(1)
          end
          i += 1
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
        STDERR.puts "Run 'galaxy-artifacts view --help' for usage"
        exit(1)
      end

      unless number
        STDERR.puts "Error: artifact number is required"
        STDERR.puts "Run 'galaxy-artifacts view --help' for usage"
        exit(1)
      end

      artifact = Database.get_artifact_by_number(ledger_session_id, number)

      unless artifact
        STDERR.puts "Error: artifact ##{number} not found"
        exit(1)
      end

      unless VIEWABLE_ARTIFACT_TYPES.includes?(artifact.artifact_type)
        STDERR.puts "Error: artifact ##{number} is a #{artifact.artifact_type} file (binary) \u2014 use 'open' instead"
        exit(1)
      end

      stored_path = artifact.stored_path
      unless File.exists?(stored_path)
        STDERR.puts "Error: stored file not found at #{stored_path}"
        exit(1)
      end

      puts File.read(stored_path)
    end

    # ============================================================
    # open
    # ============================================================

    private def self.handle_open(args : Array(String))
      pid_str : String? = nil
      ledger_session_id_str : String? = nil
      number : Int32? = nil

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
        else
          # Try as positional number
          if n = arg.to_i?
            number = n
          else
            STDERR.puts "Error: Unknown option '#{arg}'"
            STDERR.puts "Run 'galaxy-artifacts open --help' for usage"
            exit(1)
          end
          i += 1
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
        STDERR.puts "Run 'galaxy-artifacts open --help' for usage"
        exit(1)
      end

      unless number
        STDERR.puts "Error: artifact number is required"
        STDERR.puts "Run 'galaxy-artifacts open --help' for usage"
        exit(1)
      end

      artifact = Database.get_artifact_by_number(ledger_session_id, number)

      unless artifact
        STDERR.puts "Error: artifact ##{number} not found"
        exit(1)
      end

      stored_path = artifact.stored_path
      unless File.exists?(stored_path)
        STDERR.puts "Error: stored file not found at #{stored_path}"
        exit(1)
      end

      # Open with macOS `open` command
      begin
        process = Process.new(
          "open",
          args: [stored_path],
          shell: false,
          input: Process::Redirect::Inherit,
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit,
        )
        process.wait
      rescue ex
        STDERR.puts "Error: failed to open artifact: #{ex.message}"
        exit(1)
      end

      puts "Opened artifact ##{number} (\"#{artifact.title}\") \u2192 #{stored_path}"
    end

    # ============================================================
    # delete
    # ============================================================

    private def self.handle_delete(args : Array(String))
      pid_str : String? = nil
      ledger_session_id_str : String? = nil
      number : Int32? = nil

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
        else
          # Try as positional number
          if n = arg.to_i?
            number = n
          else
            STDERR.puts "Error: Unknown option '#{arg}'"
            STDERR.puts "Run 'galaxy-artifacts delete --help' for usage"
            exit(1)
          end
          i += 1
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
        STDERR.puts "Run 'galaxy-artifacts delete --help' for usage"
        exit(1)
      end

      unless number
        STDERR.puts "Error: artifact number is required"
        STDERR.puts "Run 'galaxy-artifacts delete --help' for usage"
        exit(1)
      end

      result = Database.delete_artifact_by_number(ledger_session_id, number)

      if result
        EventPublisher.publish(
          ledger_session_id,
          "artifact.deleted",
          ref: number.to_s,
        )
        puts "Artifact ##{number} deleted"
      else
        STDERR.puts "Error: artifact ##{number} not found"
        exit(1)
      end
    end

    # ============================================================
    # stats
    # ============================================================

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
          # accepted but stats always outputs JSON
          i += 1
        else
          STDERR.puts "Error: Unknown option '#{arg}'"
          STDERR.puts "Run 'galaxy-artifacts stats --help' for usage"
          exit(1)
        end
      end

      # Resolve to ledger_session_id
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
        STDERR.puts "Run 'galaxy-artifacts stats --help' for usage"
        exit(1)
      end

      count = Database.session_artifact_count(ledger_session_id)

      JSON.build(STDOUT) do |json|
        json.object do
          json.field "count", count
        end
      end
      puts ""
    end

    # ============================================================
    # backup
    # ============================================================

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
        puts "Backups are disabled. Enable with: galaxy-artifacts config set backups.enabled true"
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

    # ============================================================
    # Session Resolution Helpers
    # ============================================================

    # Resolve --pid to ledger_session_id via ledger CLI
    private def self.resolve_pid_to_ledger_session_id(
      pid_str : String,
    ) : Int64
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

    # Resolve --session to ledger_session_id via ledger CLI
    private def self.resolve_session_to_ledger_session_id(
      session_identifier : String,
    ) : Int64
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run(
        LEDGER_BIN.to_s,
        args: ["resolve-session", "--session", session_identifier],
        output: output,
        error: error,
      )

      unless status.success?
        err = error.to_s.strip
        if err.empty?
          STDERR.puts(
            "Error: failed to resolve session '#{session_identifier}'",
          )
        else
          STDERR.puts err
        end
        exit(1)
      end

      result = output.to_s.strip.to_i64?
      unless result
        STDERR.puts(
          "Error: invalid response from ledger " \
          "for session '#{session_identifier}'",
        )
        exit(1)
      end

      result
    end

    private def self.resolve_ledger_session_id_str(
      id_str : String,
    ) : Int64
      id = id_str.to_i64?
      unless id
        STDERR.puts(
          "Error: invalid --ledger-session-id value " \
          "'#{id_str}' (must be an integer)",
        )
        exit(1)
      end
      id
    end

    # ============================================================
    # Formatting Helpers
    # ============================================================

    # Format file size for display (e.g., 1024 -> "1.0k", 1048576 -> "1.0M")
    private def self.format_file_size(bytes : Int64) : String
      if bytes >= 1_048_576
        "#{"%.1f" % (bytes / 1_048_576.0)}M"
      elsif bytes >= 1024
        "#{"%.1f" % (bytes / 1024.0)}k"
      else
        "#{bytes}B"
      end
    end

    # Format size for backup display (matches snapshots)
    private def self.format_size(bytes : Int64) : String
      if bytes < 1024
        "#{bytes} B"
      elsif bytes < 1024 * 1024
        "%.1f KB" % (bytes / 1024.0)
      else
        "%.1f MB" % (bytes / (1024.0 * 1024.0))
      end
    end

    private def self.format_timestamp(utc_str : String) : String
      begin
        utc_time = Time.parse_utc(utc_str, "%Y-%m-%d %H:%M:%S")
        local_time = utc_time.to_local
        hour = local_time.hour % 12
        hour = 12 if hour == 0
        ampm = local_time.hour >= 12 ? "PM" : "AM"
        "#{local_time.to_s("%m/%d/%Y")} #{hour}:#{local_time.to_s("%M")} #{ampm}"
      rescue
        utc_str # Fallback to raw string
      end
    end

    # ============================================================
    # Help Text
    # ============================================================

    private def self.show_help
      puts <<-HELP
      galaxy-artifacts - Manage session artifacts

      USAGE:
        galaxy-artifacts <command> [options]

      COMMANDS:
        save        Register an artifact from a file path
        list        List artifacts for a session
        view        View a text artifact's content
        open        Open an artifact in native app
        delete      Delete an artifact
        stats       Get artifact count for a session (JSON)
        backup      Manage database backups
        install     Install skills
        uninstall   Remove skills
        version     Show version

      Run 'galaxy-artifacts <command> --help' for detailed usage.
      HELP
    end

    private def self.show_save_help
      puts <<-HELP
      galaxy-artifacts save - Register an artifact

      USAGE:
        galaxy-artifacts save --pid PID --source-path PATH [options]
        galaxy-artifacts save --ledger-session-id ID --source-path PATH [options]

      REQUIRED:
        --source-path PATH    Path to the file to store as an artifact

      REQUIRED (one of):
        --pid PID               Claude Code process ID
        --ledger-session-id ID  Direct ledger session ID

      OPTIONS:
        --title TITLE           Descriptive title (default: derived from filename)
        --description TEXT       Context about what this artifact contains
        --artifact-type TYPE    Artifact type (default: "text")
        --mime-type MIME        MIME type (default: "application/octet-stream")
        --content-hash HASH     SHA256 hash (default: computed from file)
        --file-size BYTES       File size in bytes (default: computed from file)

      DESCRIPTION:
        Copies the source file to artifact storage and creates a session-scoped
        artifact record. The original file is left in place. If the same source
        path was already saved in this session, the existing artifact is updated
        (enrichment or version update depending on content hash).
      HELP
    end

    private def self.show_list_help
      puts <<-HELP
      galaxy-artifacts list - List session artifacts

      USAGE:
        galaxy-artifacts list --pid PID
        galaxy-artifacts list --session SESSION_ID
        galaxy-artifacts list --ledger-session-id ID

      REQUIRED (one of):
        --pid PID                Claude Code process ID
        --session ID             Session identifier
        --ledger-session-id ID   Direct ledger session ID

      OPTIONS:
        --json                   Output as JSON (envelope: {"artifacts":[...]})

      DESCRIPTION:
        Lists all artifacts for the specified session with number, type,
        title, size, and timestamp.
      HELP
    end

    private def self.show_view_help
      puts <<-HELP
      galaxy-artifacts view - View a text artifact

      USAGE:
        galaxy-artifacts view --pid PID NUMBER
        galaxy-artifacts view --ledger-session-id ID NUMBER

      REQUIRED:
        --pid PID                Claude Code process ID (or use --ledger-session-id)
        --ledger-session-id ID   Direct ledger session ID (or use --pid)
        NUMBER                   Artifact number (session-scoped)

      DESCRIPTION:
        Outputs the content of a text-based artifact to stdout. Only works
        for text-based types (markdown, csv, text, mermaid, data, html).
        For binary artifacts (pdf, image), use 'open' instead.
      HELP
    end

    private def self.show_open_help
      puts <<-HELP
      galaxy-artifacts open - Open an artifact

      USAGE:
        galaxy-artifacts open --pid PID NUMBER
        galaxy-artifacts open --ledger-session-id ID NUMBER

      REQUIRED:
        --pid PID                Claude Code process ID (or use --ledger-session-id)
        --ledger-session-id ID   Direct ledger session ID (or use --pid)
        NUMBER                   Artifact number (session-scoped)

      DESCRIPTION:
        Opens the stored artifact file with the macOS default application.
        Works for all artifact types (PDFs, images, text files, etc.).
      HELP
    end

    private def self.show_delete_help
      puts <<-HELP
      galaxy-artifacts delete - Delete an artifact

      USAGE:
        galaxy-artifacts delete --pid PID NUMBER
        galaxy-artifacts delete --ledger-session-id ID NUMBER

      REQUIRED:
        --pid PID                Claude Code process ID (or use --ledger-session-id)
        --ledger-session-id ID   Direct ledger session ID (or use --pid)
        NUMBER                   Artifact number (session-scoped)

      DESCRIPTION:
        Permanently deletes an artifact record and its stored file.
      HELP
    end

    private def self.show_stats_help
      puts <<-HELP
      galaxy-artifacts stats - Get artifact count for a session

      USAGE:
        galaxy-artifacts stats --pid PID
        galaxy-artifacts stats --session SESSION_ID
        galaxy-artifacts stats --ledger-session-id ID

      REQUIRED (one of):
        --pid PID                Claude Code process ID
        --session ID             Session identifier
        --ledger-session-id ID   Direct ledger session ID

      DESCRIPTION:
        Returns JSON with artifact count for the session.
        Used for budget decisions and context handoff.

        Output: {"count": N}
      HELP
    end

    private def self.show_backup_help
      puts <<-HELP
      galaxy-artifacts backup - Manage database backups

      USAGE:
        galaxy-artifacts backup                        Create a backup and prune old ones
        galaxy-artifacts backup --list                 List all backups
        galaxy-artifacts backup --prune-only           Prune old backups without creating new one

      OPTIONS:
        --session-id ID   Session record ID for backup filename (default: 0)
        --list            List all existing backups
        --prune-only      Only prune old backups, don't create a new one

      CONFIGURATION:
        backups.enabled          Enable/disable automatic backups (default: true)
        backups.retention_days   Days of backups to keep (default: 3)
        backups.path             Custom backup directory (default: ~/.claude/galaxy/data/backups/artifacts)

      DESCRIPTION:
        Creates point-in-time database backups using SQLite VACUUM INTO.
        Each backup is named with the session ID and stored in date-based
        filenames. Old backups are automatically pruned based on the
        retention_days setting.

      EXAMPLES:
        galaxy-artifacts backup                   # Create backup + prune
        galaxy-artifacts backup --list            # See all backups
        galaxy-artifacts backup --prune-only      # Clean up old backups
      HELP
    end
  end
end
