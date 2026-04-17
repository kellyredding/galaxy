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
      when "refresh"
        if rest.includes?("-h") || rest.includes?("--help")
          show_refresh_help
        else
          handle_refresh(rest)
        end
      when "show"
        if rest.includes?("-h") || rest.includes?("--help")
          show_show_help
        else
          handle_show(rest)
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
      when "annotation"
        handle_annotation_command(rest)
      when "review"
        handle_review_command(rest)
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

    # Binary artifact types that cannot be viewed inline
    BINARY_ARTIFACT_TYPES = Set{"pdf", "image", "binary"}

    # ============================================================
    # save
    # ============================================================

    private def self.handle_save(args : Array(String))
      pid_str : String? = nil
      ledger_session_id_str : String? = nil
      title : String? = nil
      source_path : String? = nil
      filename : String? = nil
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
        when "--filename"
          if i + 1 < args.size
            filename = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --filename requires a value"
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

      # Dispatch: source-path (file on disk, dedup applies) vs
      # stdin streaming (--filename required, no dedup).
      unless source_path
        handle_save_from_stdin(
          ledger_session_id: ledger_session_id,
          filename: filename,
          title: title,
          description: description,
          artifact_type: artifact_type,
          mime_type: mime_type,
        )
        return
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

      # Publish timeline event (fire-and-forget)
      trigger = content_hash_arg ? "auto" : "manual"
      case result.action
      when .insert?
        TimelinePublisher.artifact_created(
          ledger_session_id,
          number: number,
          title: artifact_title,
          artifact_type: effective_artifact_type,
          source_path: source_path,
          file_size: fsize,
          content_hash: hash,
          trigger: trigger,
        )
      when .version_update?
        TimelinePublisher.artifact_updated(
          ledger_session_id,
          number: number,
          title: artifact_title,
          artifact_type: effective_artifact_type,
          source_path: source_path,
          file_size: fsize,
          content_hash: hash,
          previous_file_size: result.previous_file_size || 0_i64,
          previous_content_hash: result.previous_content_hash || "",
        )

        # Mark annotations stale when content changes
        artifact = Database.get_artifact_by_number(
          ledger_session_id, number,
        )
        if artifact
          stale_count = Database.mark_annotations_stale(
            artifact.id,
          )
          if stale_count > 0
            STDERR.puts(
              "Note: #{stale_count} annotation(s) " \
              "marked stale (content changed)",
            )
          end
        end
      end
      # Enrichment — no timeline event (metadata-only, no
      # content change)

      action_label = result.action.insert? ? "saved" : "updated"
      puts "Artifact ##{number} #{action_label} (title: \"#{artifact_title}\", type: #{effective_artifact_type}, size: #{format_file_size(fsize)})"
    end

    # Save an artifact from stdin. No source file, no dedup —
    # always creates a fresh artifact. Content streams in 64 KB
    # chunks with hash and size computed in a single pass.
    private def self.handle_save_from_stdin(
      ledger_session_id : Int64,
      filename : String?,
      title : String?,
      description : String?,
      artifact_type : String?,
      mime_type : String?,
    )
      unless filename
        STDERR.puts(
          "Error: --filename is required when " \
          "--source-path is not provided",
        )
        STDERR.puts "Run 'galaxy-artifacts save --help' for usage"
        exit(1)
      end

      original_filename = filename
      artifact_title = title ||
                       ArtifactStorage.title_from_filename(original_filename)
      effective_artifact_type = artifact_type || "text"
      effective_mime_type = mime_type || "application/octet-stream"

      # Reserve the upcoming artifact number so we can construct
      # the stored_path before streaming content to disk.
      reserved_number = Database.reserve_next_number(ledger_session_id)
      unless reserved_number
        STDERR.puts "Error: failed to reserve artifact number"
        exit(1)
      end

      # Stream stdin directly into artifact storage. Hash and
      # size are computed on the fly — no in-memory buffering.
      stream_result = ArtifactStorage.stream_stdin(
        ledger_session_id,
        reserved_number,
        original_filename,
      )
      unless stream_result
        STDERR.puts(
          "Error: failed to stream content to storage " \
          "(empty stdin or write error)",
        )
        exit(1)
      end

      path = stream_result[:path]
      hash = stream_result[:hash]
      fsize = stream_result[:size]

      # Insert the DB record. source_path: nil bypasses dedup —
      # save_artifact always inserts when source_path is nil.
      result = Database.save_artifact(
        ledger_session_id,
        title: artifact_title,
        artifact_type: effective_artifact_type,
        mime_type: effective_mime_type,
        original_filename: original_filename,
        stored_path: path,
        source_path: nil,
        file_size: fsize,
        content_hash: hash,
        description: description,
      )

      if result.action.failed?
        # Clean up the orphan file so a retry can reuse the
        # number without colliding on disk.
        File.delete(path) if File.exists?(path)
        STDERR.puts "Error: failed to save artifact"
        exit(1)
      end

      number = result.number

      # Publish timeline event (fire-and-forget).
      TimelinePublisher.artifact_created(
        ledger_session_id,
        number: number,
        title: artifact_title,
        artifact_type: effective_artifact_type,
        source_path: nil,
        file_size: fsize,
        content_hash: hash,
        trigger: "manual",
      )

      puts "Artifact ##{number} saved (title: \"#{artifact_title}\", type: #{effective_artifact_type}, size: #{format_file_size(fsize)})"
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

      if BINARY_ARTIFACT_TYPES.includes?(artifact.artifact_type)
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
    # refresh
    # ============================================================

    private def self.handle_refresh(
      args : Array(String),
    )
      pid_str : String? = nil
      ledger_session_id_str : String? = nil
      number : Int32? = nil
      skip_event = false

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
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        when "--skip-event"
          skip_event = true
          i += 1
        else
          if n = arg.to_i?
            number = n
          else
            STDERR.puts "Error: Unknown option '#{arg}'"
            STDERR.puts(
              "Run 'galaxy-artifacts refresh " \
              "--help' for usage",
            )
            exit(1)
          end
          i += 1
        end
      end

      # Resolve ledger_session_id
      ledger_session_id : Int64? = nil
      if lsid_str = ledger_session_id_str
        ledger_session_id =
          resolve_ledger_session_id_str(lsid_str)
      elsif ps = pid_str
        ledger_session_id =
          resolve_pid_to_ledger_session_id(ps)
      end

      unless ledger_session_id
        STDERR.puts(
          "Error: --pid or --ledger-session-id " \
          "is required",
        )
        STDERR.puts(
          "Run 'galaxy-artifacts refresh " \
          "--help' for usage",
        )
        exit(1)
      end

      unless number
        STDERR.puts "Error: artifact number is required"
        STDERR.puts(
          "Run 'galaxy-artifacts refresh " \
          "--help' for usage",
        )
        exit(1)
      end

      artifact = Database.get_artifact_by_number(
        ledger_session_id, number,
      )

      unless artifact
        STDERR.puts "Error: artifact ##{number} not found"
        exit(1)
      end

      # Re-save from source_path if available and file
      # still exists. This triggers the existing dedup
      # logic: Enrichment if unchanged, VersionUpdate
      # if content changed (which re-copies the file
      # and marks annotations stale).
      resaved = false
      if source = artifact.source_path
        if File.exists?(source)
          hash = ArtifactStorage.file_hash(source)
          fsize = ArtifactStorage.file_size(source)

          result = Database.save_artifact(
            ledger_session_id,
            title: artifact.title,
            artifact_type: artifact.artifact_type,
            mime_type: artifact.mime_type,
            original_filename: artifact.original_filename,
            stored_path: "",
            source_path: source,
            file_size: fsize,
            content_hash: hash,
          )

          unless result.action.failed?
            unless result.action.enrichment?
              stored = ArtifactStorage.store(
                ledger_session_id,
                number,
                source,
                artifact.original_filename,
              )
              if stored
                Database.update_artifact_stored_path(
                  ledger_session_id, number, stored,
                )
              end
            end

            if result.action.version_update?
              updated = Database.get_artifact_by_number(
                ledger_session_id, number,
              )
              if updated
                Database.mark_annotations_stale(updated.id)
              end
            end

            resaved = true
          end
        end
      end

      # Output JSON result for the Swift caller
      JSON.build(STDOUT) do |json|
        json.object do
          json.field "number", artifact.number
          json.field "resaved", resaved
          json.field "has_source", !artifact.source_path.nil?
          json.field(
            "source_exists",
            artifact.source_path.try { |p|
              File.exists?(p)
            } || false,
          )
        end
      end
      puts ""

      # Publish socket event so Galaxy.app can auto-open
      # the artifact reader. Fire-and-forget — works
      # whether or not Galaxy.app is running. Skipped
      # when --skip-event is set (in-app callers that
      # handle their own UI reload).
      unless skip_event
        detail = JSON.build do |json|
          json.object do
            json.field(
              "artifact_number", artifact.number,
            )
          end
        end
        EventPublisher.publish(
          ledger_session_id,
          event: "artifact.show",
          detail_data: detail,
        )
      end
    end

    # ============================================================
    # show
    # ============================================================

    private def self.handle_show(
      args : Array(String),
    )
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
            STDERR.puts(
              "Error: --pid requires a value",
            )
            exit(1)
          end
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        else
          if n = arg.to_i?
            number = n
          else
            STDERR.puts(
              "Error: Unknown option '#{arg}'",
            )
            STDERR.puts(
              "Run 'galaxy-artifacts show " \
              "--help' for usage",
            )
            exit(1)
          end
          i += 1
        end
      end

      # Resolve ledger_session_id
      ledger_session_id : Int64? = nil
      if lsid_str = ledger_session_id_str
        ledger_session_id =
          resolve_ledger_session_id_str(lsid_str)
      elsif ps = pid_str
        ledger_session_id =
          resolve_pid_to_ledger_session_id(ps)
      end

      unless ledger_session_id
        STDERR.puts(
          "Error: --pid or --ledger-session-id " \
          "is required",
        )
        STDERR.puts(
          "Run 'galaxy-artifacts show " \
          "--help' for usage",
        )
        exit(1)
      end

      unless number
        STDERR.puts(
          "Error: artifact number is required",
        )
        STDERR.puts(
          "Run 'galaxy-artifacts show " \
          "--help' for usage",
        )
        exit(1)
      end

      artifact = Database.get_artifact_by_number(
        ledger_session_id, number,
      )

      unless artifact
        STDERR.puts(
          "Error: artifact ##{number} not found",
        )
        exit(1)
      end

      # Publish socket event so Galaxy.app opens
      # the artifact in its reader (or falls back
      # to macOS open for unsupported types).
      detail = JSON.build do |json|
        json.object do
          json.field(
            "artifact_number", artifact.number,
          )
        end
      end
      EventPublisher.publish(
        ledger_session_id,
        event: "artifact.show",
        detail_data: detail,
      )

      puts(
        "Showing artifact ##{number}" \
        " (\"#{artifact.title}\")",
      )
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

      # Fetch artifact metadata before deletion (for timeline event)
      artifact = Database.get_artifact_by_number(
        ledger_session_id, number,
      )

      unless artifact
        STDERR.puts "Error: artifact ##{number} not found"
        exit(1)
      end

      result = Database.delete_artifact_by_number(
        ledger_session_id, number,
      )

      if result
        TimelinePublisher.artifact_deleted(
          ledger_session_id,
          number: number,
          title: artifact.title,
          artifact_type: artifact.artifact_type,
        )
        puts "Artifact ##{number} deleted"
      else
        STDERR.puts(
          "Error: failed to delete artifact ##{number}",
        )
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

      shared_config = SharedBackupConfig.load

      if list_mode
        backup_list(shared_config)
      elsif prune_only
        backup_prune_only(shared_config)
      else
        backup_create_and_prune(shared_config, session_id)
      end
    end

    private def self.backup_list(shared_config : SharedBackupConfig)
      backup_dir = shared_config.effective_backup_path

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

      puts "Backups in #{backup_dir} (retention: #{shared_config.backups.retention_days} days)"
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

    private def self.backup_create_and_prune(shared_config : SharedBackupConfig, session_id : Int64)
      unless shared_config.backups.enabled
        puts "Backups are disabled. Enable with: galaxy config set backups.enabled true"
        return
      end

      backup_dir = shared_config.effective_backup_path

      result = Database.backup(backup_dir, session_id)
      if result
        size = File.size(result)
        puts "Backup created: #{result} (#{format_size(size)})"
      else
        STDERR.puts "Backup failed."
      end

      pruned = Database.prune_backups(backup_dir, shared_config.backups.retention_days)
      if pruned > 0
        puts "Pruned #{pruned} old backup #{pruned == 1 ? "directory" : "directories"}."
      end
    end

    private def self.backup_prune_only(shared_config : SharedBackupConfig)
      backup_dir = shared_config.effective_backup_path
      pruned = Database.prune_backups(backup_dir, shared_config.backups.retention_days)
      if pruned > 0
        puts "Pruned #{pruned} old backup #{pruned == 1 ? "directory" : "directories"}."
      else
        puts "No backups to prune."
      end
    end

    # ============================================================
    # annotation
    # ============================================================

    private def self.handle_annotation_command(
      args : Array(String),
    )
      if args.empty? || args.first? == "-h" || args.first? == "--help"
        show_annotation_help
        return
      end

      subcommand = args[0]
      rest = args[1..]? || [] of String

      case subcommand
      when "create"
        if rest.includes?("-h") || rest.includes?("--help")
          show_annotation_create_help
        else
          annotation_create(rest)
        end
      when "list"
        if rest.includes?("-h") || rest.includes?("--help")
          show_annotation_list_help
        else
          annotation_list(rest)
        end
      when "view"
        if rest.includes?("-h") || rest.includes?("--help")
          show_annotation_view_help
        else
          annotation_view(rest)
        end
      when "update"
        if rest.includes?("-h") || rest.includes?("--help")
          show_annotation_update_help
        else
          annotation_update(rest)
        end
      when "delete"
        if rest.includes?("-h") || rest.includes?("--help")
          show_annotation_delete_help
        else
          annotation_delete(rest)
        end
      else
        STDERR.puts(
          "Error: Unknown annotation command " \
          "'#{subcommand}'",
        )
        STDERR.puts(
          "Run 'galaxy-artifacts annotation --help' " \
          "for usage",
        )
        exit(1)
      end
    end

    # Resolve --artifact-id to the DB primary key of the
    # artifact. Supports direct ID or
    # (--ledger-session-id + --artifact number).
    private def self.resolve_artifact_id(
      artifact_id_str : String?,
      ledger_session_id_str : String?,
      artifact_number : Int32?,
    ) : Int64
      if aid_str = artifact_id_str
        id = aid_str.to_i64?
        unless id
          STDERR.puts(
            "Error: --artifact-id must be a number",
          )
          exit(1)
        end
        return id
      end

      if sess_str = ledger_session_id_str
        session_id = resolve_ledger_session_id_str(
          sess_str,
        )
        unless artifact_number
          STDERR.puts(
            "Error: --artifact is required when " \
            "using --ledger-session-id",
          )
          exit(1)
        end
        artifact = Database.get_artifact_by_number(
          session_id, artifact_number,
        )
        unless artifact
          STDERR.puts(
            "Error: artifact ##{artifact_number} " \
            "not found",
          )
          exit(1)
        end
        return artifact.id
      end

      STDERR.puts(
        "Error: --artifact-id (or " \
        "--ledger-session-id + --artifact) " \
        "is required",
      )
      exit(1)
    end

    # Parse common annotation/review identifier flags.
    # Returns {artifact_id_str, ledger_session_id_str,
    # artifact_number, remaining_index}.
    private def self.parse_artifact_id_args(
      args : Array(String),
      i : Int32,
    ) : {String?, String?, Int32?, Int32}
      artifact_id_str : String? = nil
      ledger_session_id_str : String? = nil
      artifact_number : Int32? = nil

      arg = args[i]
      case arg
      when "--artifact-id"
        if i + 1 < args.size
          artifact_id_str = args[i + 1]
          i += 2
        else
          STDERR.puts(
            "Error: --artifact-id requires a value",
          )
          exit(1)
        end
      when "--ledger-session-id"
        if i + 1 < args.size
          ledger_session_id_str = args[i + 1]
          i += 2
        else
          STDERR.puts(
            "Error: --ledger-session-id " \
            "requires a value",
          )
          exit(1)
        end
      when "--artifact"
        if i + 1 < args.size
          artifact_number = args[i + 1].to_i?
          unless artifact_number
            STDERR.puts(
              "Error: --artifact must be a number",
            )
            exit(1)
          end
          i += 2
        else
          STDERR.puts(
            "Error: --artifact requires a value",
          )
          exit(1)
        end
      end

      {artifact_id_str, ledger_session_id_str,
       artifact_number, i}
    end

    private def self.annotation_create(
      args : Array(String),
    )
      artifact_id_str : String? = nil
      ledger_session_id_str : String? = nil
      artifact_number : Int32? = nil

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--artifact-id"
          if i + 1 < args.size
            artifact_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --artifact-id requires a value",
            )
            exit(1)
          end
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        when "--artifact"
          if i + 1 < args.size
            artifact_number = args[i + 1].to_i?
            unless artifact_number
              STDERR.puts(
                "Error: --artifact must be a number",
              )
              exit(1)
            end
            i += 2
          else
            STDERR.puts(
              "Error: --artifact requires a value",
            )
            exit(1)
          end
        else
          STDERR.puts "Error: Unknown option '#{arg}'"
          STDERR.puts(
            "Run 'galaxy-artifacts annotation " \
            "create --help' for usage",
          )
          exit(1)
        end
      end

      artifact_id = resolve_artifact_id(
        artifact_id_str,
        ledger_session_id_str,
        artifact_number,
      )

      # Read JSON envelope from stdin
      input = STDIN.gets_to_end
      if input.strip.empty?
        STDERR.puts(
          "Error: no input provided on stdin " \
          "(expected JSON with anchor_data and content)",
        )
        exit(1)
      end

      begin
        envelope = JSON.parse(input.strip)
      rescue
        STDERR.puts "Error: invalid JSON on stdin"
        exit(1)
      end

      anchor_data = envelope["anchor_data"]?
      unless anchor_data
        STDERR.puts(
          "Error: missing 'anchor_data' in " \
          "stdin JSON",
        )
        exit(1)
      end

      content = envelope["content"]?.try(&.as_s?)
      unless content && !content.empty?
        STDERR.puts(
          "Error: missing or empty 'content' in " \
          "stdin JSON",
        )
        exit(1)
      end

      # Look up artifact's current content_hash
      artifact = resolve_artifact(artifact_id)
      ann = Database.save_annotation(
        artifact_id,
        content,
        anchor_data.to_json,
        artifact.content_hash,
      )

      if ann
        JSON.build(STDOUT, indent: "  ") do |json|
          json.object do
            json.field "annotation" do
              annotation_to_json(json, ann)
            end
          end
        end
        puts ""

        TimelinePublisher.annotation_created(
          artifact.ledger_session_id,
          artifact_id: artifact_id,
          artifact_number: artifact.number,
          artifact_title: artifact.title,
          annotation_number: ann.number,
          content: ann.content,
        )
      else
        STDERR.puts "Error: failed to create annotation"
        exit(1)
      end
    end

    private def self.annotation_list(
      args : Array(String),
    )
      artifact_id_str : String? = nil
      ledger_session_id_str : String? = nil
      artifact_number : Int32? = nil
      json_output = false

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--artifact-id"
          if i + 1 < args.size
            artifact_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --artifact-id requires a value",
            )
            exit(1)
          end
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        when "--artifact"
          if i + 1 < args.size
            artifact_number = args[i + 1].to_i?
            unless artifact_number
              STDERR.puts(
                "Error: --artifact must be a number",
              )
              exit(1)
            end
            i += 2
          else
            STDERR.puts(
              "Error: --artifact requires a value",
            )
            exit(1)
          end
        when "--json"
          json_output = true
          i += 1
        else
          STDERR.puts "Error: Unknown option '#{arg}'"
          STDERR.puts(
            "Run 'galaxy-artifacts annotation " \
            "list --help' for usage",
          )
          exit(1)
        end
      end

      artifact_id = resolve_artifact_id(
        artifact_id_str,
        ledger_session_id_str,
        artifact_number,
      )
      annotations = Database.list_annotations(artifact_id)

      if json_output
        JSON.build(STDOUT, indent: "  ") do |json|
          json.object do
            json.field "annotations" do
              json.array do
                annotations.each do |ann|
                  annotation_to_json(json, ann)
                end
              end
            end
          end
        end
        puts ""
        return
      end

      if annotations.empty?
        puts "No annotations for this artifact."
        return
      end

      puts "Annotations (#{annotations.size} total):"
      puts ""

      annotations.each do |ann|
        preview = ann.content.gsub('\n', ' ')
        preview = preview.size > 50 ? "#{preview[0, 50]}..." : preview
        stale = ann.stale ? " [stale]" : ""
        timestamp = format_timestamp(ann.created_at)
        puts(
          "  ##{ann.number}  \"#{preview}\"" \
          "#{stale}  #{timestamp}",
        )
      end
    end

    private def self.annotation_view(
      args : Array(String),
    )
      artifact_id_str : String? = nil
      ledger_session_id_str : String? = nil
      artifact_number : Int32? = nil
      number : Int32? = nil

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--artifact-id"
          if i + 1 < args.size
            artifact_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --artifact-id requires a value",
            )
            exit(1)
          end
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        when "--artifact"
          if i + 1 < args.size
            artifact_number = args[i + 1].to_i?
            unless artifact_number
              STDERR.puts(
                "Error: --artifact must be a number",
              )
              exit(1)
            end
            i += 2
          else
            STDERR.puts(
              "Error: --artifact requires a value",
            )
            exit(1)
          end
        else
          if n = arg.to_i?
            number = n
          else
            STDERR.puts "Error: Unknown option '#{arg}'"
            STDERR.puts(
              "Run 'galaxy-artifacts annotation " \
              "view --help' for usage",
            )
            exit(1)
          end
          i += 1
        end
      end

      artifact_id = resolve_artifact_id(
        artifact_id_str,
        ledger_session_id_str,
        artifact_number,
      )

      unless number
        STDERR.puts "Error: annotation number is required"
        STDERR.puts(
          "Run 'galaxy-artifacts annotation " \
          "view --help' for usage",
        )
        exit(1)
      end

      ann = Database.get_annotation(artifact_id, number)

      unless ann
        STDERR.puts(
          "Error: annotation ##{number} not found",
        )
        exit(1)
      end

      JSON.build(STDOUT, indent: "  ") do |json|
        json.object do
          json.field "annotation" do
            annotation_to_json(json, ann)
          end
        end
      end
      puts ""
    end

    private def self.annotation_update(
      args : Array(String),
    )
      artifact_id_str : String? = nil
      ledger_session_id_str : String? = nil
      artifact_number : Int32? = nil
      number : Int32? = nil

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--artifact-id"
          if i + 1 < args.size
            artifact_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --artifact-id requires a value",
            )
            exit(1)
          end
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        when "--artifact"
          if i + 1 < args.size
            artifact_number = args[i + 1].to_i?
            unless artifact_number
              STDERR.puts(
                "Error: --artifact must be a number",
              )
              exit(1)
            end
            i += 2
          else
            STDERR.puts(
              "Error: --artifact requires a value",
            )
            exit(1)
          end
        else
          if n = arg.to_i?
            number = n
          else
            STDERR.puts "Error: Unknown option '#{arg}'"
            STDERR.puts(
              "Run 'galaxy-artifacts annotation " \
              "update --help' for usage",
            )
            exit(1)
          end
          i += 1
        end
      end

      artifact_id = resolve_artifact_id(
        artifact_id_str,
        ledger_session_id_str,
        artifact_number,
      )

      unless number
        STDERR.puts "Error: annotation number is required"
        STDERR.puts(
          "Run 'galaxy-artifacts annotation " \
          "update --help' for usage",
        )
        exit(1)
      end

      # Read content from stdin (plain text, not JSON)
      content = STDIN.gets_to_end
      if content.strip.empty?
        STDERR.puts(
          "Error: no content provided on stdin",
        )
        exit(1)
      end

      ann = Database.update_annotation(
        artifact_id,
        number,
        content.strip,
      )

      if ann
        JSON.build(STDOUT, indent: "  ") do |json|
          json.object do
            json.field "annotation" do
              annotation_to_json(json, ann)
            end
          end
        end
        puts ""

        artifact = resolve_artifact(artifact_id)
        TimelinePublisher.annotation_updated(
          artifact.ledger_session_id,
          artifact_id: artifact_id,
          artifact_number: artifact.number,
          artifact_title: artifact.title,
          annotation_number: ann.number,
          content: ann.content,
        )
      else
        STDERR.puts(
          "Error: annotation ##{number} not found",
        )
        exit(1)
      end
    end

    private def self.annotation_delete(
      args : Array(String),
    )
      artifact_id_str : String? = nil
      ledger_session_id_str : String? = nil
      artifact_number : Int32? = nil
      number : Int32? = nil

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--artifact-id"
          if i + 1 < args.size
            artifact_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --artifact-id requires a value",
            )
            exit(1)
          end
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        when "--artifact"
          if i + 1 < args.size
            artifact_number = args[i + 1].to_i?
            unless artifact_number
              STDERR.puts(
                "Error: --artifact must be a number",
              )
              exit(1)
            end
            i += 2
          else
            STDERR.puts(
              "Error: --artifact requires a value",
            )
            exit(1)
          end
        else
          if n = arg.to_i?
            number = n
          else
            STDERR.puts "Error: Unknown option '#{arg}'"
            STDERR.puts(
              "Run 'galaxy-artifacts annotation " \
              "delete --help' for usage",
            )
            exit(1)
          end
          i += 1
        end
      end

      artifact_id = resolve_artifact_id(
        artifact_id_str,
        ledger_session_id_str,
        artifact_number,
      )

      unless number
        STDERR.puts "Error: annotation number is required"
        STDERR.puts(
          "Run 'galaxy-artifacts annotation " \
          "delete --help' for usage",
        )
        exit(1)
      end

      # Fetch before delete for timeline event content
      ann = Database.get_annotation(artifact_id, number)
      result = Database.delete_annotation(
        artifact_id, number,
      )

      if result
        puts "Annotation ##{number} deleted"

        artifact = resolve_artifact(artifact_id)
        TimelinePublisher.annotation_deleted(
          artifact.ledger_session_id,
          artifact_id: artifact_id,
          artifact_number: artifact.number,
          artifact_title: artifact.title,
          annotation_number: number,
          content: ann.try(&.content),
        )
      else
        STDERR.puts(
          "Error: annotation ##{number} not found",
        )
        exit(1)
      end
    end

    # Serialize an ArtifactAnnotation to JSON fields
    private def self.annotation_to_json(
      json : JSON::Builder,
      ann : Database::ArtifactAnnotation,
    )
      json.object do
        json.field "id", ann.id
        json.field "number", ann.number
        json.field "artifact_id", ann.artifact_id
        json.field "artifact_review_id",
          ann.artifact_review_id
        json.field "review_number", ann.review_number
        json.field "review_reviewed_at",
          ann.review_reviewed_at
        json.field "content", ann.content
        json.field "anchor_data" do
          json.raw(ann.anchor_data)
        end
        json.field "content_hash", ann.content_hash
        json.field "stale", ann.stale
        json.field "created_at", ann.created_at
        json.field "updated_at", ann.updated_at
      end
    end

    # ============================================================
    # review
    # ============================================================

    private def self.handle_review_command(
      args : Array(String),
    )
      if args.empty? || args.first? == "-h" || args.first? == "--help"
        show_review_help
        return
      end

      subcommand = args[0]
      rest = args[1..]? || [] of String

      case subcommand
      when "create"
        if rest.includes?("-h") || rest.includes?("--help")
          show_review_create_help
        else
          review_create(rest)
        end
      when "list"
        if rest.includes?("-h") || rest.includes?("--help")
          show_review_list_help
        else
          review_list(rest)
        end
      when "view"
        if rest.includes?("-h") || rest.includes?("--help")
          show_review_view_help
        else
          review_view(rest)
        end
      when "mark-reviewed"
        if rest.includes?("-h") || rest.includes?("--help")
          show_review_mark_reviewed_help
        else
          review_mark_reviewed(rest)
        end
      when "has-pending"
        if rest.includes?("-h") || rest.includes?("--help")
          show_review_has_pending_help
        else
          review_has_pending(rest)
        end
      else
        STDERR.puts(
          "Error: Unknown review command " \
          "'#{subcommand}'",
        )
        STDERR.puts(
          "Run 'galaxy-artifacts review --help' " \
          "for usage",
        )
        exit(1)
      end
    end

    private def self.review_create(
      args : Array(String),
    )
      artifact_id_str : String? = nil
      ledger_session_id_str : String? = nil
      artifact_number : Int32? = nil

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--artifact-id"
          if i + 1 < args.size
            artifact_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --artifact-id requires a value",
            )
            exit(1)
          end
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        when "--artifact"
          if i + 1 < args.size
            artifact_number = args[i + 1].to_i?
            i += 2
          else
            STDERR.puts(
              "Error: --artifact requires a value",
            )
            exit(1)
          end
        else
          i += 1
        end
      end

      artifact_id = resolve_artifact_id(
        artifact_id_str,
        ledger_session_id_str,
        artifact_number,
      )

      result = Database.save_review(artifact_id)

      unless result
        STDERR.puts(
          "Error: no unreviewed annotations " \
          "to submit",
        )
        exit(1)
      end

      review, annotation_count = result

      artifact = resolve_artifact(artifact_id)
      TimelinePublisher.review_created(
        artifact.ledger_session_id,
        artifact_id: artifact_id,
        artifact_number: artifact.number,
        artifact_title: artifact.title,
        review_number: review.number,
        annotation_count: annotation_count,
      )

      JSON.build(STDOUT) do |json|
        json.object do
          json.field "review" do
            review_to_json(json, review)
          end
          json.field "annotation_count",
            annotation_count
        end
      end
      puts ""
    end

    private def self.review_list(
      args : Array(String),
    )
      artifact_id_str : String? = nil
      ledger_session_id_str : String? = nil
      artifact_number : Int32? = nil
      json_output = false
      pending_only = false

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--artifact-id"
          if i + 1 < args.size
            artifact_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --artifact-id requires a value",
            )
            exit(1)
          end
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        when "--artifact"
          if i + 1 < args.size
            artifact_number = args[i + 1].to_i?
            i += 2
          else
            STDERR.puts(
              "Error: --artifact requires a value",
            )
            exit(1)
          end
        when "--json"
          json_output = true
          i += 1
        when "--pending"
          pending_only = true
          i += 1
        else
          i += 1
        end
      end

      artifact_id = resolve_artifact_id(
        artifact_id_str,
        ledger_session_id_str,
        artifact_number,
      )

      reviews = Database.list_reviews(
        artifact_id,
        pending_only: pending_only,
      )

      if json_output
        JSON.build(STDOUT) do |json|
          json.object do
            json.field "reviews" do
              json.array do
                reviews.each do |review|
                  json.object do
                    json.field "number", review.number
                    json.field "artifact_id",
                      review.artifact_id
                    json.field "created_at",
                      review.created_at
                    json.field "reviewed_at",
                      review.reviewed_at
                    json.field "annotation_count" do
                      anns = Database \
                        .list_annotations_for_review(
                        review.id,
                      )
                      json.number anns.size
                    end
                  end
                end
              end
            end
          end
        end
        puts ""
      else
        if reviews.empty?
          label = pending_only ? "pending reviews" : "reviews"
          puts "No #{label}."
        else
          label = pending_only ? "Pending reviews" : "Reviews"
          puts "#{label} (#{reviews.size} total):"
          reviews.each do |review|
            ann_count = Database \
              .list_annotations_for_review(
              review.id,
            ).size
            status = review.reviewed_at ? "reviewed" : "pending"
            timestamp = format_timestamp(
              review.created_at,
            )
            puts(
              "  ##{review.number}  " \
              "#{ann_count} annotation" \
              "#{ann_count == 1 ? "" : "s"}  " \
              "#{status}  #{timestamp}",
            )
          end
        end
      end
    end

    private def self.review_view(
      args : Array(String),
    )
      artifact_id_str : String? = nil
      ledger_session_id_str : String? = nil
      artifact_number : Int32? = nil
      review_number : Int32? = nil
      json_output = false

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--artifact-id"
          if i + 1 < args.size
            artifact_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --artifact-id requires a value",
            )
            exit(1)
          end
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        when "--artifact"
          if i + 1 < args.size
            artifact_number = args[i + 1].to_i?
            i += 2
          else
            STDERR.puts(
              "Error: --artifact requires a value",
            )
            exit(1)
          end
        when "--json"
          json_output = true
          i += 1
        else
          if n = arg.to_i?
            review_number = n
          end
          i += 1
        end
      end

      artifact_id = resolve_artifact_id(
        artifact_id_str,
        ledger_session_id_str,
        artifact_number,
      )

      unless review_number
        STDERR.puts "Error: review number is required"
        STDERR.puts(
          "Run 'galaxy-artifacts review " \
          "view --help' for usage",
        )
        exit(1)
      end

      review = Database.get_review(
        artifact_id, review_number,
      )
      unless review
        STDERR.puts(
          "Error: review ##{review_number} not found",
        )
        exit(1)
      end

      # Get artifact for context
      artifact = resolve_artifact(artifact_id)
      annotations = Database.list_annotations_for_review(
        review.id,
      )

      if json_output
        JSON.build(STDOUT) do |json|
          json.object do
            json.field "review" do
              review_to_json(json, review)
            end
            json.field "artifact" do
              json.object do
                json.field "id", artifact.id
                json.field "number", artifact.number
                json.field "title", artifact.title
                json.field "artifact_type",
                  artifact.artifact_type
                json.field "ledger_session_id",
                  artifact.ledger_session_id
                json.field "created_at",
                  artifact.created_at
              end
            end
            json.field "annotations" do
              json.array do
                annotations.each do |ann|
                  annotation_to_json(json, ann)
                end
              end
            end
          end
        end
        puts ""
      else
        status = if ra = review.reviewed_at
                   "reviewed #{format_timestamp(ra)}"
                 else
                   "pending"
                 end
        timestamp = format_timestamp(review.created_at)
        puts "Review ##{review.number} (#{status})"
        puts(
          "  Artifact: ##{artifact.number} " \
          "\u2014 #{artifact.title}",
        )
        puts "  Created: #{timestamp}"
        puts "  Annotations (#{annotations.size}):"
        annotations.each do |ann|
          preview = ann.content.gsub('\n', ' ')
          preview = preview[0, 60] + "..." if preview.size > 63
          stale = ann.stale ? " [stale]" : ""
          puts(
            "    ##{ann.number}  " \
            "\"#{preview}\"#{stale}",
          )
        end
      end
    end

    private def self.review_mark_reviewed(
      args : Array(String),
    )
      artifact_id_str : String? = nil
      ledger_session_id_str : String? = nil
      artifact_number : Int32? = nil
      review_number : Int32? = nil

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--artifact-id"
          if i + 1 < args.size
            artifact_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --artifact-id requires a value",
            )
            exit(1)
          end
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        when "--artifact"
          if i + 1 < args.size
            artifact_number = args[i + 1].to_i?
            i += 2
          else
            STDERR.puts(
              "Error: --artifact requires a value",
            )
            exit(1)
          end
        else
          if n = arg.to_i?
            review_number = n
          end
          i += 1
        end
      end

      artifact_id = resolve_artifact_id(
        artifact_id_str,
        ledger_session_id_str,
        artifact_number,
      )

      unless review_number
        STDERR.puts "Error: review number is required"
        STDERR.puts(
          "Run 'galaxy-artifacts review " \
          "mark-reviewed --help' for usage",
        )
        exit(1)
      end

      review = Database.mark_review_reviewed(
        artifact_id,
        review_number,
      )

      unless review
        STDERR.puts(
          "Error: review ##{review_number} not found",
        )
        exit(1)
      end

      JSON.build(STDOUT) do |json|
        json.object do
          json.field "review" do
            review_to_json(json, review)
          end
        end
      end
      puts ""
    end

    private def self.review_has_pending(
      args : Array(String),
    )
      artifact_id_str : String? = nil
      ledger_session_id_str : String? = nil
      artifact_number : Int32? = nil

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--artifact-id"
          if i + 1 < args.size
            artifact_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --artifact-id requires a value",
            )
            exit(1)
          end
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        when "--artifact"
          if i + 1 < args.size
            artifact_number = args[i + 1].to_i?
            i += 2
          else
            STDERR.puts(
              "Error: --artifact requires a value",
            )
            exit(1)
          end
        else
          i += 1
        end
      end

      artifact_id = resolve_artifact_id(
        artifact_id_str,
        ledger_session_id_str,
        artifact_number,
      )

      count = Database.count_unreviewed_annotations(
        artifact_id,
      )

      JSON.build(STDOUT) do |json|
        json.object do
          json.field "artifact_id", artifact_id
          json.field "has_pending", count > 0
          json.field "count", count
        end
      end
      puts ""
    end

    # Serialize an ArtifactReview to JSON fields
    private def self.review_to_json(
      json : JSON::Builder,
      review : Database::ArtifactReview,
    )
      json.object do
        json.field "id", review.id
        json.field "number", review.number
        json.field "artifact_id", review.artifact_id
        json.field "created_at", review.created_at
        json.field "updated_at", review.updated_at
        json.field "reviewed_at", review.reviewed_at
      end
    end

    # Resolve the artifact record from its DB primary key.
    private def self.resolve_artifact(
      artifact_id : Int64,
    ) : Database::Artifact
      # Query by primary key directly
      begin
        GalaxyArtifacts::Database.open do |db|
          result = db.query_one?(
            <<-SQL,
              SELECT id, ledger_session_id, number,
                     created_at, updated_at, title,
                     artifact_type, mime_type,
                     original_filename, stored_path,
                     source_path, file_size,
                     content_hash, description, metadata
              FROM artifacts
              WHERE id = ?
            SQL
            artifact_id,
          ) do |rs|
            Database::Artifact.from_row(rs)
          end
          if result
            return result
          end
        end
      rescue
      end
      STDERR.puts "Error: artifact not found"
      exit(1)
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
        refresh     Re-sync artifact from source file
        show        Show an artifact in Galaxy.app
        open        Open an artifact in native app
        delete      Delete an artifact
        annotation  Manage artifact annotations
        review      Manage annotation reviews
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
        # From a file on disk (dedup applies):
        galaxy-artifacts save --pid PID --source-path PATH [options]
        galaxy-artifacts save --ledger-session-id ID --source-path PATH [options]

        # From stdin (no source file, no dedup):
        some-command | galaxy-artifacts save --pid PID --filename NAME [options]

      REQUIRED (one of):
        --pid PID               Claude Code process ID
        --ledger-session-id ID  Direct ledger session ID

      SOURCE (one of):
        --source-path PATH      File on disk to copy into artifact storage
        --filename NAME         Filename for stdin content (required when
                                --source-path is not provided; extension
                                determines reader type in Galaxy.app)

      OPTIONS:
        --title TITLE           Descriptive title (default: derived from filename)
        --description TEXT      Context about what this artifact contains
        --artifact-type TYPE    Artifact type (default: "text")
        --mime-type MIME        MIME type (default: "application/octet-stream")
        --content-hash HASH     SHA256 hash (default: computed; source-path only)
        --file-size BYTES       File size in bytes (default: computed; source-path only)

      DESCRIPTION:
        With --source-path: copies the file to artifact storage and creates
        a session-scoped artifact record. The original file is left in place.
        If the same source path was already saved in this session, the
        existing artifact is updated (enrichment if content unchanged,
        version update if content changed).

        With --filename (stdin mode): streams stdin directly into artifact
        storage in 64 KB chunks. No source file is created or maintained,
        and no dedup applies — each invocation creates a new artifact. Use
        for ephemeral content like diffs or piped output.
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
        Outputs the content of an artifact to stdout. Works for all
        text-based types. Binary artifacts (pdf, image) are rejected
        — use 'open' instead.
      HELP
    end

    private def self.show_refresh_help
      puts <<-HELP
      galaxy-artifacts refresh - Re-sync artifact from source

      USAGE:
        galaxy-artifacts refresh --ledger-session-id ID NUMBER
        galaxy-artifacts refresh --pid PID NUMBER
        galaxy-artifacts refresh --skip-event --pid PID NUMBER

      Re-reads the source file and updates the stored copy if
      the content has changed. Outputs JSON result. If no
      source_path exists, outputs status without re-saving.

      By default, publishes an artifact.refresh socket event
      to Galaxy.app so it can auto-open the artifact reader.
      Use --skip-event when the caller handles its own UI
      reload (e.g. Galaxy.app's in-app refresh button).

      REQUIRED:
        NUMBER                  Artifact number

      REQUIRED (one of):
        --pid PID               Claude Code process ID
        --ledger-session-id ID  Direct ledger session ID

      OPTIONAL:
        --skip-event            Skip socket event publish
      HELP
    end

    private def self.show_show_help
      puts <<-HELP
      galaxy-artifacts show - Show an artifact in Galaxy.app

      USAGE:
        galaxy-artifacts show --ledger-session-id ID NUMBER
        galaxy-artifacts show --pid PID NUMBER

      Publishes an artifact.show socket event to Galaxy.app,
      which navigates to the artifact's session, switches to
      the Artifacts tab, and opens the artifact in its reader.
      If Galaxy.app doesn't have a reader for the artifact
      type, it falls back to the macOS default application.

      REQUIRED:
        NUMBER                  Artifact number

      REQUIRED (one of):
        --pid PID               Claude Code process ID
        --ledger-session-id ID  Direct ledger session ID
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

    private def self.show_annotation_help
      puts <<-HELP
      galaxy-artifacts annotation - Manage artifact annotations

      USAGE:
        galaxy-artifacts annotation <subcommand> [options]

      SUBCOMMANDS:
        create      Create an annotation (stdin JSON)
        list        List annotations for an artifact
        view        View a single annotation
        update      Update annotation content (stdin text)
        delete      Delete an annotation

      IDENTIFIER (required for all subcommands, one of):
        --artifact-id ID                   Direct artifact DB ID
        --ledger-session-id ID --artifact N  Session ID + artifact number

      Run 'galaxy-artifacts annotation <subcommand> --help' for details.
      HELP
    end

    private def self.show_annotation_create_help
      puts <<-HELP
      galaxy-artifacts annotation create - Create an annotation

      USAGE:
        echo '{"anchor_data":{...},"content":"..."}' | \\
          galaxy-artifacts annotation create --artifact-id ID

      REQUIRED (one of):
        --artifact-id ID                   Direct artifact DB ID
        --ledger-session-id ID --artifact N  Session + artifact number

      STDIN:
        JSON envelope with two fields:
          anchor_data  Object describing the annotation location
          content      Annotation text content

      DESCRIPTION:
        Creates an annotation on an artifact. The artifact's current
        content_hash is stored on the annotation for stale tracking.
        Anchor data is stored as-is (supports line_range, row_range,
        block_range, whole_file, and future anchor types).
      HELP
    end

    private def self.show_annotation_list_help
      puts <<-HELP
      galaxy-artifacts annotation list - List annotations

      USAGE:
        galaxy-artifacts annotation list --artifact-id ID
        galaxy-artifacts annotation list --ledger-session-id ID --artifact N

      REQUIRED (one of):
        --artifact-id ID                   Direct artifact DB ID
        --ledger-session-id ID --artifact N  Session + artifact number

      OPTIONS:
        --json    Output as JSON

      DESCRIPTION:
        Lists all annotations for the specified artifact, ordered by number.
      HELP
    end

    private def self.show_annotation_view_help
      puts <<-HELP
      galaxy-artifacts annotation view - View an annotation

      USAGE:
        galaxy-artifacts annotation view --artifact-id ID NUMBER

      REQUIRED:
        --artifact-id ID (or --ledger-session-id ID --artifact N)
        NUMBER    Annotation number

      DESCRIPTION:
        Returns a single annotation as JSON.
      HELP
    end

    private def self.show_annotation_update_help
      puts <<-HELP
      galaxy-artifacts annotation update - Update annotation content

      USAGE:
        echo 'new content' | \\
          galaxy-artifacts annotation update --artifact-id ID NUMBER

      REQUIRED:
        --artifact-id ID (or --ledger-session-id ID --artifact N)
        NUMBER    Annotation number

      STDIN:
        Plain text content (replaces existing content).
        Anchor data is immutable and cannot be changed.

      DESCRIPTION:
        Updates the content of an existing annotation. Only content
        can be changed — anchor_data, content_hash, and stale status
        are preserved.
      HELP
    end

    private def self.show_annotation_delete_help
      puts <<-HELP
      galaxy-artifacts annotation delete - Delete an annotation

      USAGE:
        galaxy-artifacts annotation delete --artifact-id ID NUMBER

      REQUIRED:
        --artifact-id ID (or --ledger-session-id ID --artifact N)
        NUMBER    Annotation number

      DESCRIPTION:
        Permanently deletes an annotation.
      HELP
    end

    private def self.show_review_help
      puts <<-HELP
      galaxy-artifacts review - Manage annotation reviews

      USAGE:
        galaxy-artifacts review <subcommand> [options]

      SUBCOMMANDS:
        create          Batch unreviewed annotations into a review
        list            List reviews for an artifact
        view            View a review with its annotations
        mark-reviewed   Mark a review as reviewed
        has-pending     Check for unreviewed annotations

      IDENTIFIER (required for all subcommands, one of):
        --artifact-id ID                   Direct artifact DB ID
        --ledger-session-id ID --artifact N  Session + artifact number

      Run 'galaxy-artifacts review <subcommand> --help' for details.
      HELP
    end

    private def self.show_review_create_help
      puts <<-HELP
      galaxy-artifacts review create - Create a review

      USAGE:
        galaxy-artifacts review create --artifact-id ID

      REQUIRED (one of):
        --artifact-id ID                   Direct artifact DB ID
        --ledger-session-id ID --artifact N  Session + artifact number

      DESCRIPTION:
        Atomically batches all unreviewed annotations into a new review.
        Fails if no unreviewed annotations exist.
      HELP
    end

    private def self.show_review_list_help
      puts <<-HELP
      galaxy-artifacts review list - List reviews

      USAGE:
        galaxy-artifacts review list --artifact-id ID

      REQUIRED (one of):
        --artifact-id ID                   Direct artifact DB ID
        --ledger-session-id ID --artifact N  Session + artifact number

      OPTIONS:
        --json       Output as JSON
        --pending    Only show reviews not yet marked as reviewed

      DESCRIPTION:
        Lists reviews for the specified artifact, ordered by number.
      HELP
    end

    private def self.show_review_view_help
      puts <<-HELP
      galaxy-artifacts review view - View a review

      USAGE:
        galaxy-artifacts review view --artifact-id ID NUMBER

      REQUIRED:
        --artifact-id ID (or --ledger-session-id ID --artifact N)
        NUMBER    Review number

      OPTIONS:
        --json    Output as JSON (includes artifact context and annotations)

      DESCRIPTION:
        Shows review details with its associated annotations.
      HELP
    end

    private def self.show_review_mark_reviewed_help
      puts <<-HELP
      galaxy-artifacts review mark-reviewed - Mark as reviewed

      USAGE:
        galaxy-artifacts review mark-reviewed --artifact-id ID NUMBER

      REQUIRED:
        --artifact-id ID (or --ledger-session-id ID --artifact N)
        NUMBER    Review number

      DESCRIPTION:
        Sets reviewed_at to the current timestamp. Idempotent — calling
        again updates the timestamp.
      HELP
    end

    private def self.show_review_has_pending_help
      puts <<-HELP
      galaxy-artifacts review has-pending - Check pending annotations

      USAGE:
        galaxy-artifacts review has-pending --artifact-id ID

      REQUIRED (one of):
        --artifact-id ID                   Direct artifact DB ID
        --ledger-session-id ID --artifact N  Session + artifact number

      DESCRIPTION:
        Returns JSON: {"artifact_id": N, "has_pending": bool, "count": N}
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
        Backup settings are managed by the shared Galaxy config.
        Use 'galaxy config' to view and 'galaxy config set' to change:
          galaxy config set backups.enabled true
          galaxy config set backups.retention_days 7
          galaxy config set backups.path /path/to/backups

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
