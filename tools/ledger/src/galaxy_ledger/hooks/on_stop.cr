require "json"

module GalaxyLedger
  module Hooks
    # Handles the Stop hook — RESOLVE MODE
    # - Resolves session by Claude Code PID
    # - Parses transcript to capture last exchange
    # - Writes last interaction to DB session record
    # - Checks context thresholds and shows warnings
    # - Spawns async extraction for learnings/decisions/summary
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

        # Resolve session by PID → ledger_session_id
        claude_pid = Process.ppid.to_i64
        ledger_session_id = Database.resolve_claude_pid(claude_pid)

        # Fallback: try resolving stdin session_identifier
        unless ledger_session_id
          if sid = @stdin_session_identifier
            ledger_session_id = Database.resolve_session_identifier(sid)
          end
        end
        return unless ledger_session_id

        # Get current session_identifier for extraction subprocess --session flags
        session_record = Database.get_session_by_id(ledger_session_id)
        current_sid = session_record.try(&.current_session_identifier) || @stdin_session_identifier
        return unless current_sid

        # Capture last exchange from transcript
        capture_last_exchange(ledger_session_id)

        # Check context thresholds and build warning message if needed
        warning = check_context_thresholds(ledger_session_id)

        # If we have a warning, output it
        if warning
          puts warning
        end

        # Spawn async extraction process for learnings/decisions/summary
        spawn_extraction_async(ledger_session_id, current_sid)

        # Re-extract any guideline/implementation plan files that were
        # edited during this session (stale entries)
        re_extract_stale_files(ledger_session_id, current_sid)
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

      private def capture_last_exchange(ledger_session_id : Int64)
        transcript_path = @transcript_path
        return unless transcript_path

        # Parse transcript
        entries = Transcript.parse(transcript_path)
        return if entries.empty?

        # Extract last exchange
        extracted = Transcript.extract_last_exchange(entries)
        return unless extracted

        # Convert to LastExchange format and write to DB
        last_exchange = Transcript.to_last_exchange(extracted)
        Database.update_session_last_interaction(ledger_session_id, last_exchange.to_pretty_json)
      end

      private def check_context_thresholds(ledger_session_id : Int64) : String?
        # Read context percentage from DB (written by statusline → update-session-metrics)
        session_record = Database.get_session_by_id(ledger_session_id)
        return nil unless session_record

        percentage = session_record.context_percentage
        return nil if percentage <= 0.0

        # Load config for thresholds
        config = Config.load

        # Check critical threshold first (85% default)
        if percentage >= config.thresholds.critical
          if config.warnings.at_critical_threshold
            return build_critical_warning(percentage)
          end
          # Check warning threshold (70% default)
        elsif percentage >= config.thresholds.warning
          if config.warnings.at_warning_threshold
            return build_warning(percentage)
          end
        end

        nil
      end

      private def build_warning(percentage : Float64) : String
        "⚠️  Context at #{percentage.round.to_i}%. Consider /clear soon to preserve performance."
      end

      private def build_critical_warning(percentage : Float64) : String
        lines = [] of String
        lines << "🚨 Context at #{percentage.round.to_i}%. Please /clear now."
        lines << "   Auto-compact will trigger at 95% and may lose important context."
        lines.join("\n")
      end

      private def spawn_extraction_async(ledger_session_id : Int64, current_sid : String)
        transcript_path = @transcript_path
        return unless transcript_path

        # Check if extraction is enabled in config
        config = Config.load
        return unless config.extraction.on_stop

        # Read the last exchange from the DB session record
        session_record = Database.get_session_by_id(ledger_session_id)
        return unless session_record

        json_str = session_record.last_interaction
        return unless json_str

        last_exchange = begin
          Exchange::LastExchange.from_json(json_str)
        rescue
          return
        end

        user_message = last_exchange.user_message
        assistant_content = last_exchange.full_content

        return if user_message.strip.empty? || assistant_content.strip.empty?

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
        rescue
          # Silently fail - extraction is best-effort
        end
      end

      # Re-extract guideline/implementation plan files that were edited
      # during this session. Reads fresh content from disk, prunes stale
      # DB entries, and spawns async extract-file subprocesses.
      # NOTE: extraction subprocesses use --session (not --pid) because their
      # PPID is the hook process, not Claude Code.
      private def re_extract_stale_files(ledger_session_id : Int64, current_sid : String)
        stale = Database.stale_entries(ledger_session_id)
        return if stale.empty?

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
          rescue
            # Silently fail - re-extraction is best-effort
          end
        end
      end
    end
  end
end
