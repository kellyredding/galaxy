module GalaxySnapshots
  module CLI
    def self.run(args : Array(String))
      if args.empty?
        show_help
        return
      end

      command = args.first
      rest = args[1..]

      case command
      when "create"
        if rest.includes?("-h") || rest.includes?("--help")
          show_create_help
        else
          handle_create(rest)
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
      when "delete"
        if rest.includes?("-h") || rest.includes?("--help")
          show_delete_help
        else
          handle_delete(rest)
        end
      when "open"
        if rest.includes?("-h") || rest.includes?("--help")
          show_open_help
        else
          handle_open(rest)
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
          puts "galaxy-snapshots: skills installed"
        else
          STDERR.puts "Error: install failed"
          exit(1)
        end
      when "uninstall"
        if InstallManager.uninstall
          puts "galaxy-snapshots: skills uninstalled"
        else
          STDERR.puts "Error: uninstall failed"
          exit(1)
        end
      when "version"
        puts "galaxy-snapshots #{VERSION}"
      when "help", "-h", "--help"
        show_help
      when "-v", "--version"
        puts "galaxy-snapshots #{VERSION}"
      else
        STDERR.puts "Error: Unknown command '#{command}'"
        STDERR.puts "Run 'galaxy-snapshots --help' for usage"
        exit(1)
      end
    end

    # ============================================================
    # create
    # ============================================================

    private def self.handle_create(args : Array(String))
      pid_str : String? = nil
      ledger_session_id_str : String? = nil
      title : String? = nil
      exchange_count = 1

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
        when "--exchanges"
          if i + 1 < args.size
            exchange_count = args[i + 1].to_i? || 1
            i += 2
          else
            STDERR.puts "Error: --exchanges requires a value"
            exit(1)
          end
        else
          STDERR.puts "Error: Unknown option '#{arg}'"
          STDERR.puts "Run 'galaxy-snapshots create --help' for usage"
          exit(1)
        end
      end

      unless title
        STDERR.puts "Error: --title is required"
        STDERR.puts "Run 'galaxy-snapshots create --help' for usage"
        exit(1)
      end

      # Resolve ledger_session_id
      ledger_session_id : Int64
      if lsid_str = ledger_session_id_str
        ledger_session_id = resolve_ledger_session_id_str(lsid_str)
      elsif ps = pid_str
        ledger_session_id = resolve_pid_to_ledger_session_id(ps)
      else
        STDERR.puts "Error: --pid or --ledger-session-id is required"
        STDERR.puts "Run 'galaxy-snapshots create --help' for usage"
        exit(1)
      end

      # Read content from stdin
      content = STDIN.gets_to_end
      if content.strip.empty?
        STDERR.puts "Error: no content provided on stdin"
        exit(1)
      end

      number = Database.save_snapshot(
        ledger_session_id,
        title,
        content,
        exchange_count: exchange_count,
      )

      if number > 0
        puts "Snapshot ##{number} saved (title: \"#{title}\", chars: #{content.size})"

        # Record timeline event (fire-and-forget).
        # Timeline publishes to the socket as
        # timeline.snapshot:created — no separate
        # EventPublisher call needed.
        TimelinePublisher.snapshot_created(
          ledger_session_id,
          snapshot_number: number,
          title: title,
          exchange_count: exchange_count,
          char_count: content.size,
        )
      else
        STDERR.puts "Error: failed to save snapshot"
        exit(1)
      end
    end

    # ============================================================
    # list
    # ============================================================

    private def self.handle_list(args : Array(String))
      pid_str : String? = nil
      session_id : String? = nil
      ledger_session_id_str : String? = nil
      json_output = false
      content_flag = false

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
          json_output = true
          i += 1
        when "--content"
          content_flag = true
          i += 1
        else
          STDERR.puts "Error: Unknown option '#{arg}'"
          STDERR.puts "Run 'galaxy-snapshots list --help' for usage"
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
        STDERR.puts "Run 'galaxy-snapshots list --help' for usage"
        exit(1)
      end

      if json_output && content_flag
        # Return full content for each snapshot (for context handoff use)
        snapshots = Database.list_snapshots(ledger_session_id)

        JSON.build(STDOUT, indent: "  ") do |json|
          json.object do
            json.field "snapshots" do
              json.array do
                snapshots.each do |snap|
                  json.object do
                    json.field "id", snap.id
                    json.field "number", snap.number
                    json.field "title", snap.title
                    json.field "content", snap.content
                    json.field "exchange_count", snap.exchange_count
                    json.field "char_count", snap.char_count
                    json.field "created_at", snap.created_at
                  end
                end
              end
            end
          end
        end
        puts ""
        return
      end

      snapshots = Database.list_snapshots_with_counts(ledger_session_id)

      if json_output
        JSON.build(STDOUT, indent: "  ") do |json|
          json.object do
            json.field "snapshots" do
              json.array do
                snapshots.each do |snap|
                  json.object do
                    json.field "id", snap.id
                    json.field "number", snap.number
                    json.field "title", snap.title
                    json.field "exchange_count", snap.exchange_count
                    json.field "char_count", snap.char_count
                    json.field "review_count", snap.review_count
                    json.field "created_at", snap.created_at
                  end
                end
              end
            end
          end
        end
        puts ""
        return
      end

      if snapshots.empty?
        puts "No snapshots for this session."
        return
      end

      puts "Snapshots for session (#{snapshots.size} total):"
      puts ""

      snapshots.each do |snap|
        exchange_label = snap.exchange_count == 1 ? "exchange" : "exchanges"
        chars_formatted = format_number(snap.char_count)
        timestamp = format_snapshot_timestamp(snap.created_at)
        review_label = snap.review_count == 1 ? "review" : "reviews"
        review_info = snap.review_count > 0 ? "  #{snap.review_count} #{review_label}" : ""
        puts "  ##{snap.number}  \"#{snap.title}\"  #{snap.exchange_count} #{exchange_label}  #{chars_formatted} chars#{review_info}  #{timestamp}"
      end
    end

    # ============================================================
    # view
    # ============================================================

    private def self.handle_view(args : Array(String))
      pid_str : String? = nil
      ledger_session_id_str : String? = nil
      json_output = false
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
        when "--json"
          json_output = true
          i += 1
        else
          # Try as positional number
          if n = arg.to_i?
            number = n
          else
            STDERR.puts "Error: Unknown option '#{arg}'"
            STDERR.puts "Run 'galaxy-snapshots view --help' for usage"
            exit(1)
          end
          i += 1
        end
      end

      # Resolve to ledger_session_id
      ledger_session_id : Int64? = nil
      if lsid_str = ledger_session_id_str
        ledger_session_id = resolve_ledger_session_id_str(lsid_str)
      elsif ps = pid_str
        ledger_session_id = resolve_pid_to_ledger_session_id(ps)
      end

      unless ledger_session_id
        STDERR.puts "Error: --pid or --ledger-session-id is required"
        STDERR.puts "Run 'galaxy-snapshots view --help' for usage"
        exit(1)
      end

      unless number
        STDERR.puts "Error: snapshot number is required"
        STDERR.puts "Run 'galaxy-snapshots view --help' for usage"
        exit(1)
      end

      snapshot = Database.get_snapshot_by_number(ledger_session_id, number)

      unless snapshot
        STDERR.puts "Error: snapshot ##{number} not found"
        exit(1)
      end

      if json_output
        JSON.build(STDOUT, indent: "  ") do |json|
          json.object do
            json.field "snapshot" do
              json.object do
                json.field "id", snapshot.id
                json.field "number", snapshot.number
                json.field "title", snapshot.title
                json.field "content", snapshot.content
                json.field "exchange_count", snapshot.exchange_count
                json.field "char_count", snapshot.char_count
                json.field "created_at", snapshot.created_at
                json.field "updated_at", snapshot.updated_at
                if m = snapshot.metadata
                  json.field "metadata", m
                end
              end
            end
          end
        end
        puts ""
      else
        puts snapshot.content
      end
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
            STDERR.puts "Run 'galaxy-snapshots delete --help' for usage"
            exit(1)
          end
          i += 1
        end
      end

      # Resolve to ledger_session_id
      ledger_session_id : Int64? = nil
      if lsid_str = ledger_session_id_str
        ledger_session_id = resolve_ledger_session_id_str(lsid_str)
      elsif ps = pid_str
        ledger_session_id = resolve_pid_to_ledger_session_id(ps)
      end

      unless ledger_session_id
        STDERR.puts "Error: --pid or --ledger-session-id is required"
        STDERR.puts "Run 'galaxy-snapshots delete --help' for usage"
        exit(1)
      end

      unless number
        STDERR.puts "Error: snapshot number is required"
        STDERR.puts "Run 'galaxy-snapshots delete --help' for usage"
        exit(1)
      end

      result = Database.delete_snapshot_by_number(ledger_session_id, number)

      if result
        puts "Snapshot ##{number} deleted"
      else
        STDERR.puts "Error: snapshot ##{number} not found"
        exit(1)
      end
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
            STDERR.puts "Run 'galaxy-snapshots open --help' for usage"
            exit(1)
          end
          i += 1
        end
      end

      # Resolve to ledger_session_id
      ledger_session_id : Int64? = nil
      if lsid_str = ledger_session_id_str
        ledger_session_id = resolve_ledger_session_id_str(lsid_str)
      elsif ps = pid_str
        ledger_session_id = resolve_pid_to_ledger_session_id(ps)
      end

      unless ledger_session_id
        STDERR.puts "Error: --pid or --ledger-session-id is required"
        STDERR.puts "Run 'galaxy-snapshots open --help' for usage"
        exit(1)
      end

      unless number
        STDERR.puts "Error: snapshot number is required"
        STDERR.puts "Run 'galaxy-snapshots open --help' for usage"
        exit(1)
      end

      snapshot = Database.get_snapshot_by_number(ledger_session_id, number)

      unless snapshot
        STDERR.puts "Error: snapshot ##{number} not found"
        exit(1)
      end

      # Write content to a stable temp file
      temp_path = snapshot_temp_path(ledger_session_id, number)
      Dir.mkdir_p(Path.new(temp_path).parent)
      File.write(temp_path, snapshot.content)

      # Resolve the editor command via cascade:
      # 1. config editor (explicit)
      # 2. $VISUAL env var
      # 3. $EDITOR env var
      # 4. "open" (macOS default)
      editor = resolve_editor

      # Open the file
      begin
        process = Process.new(
          editor,
          args: [temp_path],
          shell: false,
          input: Process::Redirect::Inherit,
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit,
        )
        process.wait
      rescue ex
        STDERR.puts "Error: failed to open with '#{editor}': #{ex.message}"
        STDERR.puts "Set an editor via: galaxy-snapshots config set editor <command>"
        exit(1)
      end

      puts "Opened snapshot ##{number} (\"#{snapshot.title}\") → #{temp_path}"
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
          STDERR.puts "Run 'galaxy-snapshots stats --help' for usage"
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
        STDERR.puts "Run 'galaxy-snapshots stats --help' for usage"
        exit(1)
      end

      stats = Database.session_snapshot_stats(ledger_session_id)

      JSON.build(STDOUT) do |json|
        json.object do
          json.field "count", stats[:count]
          json.field "total_chars", stats[:total_chars]
        end
      end
      puts ""
    end

    # ============================================================
    # annotation
    # ============================================================

    private def self.handle_annotation_command(args : Array(String))
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
        STDERR.puts "Error: Unknown annotation command '#{subcommand}'"
        STDERR.puts "Run 'galaxy-snapshots annotation --help' for usage"
        exit(1)
      end
    end

    # Resolve --snapshot-id or (--ledger-session-id + --snapshot) to a
    # snapshot_id (the DB primary key of the snapshot).
    private def self.resolve_snapshot_id(
      snapshot_id_str : String?,
      ledger_session_id_str : String?,
      snapshot_number : Int32?,
    ) : Int64
      if sid_str = snapshot_id_str
        id = sid_str.to_i64?
        unless id
          STDERR.puts "Error: --snapshot-id must be a number"
          exit(1)
        end
        return id
      end

      if sess_str = ledger_session_id_str
        session_id = resolve_ledger_session_id_str(sess_str)
        unless snapshot_number
          STDERR.puts "Error: --snapshot is required when using --ledger-session-id"
          exit(1)
        end
        snapshot = Database.get_snapshot_by_number(session_id, snapshot_number)
        unless snapshot
          STDERR.puts "Error: snapshot ##{snapshot_number} not found"
          exit(1)
        end
        return snapshot.id
      end

      STDERR.puts "Error: --snapshot-id (or --ledger-session-id + --snapshot) is required"
      exit(1)
    end

    private def self.annotation_create(args : Array(String))
      snapshot_id_str : String? = nil
      ledger_session_id_str : String? = nil
      snapshot_number : Int32? = nil
      start_line : Int32? = nil
      end_line : Int32? = nil

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--snapshot-id"
          if i + 1 < args.size
            snapshot_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --snapshot-id requires a value"
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
        when "--snapshot"
          if i + 1 < args.size
            snapshot_number = args[i + 1].to_i?
            unless snapshot_number
              STDERR.puts "Error: --snapshot must be a number"
              exit(1)
            end
            i += 2
          else
            STDERR.puts "Error: --snapshot requires a value"
            exit(1)
          end
        when "--start-line"
          if i + 1 < args.size
            start_line = args[i + 1].to_i?
            unless start_line
              STDERR.puts "Error: --start-line must be a number"
              exit(1)
            end
            i += 2
          else
            STDERR.puts "Error: --start-line requires a value"
            exit(1)
          end
        when "--end-line"
          if i + 1 < args.size
            end_line = args[i + 1].to_i?
            unless end_line
              STDERR.puts "Error: --end-line must be a number"
              exit(1)
            end
            i += 2
          else
            STDERR.puts "Error: --end-line requires a value"
            exit(1)
          end
        else
          STDERR.puts "Error: Unknown option '#{arg}'"
          STDERR.puts "Run 'galaxy-snapshots annotation create --help' for usage"
          exit(1)
        end
      end

      snapshot_id = resolve_snapshot_id(snapshot_id_str, ledger_session_id_str, snapshot_number)

      unless start_line
        STDERR.puts "Error: --start-line is required"
        STDERR.puts "Run 'galaxy-snapshots annotation create --help' for usage"
        exit(1)
      end

      unless end_line
        STDERR.puts "Error: --end-line is required"
        STDERR.puts "Run 'galaxy-snapshots annotation create --help' for usage"
        exit(1)
      end

      # Read content from stdin
      content = STDIN.gets_to_end
      if content.strip.empty?
        STDERR.puts "Error: no content provided on stdin"
        exit(1)
      end

      ann = Database.save_snapshot_annotation(
        snapshot_id,
        start_line,
        end_line,
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

        snap = resolve_snapshot(snapshot_id)
        TimelinePublisher.annotation_created(
          snap.ledger_session_id,
          snapshot_id: snapshot_id,
          snapshot_number: snap.number,
          snapshot_title: snap.title,
          annotation_number: ann.number,
          start_line: ann.start_line,
          end_line: ann.end_line,
          content: ann.content,
        )
      else
        STDERR.puts "Error: failed to create annotation"
        exit(1)
      end
    end

    private def self.annotation_list(args : Array(String))
      snapshot_id_str : String? = nil
      ledger_session_id_str : String? = nil
      snapshot_number : Int32? = nil
      json_output = false

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--snapshot-id"
          if i + 1 < args.size
            snapshot_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --snapshot-id requires a value"
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
        when "--snapshot"
          if i + 1 < args.size
            snapshot_number = args[i + 1].to_i?
            unless snapshot_number
              STDERR.puts "Error: --snapshot must be a number"
              exit(1)
            end
            i += 2
          else
            STDERR.puts "Error: --snapshot requires a value"
            exit(1)
          end
        when "--json"
          json_output = true
          i += 1
        else
          STDERR.puts "Error: Unknown option '#{arg}'"
          STDERR.puts "Run 'galaxy-snapshots annotation list --help' for usage"
          exit(1)
        end
      end

      snapshot_id = resolve_snapshot_id(snapshot_id_str, ledger_session_id_str, snapshot_number)
      annotations = Database.list_snapshot_annotations(snapshot_id)

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
        puts "No annotations for this snapshot."
        return
      end

      puts "Annotations (#{annotations.size} total):"
      puts ""

      annotations.each do |ann|
        line_range = ann.start_line == ann.end_line ? "line #{ann.start_line}" : "lines #{ann.start_line}-#{ann.end_line}"
        preview = ann.content.gsub('\n', ' ')
        preview = preview.size > 50 ? "#{preview[0, 50]}..." : preview
        timestamp = format_snapshot_timestamp(ann.created_at)
        puts "  ##{ann.number}  #{line_range}  \"#{preview}\"  #{timestamp}"
      end
    end

    private def self.annotation_view(args : Array(String))
      snapshot_id_str : String? = nil
      ledger_session_id_str : String? = nil
      snapshot_number : Int32? = nil
      number : Int32? = nil

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--snapshot-id"
          if i + 1 < args.size
            snapshot_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --snapshot-id requires a value"
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
        when "--snapshot"
          if i + 1 < args.size
            snapshot_number = args[i + 1].to_i?
            unless snapshot_number
              STDERR.puts "Error: --snapshot must be a number"
              exit(1)
            end
            i += 2
          else
            STDERR.puts "Error: --snapshot requires a value"
            exit(1)
          end
        else
          # Try as positional annotation number
          if n = arg.to_i?
            number = n
          else
            STDERR.puts "Error: Unknown option '#{arg}'"
            STDERR.puts "Run 'galaxy-snapshots annotation view --help' for usage"
            exit(1)
          end
          i += 1
        end
      end

      snapshot_id = resolve_snapshot_id(snapshot_id_str, ledger_session_id_str, snapshot_number)

      unless number
        STDERR.puts "Error: annotation number is required"
        STDERR.puts "Run 'galaxy-snapshots annotation view --help' for usage"
        exit(1)
      end

      ann = Database.get_snapshot_annotation(snapshot_id, number)

      unless ann
        STDERR.puts "Error: annotation ##{number} not found"
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

    private def self.annotation_update(args : Array(String))
      snapshot_id_str : String? = nil
      ledger_session_id_str : String? = nil
      snapshot_number : Int32? = nil
      number : Int32? = nil

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--snapshot-id"
          if i + 1 < args.size
            snapshot_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --snapshot-id requires a value"
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
        when "--snapshot"
          if i + 1 < args.size
            snapshot_number = args[i + 1].to_i?
            unless snapshot_number
              STDERR.puts "Error: --snapshot must be a number"
              exit(1)
            end
            i += 2
          else
            STDERR.puts "Error: --snapshot requires a value"
            exit(1)
          end
        else
          # Try as positional annotation number
          if n = arg.to_i?
            number = n
          else
            STDERR.puts "Error: Unknown option '#{arg}'"
            STDERR.puts "Run 'galaxy-snapshots annotation update --help' for usage"
            exit(1)
          end
          i += 1
        end
      end

      snapshot_id = resolve_snapshot_id(snapshot_id_str, ledger_session_id_str, snapshot_number)

      unless number
        STDERR.puts "Error: annotation number is required"
        STDERR.puts "Run 'galaxy-snapshots annotation update --help' for usage"
        exit(1)
      end

      # Read content from stdin
      content = STDIN.gets_to_end
      if content.strip.empty?
        STDERR.puts "Error: no content provided on stdin"
        exit(1)
      end

      ann = Database.update_snapshot_annotation(
        snapshot_id,
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

        snap = resolve_snapshot(snapshot_id)
        TimelinePublisher.annotation_updated(
          snap.ledger_session_id,
          snapshot_id: snapshot_id,
          snapshot_number: snap.number,
          snapshot_title: snap.title,
          annotation_number: ann.number,
          content: ann.content,
        )
      else
        STDERR.puts "Error: annotation ##{number} not found"
        exit(1)
      end
    end

    private def self.annotation_delete(args : Array(String))
      snapshot_id_str : String? = nil
      ledger_session_id_str : String? = nil
      snapshot_number : Int32? = nil
      number : Int32? = nil

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--snapshot-id"
          if i + 1 < args.size
            snapshot_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --snapshot-id requires a value"
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
        when "--snapshot"
          if i + 1 < args.size
            snapshot_number = args[i + 1].to_i?
            unless snapshot_number
              STDERR.puts "Error: --snapshot must be a number"
              exit(1)
            end
            i += 2
          else
            STDERR.puts "Error: --snapshot requires a value"
            exit(1)
          end
        else
          # Try as positional annotation number
          if n = arg.to_i?
            number = n
          else
            STDERR.puts "Error: Unknown option '#{arg}'"
            STDERR.puts "Run 'galaxy-snapshots annotation delete --help' for usage"
            exit(1)
          end
          i += 1
        end
      end

      snapshot_id = resolve_snapshot_id(snapshot_id_str, ledger_session_id_str, snapshot_number)

      unless number
        STDERR.puts "Error: annotation number is required"
        STDERR.puts "Run 'galaxy-snapshots annotation delete --help' for usage"
        exit(1)
      end

      # Fetch annotation before deleting so we can
      # include its content in the timeline event.
      ann = Database.get_snapshot_annotation(
        snapshot_id, number,
      )
      result = Database.delete_snapshot_annotation(
        snapshot_id, number,
      )

      if result
        puts "Annotation ##{number} deleted"

        snap = resolve_snapshot(snapshot_id)
        TimelinePublisher.annotation_deleted(
          snap.ledger_session_id,
          snapshot_id: snapshot_id,
          snapshot_number: snap.number,
          snapshot_title: snap.title,
          annotation_number: number,
          content: ann.try(&.content),
        )
      else
        STDERR.puts "Error: annotation ##{number} not found"
        exit(1)
      end
    end

    # Serialize a SnapshotAnnotation to JSON fields
    private def self.annotation_to_json(json : JSON::Builder, ann : Database::SnapshotAnnotation)
      json.object do
        json.field "id", ann.id
        json.field "number", ann.number
        json.field "snapshot_id", ann.snapshot_id
        json.field "snapshot_review_id", ann.snapshot_review_id
        json.field "review_number", ann.review_number
        json.field "review_reviewed_at", ann.review_reviewed_at
        json.field "start_line", ann.start_line
        json.field "end_line", ann.end_line
        json.field "content", ann.content
        json.field "created_at", ann.created_at
        json.field "updated_at", ann.updated_at
      end
    end

    # ============================================================
    # review
    # ============================================================

    private def self.handle_review_command(args : Array(String))
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
        STDERR.puts "Error: Unknown review command '#{subcommand}'"
        STDERR.puts "Run 'galaxy-snapshots review --help' for usage"
        exit(1)
      end
    end

    private def self.review_create(args : Array(String))
      snapshot_id_str : String? = nil
      ledger_session_id_str : String? = nil
      snapshot_number : Int32? = nil

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--snapshot-id"
          if i + 1 < args.size
            snapshot_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --snapshot-id requires a value"
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
        when "--snapshot"
          if i + 1 < args.size
            snapshot_number = args[i + 1].to_i?
            i += 2
          else
            STDERR.puts "Error: --snapshot requires a value"
            exit(1)
          end
        else
          i += 1
        end
      end

      snapshot_id = resolve_snapshot_id(
        snapshot_id_str,
        ledger_session_id_str,
        snapshot_number,
      )

      result = Database.save_snapshot_review(snapshot_id)

      unless result
        STDERR.puts "Error: no unreviewed annotations to submit"
        exit(1)
      end

      review, annotation_count = result

      # Record timeline event — timeline publishes to
      # the socket so Galaxy app can update review state.
      snap = resolve_snapshot(snapshot_id)
      TimelinePublisher.review_created(
        snap.ledger_session_id,
        snapshot_id: snapshot_id,
        snapshot_number: snap.number,
        snapshot_title: snap.title,
        review_number: review.number,
        annotation_count: annotation_count,
      )

      JSON.build(STDOUT) do |json|
        json.object do
          json.field "review" do
            review_to_json(json, review)
          end
          json.field "annotation_count", annotation_count
        end
      end
      puts ""
    end

    private def self.review_list(args : Array(String))
      snapshot_id_str : String? = nil
      ledger_session_id_str : String? = nil
      snapshot_number : Int32? = nil
      json_output = false
      pending_only = false

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--snapshot-id"
          if i + 1 < args.size
            snapshot_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --snapshot-id requires a value"
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
        when "--snapshot"
          if i + 1 < args.size
            snapshot_number = args[i + 1].to_i?
            i += 2
          else
            STDERR.puts "Error: --snapshot requires a value"
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

      snapshot_id = resolve_snapshot_id(
        snapshot_id_str,
        ledger_session_id_str,
        snapshot_number,
      )

      reviews = Database.list_snapshot_reviews(
        snapshot_id,
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
                    json.field "snapshot_id", review.snapshot_id
                    json.field "created_at", review.created_at
                    json.field "reviewed_at", review.reviewed_at
                    json.field "annotation_count" do
                      anns = Database.list_annotations_for_review(review.id)
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
            ann_count = Database.list_annotations_for_review(review.id).size
            status = review.reviewed_at ? "reviewed" : "pending"
            timestamp = format_snapshot_timestamp(review.created_at)
            puts "  ##{review.number}  #{ann_count} annotation#{ann_count == 1 ? "" : "s"}  #{status}  #{timestamp}"
          end
        end
      end
    end

    private def self.review_view(args : Array(String))
      snapshot_id_str : String? = nil
      ledger_session_id_str : String? = nil
      snapshot_number : Int32? = nil
      review_number : Int32? = nil
      json_output = false

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--snapshot-id"
          if i + 1 < args.size
            snapshot_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --snapshot-id requires a value"
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
        when "--snapshot"
          if i + 1 < args.size
            snapshot_number = args[i + 1].to_i?
            i += 2
          else
            STDERR.puts "Error: --snapshot requires a value"
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

      snapshot_id = resolve_snapshot_id(
        snapshot_id_str,
        ledger_session_id_str,
        snapshot_number,
      )

      unless review_number
        STDERR.puts "Error: review number is required"
        STDERR.puts "Run 'galaxy-snapshots review view --help' for usage"
        exit(1)
      end

      review = Database.get_snapshot_review(snapshot_id, review_number)
      unless review
        STDERR.puts "Error: review ##{review_number} not found"
        exit(1)
      end

      # Get the snapshot for context
      snapshot = Database.get_snapshot_by_id(snapshot_id)
      unless snapshot
        STDERR.puts "Error: snapshot not found"
        exit(1)
      end

      # Get annotations assigned to this review
      annotations = Database.list_annotations_for_review(review.id)

      if json_output
        JSON.build(STDOUT) do |json|
          json.object do
            json.field "review" do
              review_to_json(json, review)
            end
            json.field "snapshot" do
              json.object do
                json.field "id", snapshot.id
                json.field "number", snapshot.number
                json.field "title", snapshot.title
                json.field "content", snapshot.content
                json.field "exchange_count", snapshot.exchange_count
                json.field "ledger_session_id", snapshot.ledger_session_id
                json.field "created_at", snapshot.created_at
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
        status = review.reviewed_at ? "reviewed #{format_snapshot_timestamp(review.reviewed_at.not_nil!)}" : "pending"
        timestamp = format_snapshot_timestamp(review.created_at)
        puts "Review ##{review.number} (#{status})"
        puts "  Snapshot: ##{snapshot.number} — #{snapshot.title}"
        puts "  Created: #{timestamp}"
        puts "  Annotations (#{annotations.size}):"
        annotations.each do |ann|
          range = ann.start_line == ann.end_line ? "line #{ann.start_line}" : "lines #{ann.start_line}-#{ann.end_line}"
          preview = ann.content.gsub('\n', ' ')
          preview = preview[0, 60] + "..." if preview.size > 63
          puts "    ##{ann.number}  #{range}  \"#{preview}\""
        end
      end
    end

    private def self.review_mark_reviewed(args : Array(String))
      snapshot_id_str : String? = nil
      ledger_session_id_str : String? = nil
      snapshot_number : Int32? = nil
      review_number : Int32? = nil

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--snapshot-id"
          if i + 1 < args.size
            snapshot_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --snapshot-id requires a value"
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
        when "--snapshot"
          if i + 1 < args.size
            snapshot_number = args[i + 1].to_i?
            i += 2
          else
            STDERR.puts "Error: --snapshot requires a value"
            exit(1)
          end
        else
          if n = arg.to_i?
            review_number = n
          end
          i += 1
        end
      end

      snapshot_id = resolve_snapshot_id(
        snapshot_id_str,
        ledger_session_id_str,
        snapshot_number,
      )

      unless review_number
        STDERR.puts "Error: review number is required"
        STDERR.puts "Run 'galaxy-snapshots review mark-reviewed --help' for usage"
        exit(1)
      end

      review = Database.mark_snapshot_review_reviewed(
        snapshot_id,
        review_number,
      )

      unless review
        STDERR.puts "Error: review ##{review_number} not found"
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

    private def self.review_has_pending(args : Array(String))
      snapshot_id_str : String? = nil
      ledger_session_id_str : String? = nil
      snapshot_number : Int32? = nil

      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--snapshot-id"
          if i + 1 < args.size
            snapshot_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts "Error: --snapshot-id requires a value"
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
        when "--snapshot"
          if i + 1 < args.size
            snapshot_number = args[i + 1].to_i?
            i += 2
          else
            STDERR.puts "Error: --snapshot requires a value"
            exit(1)
          end
        else
          i += 1
        end
      end

      snapshot_id = resolve_snapshot_id(
        snapshot_id_str,
        ledger_session_id_str,
        snapshot_number,
      )

      count = Database.count_unreviewed_annotations(snapshot_id)

      JSON.build(STDOUT) do |json|
        json.object do
          json.field "snapshot_id", snapshot_id
          json.field "has_pending", count > 0
          json.field "count", count
        end
      end
      puts ""
    end

    # Serialize a SnapshotReview to JSON fields
    private def self.review_to_json(
      json : JSON::Builder,
      review : Database::SnapshotReview,
    )
      json.object do
        json.field "id", review.id
        json.field "number", review.number
        json.field "snapshot_id", review.snapshot_id
        json.field "created_at", review.created_at
        json.field "updated_at", review.updated_at
        json.field "reviewed_at", review.reviewed_at
      end
    end

    # Resolve the snapshot record from its DB primary key.
    # Used by TimelinePublisher calls that need
    # ledger_session_id, snapshot number, and title.
    private def self.resolve_snapshot(
      snapshot_id : Int64,
    ) : Database::Snapshot
      Database.get_snapshot_by_id(snapshot_id).not_nil!
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

      config = SharedBackupConfig.load

      if list_mode
        backup_list(config)
      elsif prune_only
        backup_prune_only(config)
      else
        backup_create_and_prune(config, session_id)
      end
    end

    private def self.backup_list(config : SharedBackupConfig)
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

    private def self.backup_create_and_prune(config : SharedBackupConfig, session_id : Int64)
      unless config.backups.enabled
        puts "Backups are disabled. Enable with: galaxy config set backups.enabled true"
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

    private def self.backup_prune_only(config : SharedBackupConfig)
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

    # Build a stable temp file path for a snapshot.
    # Same snapshot always maps to the same path, so reopening
    # in an editor reuses the tab instead of creating a duplicate.
    def self.snapshot_temp_path(
      ledger_session_id : Int64,
      number : Int32,
    ) : String
      File.join(Dir.tempdir, "galaxy-snapshots-snapshot-#{ledger_session_id}-#{number}.md")
    end

    # Resolve which editor command to use via cascade:
    # 1. config editor (if non-empty)
    # 2. $VISUAL
    # 3. $EDITOR
    # 4. "open" (macOS default)
    def self.resolve_editor : String
      # 1. Config
      config_editor = Config.load.editor
      return config_editor unless config_editor.empty?

      # 2. $VISUAL
      visual = ENV["VISUAL"]?
      return visual if visual && !visual.empty?

      # 3. $EDITOR
      editor = ENV["EDITOR"]?
      return editor if editor && !editor.empty?

      # 4. macOS default
      "open"
    end

    # Format a number with commas (e.g., 3241 -> "3,241")
    private def self.format_number(n : Int32) : String
      n.to_s.reverse.gsub(/(\d{3})(?=\d)/, "\\1,").reverse
    end

    # Format a UTC timestamp from SQLite to local time in American style.
    # Input: "2026-02-17 22:32:00" (UTC from SQLite datetime('now'))
    # Output: "02/17/2026 2:32 PM"
    private def self.format_snapshot_timestamp(utc_str : String) : String
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
      galaxy-snapshots - Manage session snapshots

      USAGE:
        galaxy-snapshots <command> [options]

      COMMANDS:
        create      Create a snapshot from stdin
        list        List snapshots for a session
        view        View a snapshot's content
        open        Open a snapshot in an editor
        delete      Delete a snapshot
        stats       Get snapshot stats for a session (JSON)
        annotation  Manage snapshot annotations
        review      Manage snapshot reviews
        backup      Manage database backups
        install     Install skills
        uninstall   Remove skills
        version     Show version

      Run 'galaxy-snapshots <command> --help' for detailed usage.
      HELP
    end

    private def self.show_create_help
      puts <<-HELP
      galaxy-snapshots create - Create a snapshot

      USAGE:
        galaxy-snapshots create --pid PID --title TITLE [--exchanges N] < content
        galaxy-snapshots create --ledger-session-id ID --title TITLE [--exchanges N] < content

      REQUIRED:
        --title TITLE           Descriptive title for the snapshot

      REQUIRED (one of):
        --pid PID               Claude Code process ID
        --ledger-session-id ID  Direct ledger session ID

      OPTIONS:
        --exchanges N           Number of exchanges captured (default: 1)

      DESCRIPTION:
        Reads markdown content from stdin and saves it as a session snapshot.
        Snapshots preserve verbatim user/assistant exchanges for restoration
        on context handoff (/clear, /compact).

      EXAMPLES:
        echo "## Exchange 1..." | galaxy-snapshots create --pid 12345 --title "Design discussion"
        galaxy-snapshots create --pid 12345 --title "Style correction" --exchanges 2 < content.md
      HELP
    end

    private def self.show_list_help
      puts <<-HELP
      galaxy-snapshots list - List session snapshots

      USAGE:
        galaxy-snapshots list --pid PID
        galaxy-snapshots list --session SESSION_ID
        galaxy-snapshots list --ledger-session-id ID

      REQUIRED (one of):
        --pid PID                Claude Code process ID
        --session ID             Session identifier
        --ledger-session-id ID   Direct ledger session ID

      OPTIONS:
        --json                   Output as JSON (envelope: {"snapshots":[...]})
        --content                With --json, include full content field

      DESCRIPTION:
        Lists all snapshots for the specified session with number, title,
        exchange count, character count, and timestamp.
      HELP
    end

    private def self.show_view_help
      puts <<-HELP
      galaxy-snapshots view - View a snapshot

      USAGE:
        galaxy-snapshots view --pid PID NUMBER
        galaxy-snapshots view --ledger-session-id ID NUMBER

      REQUIRED:
        --pid PID                Claude Code process ID (or use --ledger-session-id)
        --ledger-session-id ID   Direct ledger session ID (or use --pid)
        NUMBER                   Snapshot number (session-scoped)

      OPTIONS:
        --json                   Output as JSON (envelope: {"snapshot":{...}})

      DESCRIPTION:
        Outputs the full markdown content of a snapshot to stdout.
      HELP
    end

    private def self.show_delete_help
      puts <<-HELP
      galaxy-snapshots delete - Delete a snapshot

      USAGE:
        galaxy-snapshots delete --pid PID NUMBER
        galaxy-snapshots delete --ledger-session-id ID NUMBER

      REQUIRED:
        --pid PID                Claude Code process ID (or use --ledger-session-id)
        --ledger-session-id ID   Direct ledger session ID (or use --pid)
        NUMBER                   Snapshot number (session-scoped)

      DESCRIPTION:
        Permanently deletes a snapshot from the session.
      HELP
    end

    private def self.show_open_help
      puts <<-HELP
      galaxy-snapshots open - Open a snapshot in an editor

      USAGE:
        galaxy-snapshots open --pid PID NUMBER
        galaxy-snapshots open --ledger-session-id ID NUMBER

      REQUIRED:
        --pid PID                Claude Code process ID (or use --ledger-session-id)
        --ledger-session-id ID   Direct ledger session ID (or use --pid)
        NUMBER                   Snapshot number (session-scoped)

      DESCRIPTION:
        Writes the snapshot content to a stable temp file and opens it
        with the configured editor. The temp file path is deterministic
        so reopening the same snapshot reuses the file (and editor tab).

      EDITOR RESOLUTION (first match wins):
        1. editor config setting
        2. $VISUAL environment variable
        3. $EDITOR environment variable
        4. 'open' (macOS default application)

      EXAMPLES:
        galaxy-snapshots open --pid 12345 1
      HELP
    end

    private def self.show_stats_help
      puts <<-HELP
      galaxy-snapshots stats - Get snapshot stats for a session

      USAGE:
        galaxy-snapshots stats --pid PID
        galaxy-snapshots stats --session SESSION_ID
        galaxy-snapshots stats --ledger-session-id ID

      REQUIRED (one of):
        --pid PID                Claude Code process ID
        --session ID             Session identifier
        --ledger-session-id ID   Direct ledger session ID

      DESCRIPTION:
        Returns JSON with count and total character count for all snapshots
        in the session. Used for budget decisions without loading content.

        Output: {"count": N, "total_chars": N}
      HELP
    end

    private def self.show_annotation_help
      puts <<-HELP
      galaxy-snapshots annotation - Manage snapshot annotations

      USAGE:
        galaxy-snapshots annotation <command> [options]

      COMMANDS:
        create   Create an annotation on a snapshot
        list     List annotations for a snapshot
        view     View an annotation
        update   Update an annotation's content
        delete   Delete an annotation

      Run 'galaxy-snapshots annotation <command> --help' for detailed usage.
      HELP
    end

    private def self.show_annotation_create_help
      puts <<-HELP
      galaxy-snapshots annotation create - Create an annotation

      USAGE:
        galaxy-snapshots annotation create --snapshot-id ID --start-line N --end-line N < content
        galaxy-snapshots annotation create --ledger-session-id ID --snapshot N --start-line N --end-line N < content

      REQUIRED:
        --snapshot-id ID          Snapshot database ID
        --start-line N            Start line number in the snapshot content
        --end-line N              End line number in the snapshot content

      ALTERNATIVE IDENTIFIER:
        --ledger-session-id ID    Ledger session ID (use with --snapshot)
        --snapshot N              Snapshot number within the session

      DESCRIPTION:
        Reads annotation content from stdin and creates an annotation anchored
        to the specified line range. Number is auto-assigned sequentially.
        Returns JSON with the created annotation.

      EXAMPLES:
        echo "Important design decision" | galaxy-snapshots annotation create --snapshot-id 42 --start-line 5 --end-line 10
      HELP
    end

    private def self.show_annotation_list_help
      puts <<-HELP
      galaxy-snapshots annotation list - List snapshot annotations

      USAGE:
        galaxy-snapshots annotation list --snapshot-id ID [--json]
        galaxy-snapshots annotation list --ledger-session-id ID --snapshot N [--json]

      REQUIRED (one of):
        --snapshot-id ID          Snapshot database ID
        --ledger-session-id ID    Ledger session ID (use with --snapshot)
        --snapshot N              Snapshot number within the session

      OPTIONS:
        --json                    Output as JSON (envelope: {"annotations":[...]})

      DESCRIPTION:
        Lists all annotations for the specified snapshot, ordered by line
        position (start_line ASC, end_line ASC, number ASC).
      HELP
    end

    private def self.show_annotation_view_help
      puts <<-HELP
      galaxy-snapshots annotation view - View an annotation

      USAGE:
        galaxy-snapshots annotation view --snapshot-id ID NUMBER
        galaxy-snapshots annotation view --ledger-session-id ID --snapshot N NUMBER

      REQUIRED:
        --snapshot-id ID          Snapshot database ID (or use --ledger-session-id + --snapshot)
        NUMBER                    Annotation number (snapshot-scoped)

      DESCRIPTION:
        Returns JSON with the full annotation detail.
      HELP
    end

    private def self.show_annotation_update_help
      puts <<-HELP
      galaxy-snapshots annotation update - Update an annotation

      USAGE:
        galaxy-snapshots annotation update --snapshot-id ID NUMBER < content
        galaxy-snapshots annotation update --ledger-session-id ID --snapshot N NUMBER < content

      REQUIRED:
        --snapshot-id ID          Snapshot database ID (or use --ledger-session-id + --snapshot)
        NUMBER                    Annotation number (snapshot-scoped)

      DESCRIPTION:
        Reads updated content from stdin and updates the annotation.
        Line ranges are immutable — only content can be changed.
        Returns JSON with the updated annotation.
      HELP
    end

    private def self.show_annotation_delete_help
      puts <<-HELP
      galaxy-snapshots annotation delete - Delete an annotation

      USAGE:
        galaxy-snapshots annotation delete --snapshot-id ID NUMBER
        galaxy-snapshots annotation delete --ledger-session-id ID --snapshot N NUMBER

      REQUIRED:
        --snapshot-id ID          Snapshot database ID (or use --ledger-session-id + --snapshot)
        NUMBER                    Annotation number (snapshot-scoped)

      DESCRIPTION:
        Permanently deletes an annotation from the snapshot.
      HELP
    end

    private def self.show_review_help
      puts <<-HELP
      galaxy-snapshots review - Manage snapshot reviews

      USAGE:
        galaxy-snapshots review <command> [options]

      COMMANDS:
        create         Create a review from unreviewed annotations
        list           List reviews for a snapshot
        view           View a review with full context
        mark-reviewed  Mark a review as processed
        has-pending    Check if unreviewed annotations exist

      Run 'galaxy-snapshots review <command> --help' for detailed usage.
      HELP
    end

    private def self.show_review_create_help
      puts <<-HELP
      galaxy-snapshots review create - Create a review

      USAGE:
        galaxy-snapshots review create --snapshot-id ID
        galaxy-snapshots review create --ledger-session-id ID --snapshot N

      REQUIRED (one of):
        --snapshot-id ID          Snapshot database ID
        --ledger-session-id ID    Ledger session ID (use with --snapshot)
        --snapshot N              Snapshot number within the session

      DESCRIPTION:
        Creates a review and assigns all unreviewed annotations to it.
        Fails if there are no unreviewed annotations. Returns JSON with
        the created review and annotation count.
      HELP
    end

    private def self.show_review_list_help
      puts <<-HELP
      galaxy-snapshots review list - List reviews

      USAGE:
        galaxy-snapshots review list --snapshot-id ID [--pending] [--json]
        galaxy-snapshots review list --ledger-session-id ID --snapshot N [--pending] [--json]

      REQUIRED (one of):
        --snapshot-id ID          Snapshot database ID
        --ledger-session-id ID    Ledger session ID (use with --snapshot)
        --snapshot N              Snapshot number within the session

      OPTIONS:
        --pending                 Only show reviews not yet processed
        --json                    Output as JSON (envelope: {"reviews":[...]})

      DESCRIPTION:
        Lists reviews for the specified snapshot, ordered by number.
      HELP
    end

    private def self.show_review_view_help
      puts <<-HELP
      galaxy-snapshots review view - View a review

      USAGE:
        galaxy-snapshots review view --snapshot-id ID NUMBER [--json]
        galaxy-snapshots review view --ledger-session-id ID --snapshot N NUMBER [--json]

      REQUIRED:
        --snapshot-id ID          Snapshot database ID (or use --ledger-session-id + --snapshot)
        NUMBER                    Review number (snapshot-scoped)

      OPTIONS:
        --json                    Output as JSON with full context (review + snapshot + annotations)

      DESCRIPTION:
        Shows a review with its annotations. Human-readable format shows
        a summary with annotation previews. JSON format includes the full
        snapshot content for agent consumption — provides everything
        needed to respond to annotations in one round trip.
      HELP
    end

    private def self.show_review_has_pending_help
      puts <<-HELP
      galaxy-snapshots review has-pending - Check for unreviewed annotations

      USAGE:
        galaxy-snapshots review has-pending --snapshot-id ID
        galaxy-snapshots review has-pending --ledger-session-id ID --snapshot N

      REQUIRED (one of):
        --snapshot-id ID          Snapshot database ID
        --ledger-session-id ID    Ledger session ID (use with --snapshot)
        --snapshot N              Snapshot number within the session

      DESCRIPTION:
        Returns JSON with whether unreviewed annotations exist and the
        count. Used by Galaxy app to drive review button visibility.
      HELP
    end

    private def self.show_review_mark_reviewed_help
      puts <<-HELP
      galaxy-snapshots review mark-reviewed - Mark as processed

      USAGE:
        galaxy-snapshots review mark-reviewed --snapshot-id ID NUMBER
        galaxy-snapshots review mark-reviewed --ledger-session-id ID --snapshot N NUMBER

      REQUIRED:
        --snapshot-id ID          Snapshot database ID (or use --ledger-session-id + --snapshot)
        NUMBER                    Review number (snapshot-scoped)

      DESCRIPTION:
        Sets the reviewed_at timestamp on a review, indicating it has
        been processed. Idempotent — calling again updates the timestamp.
        Returns JSON with the updated review.
      HELP
    end

    private def self.show_backup_help
      puts <<-HELP
      galaxy-snapshots backup - Manage database backups

      USAGE:
        galaxy-snapshots backup                        Create a backup and prune old ones
        galaxy-snapshots backup --list                 List all backups
        galaxy-snapshots backup --prune-only           Prune old backups without creating new one

      OPTIONS:
        --session-id ID   Session record ID for backup filename (default: 0)
        --list            List all existing backups
        --prune-only      Only prune old backups, don't create a new one
        -h, --help        Show this help

      CONFIGURATION:
        Backup settings are managed by the shared Galaxy config.
        Use 'galaxy config' to view and 'galaxy config set' to change:
          galaxy config set backups.enabled true
          galaxy config set backups.retention_days 7
          galaxy config set backups.path /path/to/backups

      DESCRIPTION:
        Creates point-in-time database backups using SQLite VACUUM INTO.
        Backups are organized in date directories with session IDs in
        filenames. Old backups are automatically pruned based on the
        configured retention period.

      EXAMPLES:
        galaxy-snapshots backup                   # Create backup + prune
        galaxy-snapshots backup --list            # See all backups
        galaxy-snapshots backup --prune-only      # Clean up old backups
      HELP
    end
  end
end
