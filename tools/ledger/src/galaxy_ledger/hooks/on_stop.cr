require "json"

module GalaxyLedger
  module Hooks
    # Handles the Stop hook — RESOLVE MODE
    # - Resolves session by Claude Code PID
    # - Parses transcript to capture last exchange
    # - Writes last interaction to DB session record
    # - Reports context usage via colored status indicator
    # - Spawns async extraction for learnings/decisions/summary
    #
    # Output: Claude Code Stop hook JSON format
    #   { "decision": "approve", "systemMessage": "🟢 Context 34% │ ..." }
    class OnStop
      @stdin_session_identifier : String?
      @transcript_path : String?
      @stop_hook_active : Bool = false

      def run
        # Skip if GALAXY_SKIP_HOOKS is set (prevents recursion from extraction subprocesses)
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        # Parse hook input from stdin
        parse_hook_input

        # Prevent infinite loops - if stop hook is already active, return immediately
        if @stop_hook_active
          return
        end

        # Resolve session via 3-tier chain (PID → env var → hook session_id).
        # No creation — bail if nothing resolves.
        claude_pid = Process.ppid.to_i64
        env_session_id = ENV[Resolver::ENV_SESSION_ID_KEY]?

        ledger_session_id = Resolver.resolve_session(
          claude_pid: claude_pid,
          env_session_id: env_session_id,
          stdin_session_id: @stdin_session_identifier,
        )
        return unless ledger_session_id

        # Get current session_identifier for extraction subprocess --session flags
        session_record = Database.get_session_by_id(ledger_session_id)
        current_sid = session_record.try(&.current_session_identifier) || @stdin_session_identifier
        return unless current_sid

        # Capture last exchange from transcript
        exchange_captured = capture_last_exchange(ledger_session_id)

        # Spawn async extraction process for learnings/decisions/summary
        extraction_spawned = spawn_extraction_async(ledger_session_id, current_sid)

        # Re-extract any guideline/implementation plan files that were
        # edited during this session (stale entries)
        re_extracted_files = re_extract_stale_files(ledger_session_id, current_sid)

        # Re-read session record to get latest context_percentage
        session_record = Database.get_session_by_id(ledger_session_id)
        return unless session_record

        # Build and output structured JSON system message
        system_message = build_system_message(
          percentage: session_record.context_percentage,
          exchange_captured: exchange_captured,
          extraction_spawned: extraction_spawned,
          re_extracted_files: re_extracted_files,
        )
        puts output_stop_json(system_message)
      end

      private def parse_hook_input
        # Hook receives JSON via stdin:
        # {
        #   "session_id": "abc123",
        #   "transcript_path": "/path/to/transcript.jsonl",
        #   "stop_hook_active": true|false,
        #   ...
        # }
        begin
          input = STDIN.gets_to_end
          return if input.empty?

          json = JSON.parse(input)
          @stdin_session_identifier = json["session_id"]?.try(&.as_s?)
          @transcript_path = json["transcript_path"]?.try(&.as_s?)
          @stop_hook_active = json["stop_hook_active"]?.try(&.as_bool?) || false
        rescue
          # Silently ignore parse errors
        end
      end

      private def capture_last_exchange(ledger_session_id : Int64) : Bool
        transcript_path = @transcript_path
        return false unless transcript_path

        # Parse transcript
        entries = Transcript.parse(transcript_path)
        return false if entries.empty?

        # Extract last exchange
        extracted = Transcript.extract_last_exchange(entries)
        return false unless extracted

        # Convert to LastExchange format and write to DB
        last_exchange = Transcript.to_last_exchange(extracted)
        Database.update_session_last_interaction(ledger_session_id, last_exchange.to_pretty_json)
        true
      rescue
        false
      end

      # Build the context indicator when above warning thresholds.
      # Returns nil when below warning threshold (no indicator shown).
      # Uses configurable thresholds for warning/critical boundaries.
      # Reads ~/.claude.json to tailor the critical message based on
      # whether auto-compact is enabled.
      #
      #   nil                                                       (below warning)
      #   ⚠️ Context 72% — consider /clear soon                     (warning)
      #   🔥 Context 87% — will auto-compact at 95%                 (critical, auto-compact on)
      #   🔥 Context 87% — context nearly full, /clear now          (critical, auto-compact off)
      private def build_context_indicator(percentage : Float64) : String?
        config = Config.load

        pct = percentage.round.to_i
        pct = 0 if pct < 0

        if percentage >= config.thresholds.critical
          if auto_compact_enabled?
            "\u{1F525} Context #{pct}% \u2014 will auto-compact at 95%"
          else
            "\u{1F525} Context #{pct}% \u2014 context nearly full, /clear now"
          end
        elsif percentage >= config.thresholds.warning
          "\u26A0\uFE0F Context #{pct}% \u2014 consider /clear soon"
        else
          nil
        end
      end

      # Check if Claude Code's auto-compact feature is enabled.
      # Reads ~/.claude.json (Claude Code's app state file).
      # Defaults to true (safer assumption) if the file can't be read.
      # Path is overridable via GALAXY_CLAUDE_JSON_PATH env var for testing.
      private def auto_compact_enabled? : Bool
        path = ENV["GALAXY_CLAUDE_JSON_PATH"]? || (Path.home / ".claude.json").to_s
        return true unless File.exists?(path)

        json = JSON.parse(File.read(path))
        json["autoCompactEnabled"]?.try(&.as_bool?) || false
      rescue
        true
      end

      # Assemble the full system message from activity parts.
      # Format: {context_indicator} │ {activity parts...}
      private def build_system_message(
        percentage : Float64,
        exchange_captured : Bool,
        extraction_spawned : Bool,
        re_extracted_files : Array(String),
      ) : String
        parts = [] of String
        indicator = build_context_indicator(percentage)
        parts << indicator if indicator
        parts << "Exchange captured" if exchange_captured
        parts << "Extraction spawned" if extraction_spawned

        if re_extracted_files.any?
          names = re_extracted_files.map { |f| File.basename(f) }
          parts << "Re-extracting: #{names.join(", ")}"
        end

        parts.join(" \u2502 ")
      end

      # Output Claude Code Stop hook JSON format.
      private def output_stop_json(system_message : String) : String
        {
          "decision"      => "approve",
          "systemMessage" => system_message,
        }.to_json
      end

      private def spawn_extraction_async(ledger_session_id : Int64, current_sid : String) : Bool
        transcript_path = @transcript_path
        return false unless transcript_path

        # Check if extraction is enabled in config
        config = Config.load
        return false unless config.extraction.on_stop

        # Read the last exchange from the DB session record
        session_record = Database.get_session_by_id(ledger_session_id)
        return false unless session_record

        json_str = session_record.last_interaction
        return false unless json_str

        last_exchange = begin
          Exchange::LastExchange.from_json(json_str)
        rescue
          return false
        end

        user_message = last_exchange.user_message
        assistant_content = last_exchange.full_content

        return false if user_message.strip.empty? || assistant_content.strip.empty?

        # Spawn async extraction process
        # NOTE: extraction subprocesses use --session (not --pid) because their
        # PPID is the hook process, not Claude Code.
        begin
          binary = Process.executable_path || "galaxy-ledger"

          # Pass the content via a temp file to avoid stdin issues with large content
          temp_file = File.tempfile("extraction", ".json")
          temp_file.puts({
            "user_message"      => user_message,
            "assistant_content" => assistant_content,
          }.to_json)
          temp_file.close

          Process.new(
            binary,
            args: ["extract-assistant", "--session", current_sid, "--input-file", temp_file.path],
            input: Process::Redirect::Close,
            output: Process::Redirect::Close,
            error: Process::Redirect::Close,
          )
          true
        rescue
          false
        end
      end

      # Re-extract guideline/implementation plan files that were edited
      # during this session. Reads fresh content from disk, prunes stale
      # DB entries, and spawns async extract-file subprocesses.
      # Returns list of file paths that were re-extracted.
      # NOTE: extraction subprocesses use --session (not --pid) because their
      # PPID is the hook process, not Claude Code.
      private def re_extract_stale_files(ledger_session_id : Int64, current_sid : String) : Array(String)
        re_extracted = [] of String

        stale = Database.stale_entries(ledger_session_id)
        return re_extracted if stale.empty?

        binary = Process.executable_path || "galaxy-ledger"

        stale.each do |entry|
          # Read fresh content from disk; skip if file is gone
          next unless File.exists?(entry[:full_path])

          content = begin
            File.read(entry[:full_path])
          rescue
            next
          end

          next if content.strip.empty?

          # Prune stale entries, then spawn re-extraction with fresh content
          Database.delete_entries_by_source_file(ledger_session_id, entry[:source_file])

          begin
            Process.new(
              binary,
              args: ["extract-file", "--session", current_sid, "--type", entry[:entry_type], "--path", entry[:full_path]],
              input: IO::Memory.new(content),
              output: Process::Redirect::Close,
              error: Process::Redirect::Close,
            )
            re_extracted << entry[:full_path]
          rescue
            # Silently fail - re-extraction is best-effort
          end
        end

        re_extracted
      end
    end
  end
end
