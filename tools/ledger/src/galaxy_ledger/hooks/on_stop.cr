require "json"

module GalaxyLedger
  module Hooks
    # Handles the Stop hook
    # - Parses transcript to capture last exchange
    # - Writes to ledger_last-exchange.json
    # - Flushes buffer to SQLite (async) for data durability
    # - Checks context thresholds and shows warnings
    # - Spawns async extraction (Phase 6)
    class OnStop
      @session_id : String?
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

        # Capture last exchange from transcript
        capture_last_exchange

        # Flush buffer to SQLite (async) for data durability
        # This ensures entries are persisted after each completed response,
        # so if the user closes the terminal, only the current exchange is lost
        flush_buffer_async

        # Check context thresholds and build warning message if needed
        warning = check_context_thresholds

        # If we have a warning, output it
        if warning
          puts warning
        end

        # Phase 6: Spawn async extraction process for learnings/decisions/summary
        spawn_extraction_async
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
          @session_id = json["session_id"]?.try(&.as_s?)
          @transcript_path = json["transcript_path"]?.try(&.as_s?)
          @stop_hook_active = json["stop_hook_active"]?.try(&.as_bool?) || false
        rescue
          # Silently ignore parse errors
        end
      end

      private def flush_buffer_async
        session_id = @session_id
        return unless session_id

        # Only flush if there's actually a buffer to flush
        return unless Buffer.exists?(session_id)

        # Async flush - spawns detached subprocess that persists to SQLite
        Buffer.flush_async(session_id)
      end

      private def capture_last_exchange
        session_id = @session_id
        transcript_path = @transcript_path

        return unless session_id && transcript_path

        # Ensure session folder exists
        session_dir = GalaxyLedger.session_dir(session_id)
        Dir.mkdir_p(session_dir) unless Dir.exists?(session_dir)

        # Parse transcript
        entries = Transcript.parse(transcript_path)
        return if entries.empty?

        # Extract last exchange
        extracted = Transcript.extract_last_exchange(entries)
        return unless extracted

        # Convert to LastExchange format and write
        last_exchange = Transcript.to_last_exchange(extracted)
        Exchange.write(session_id, last_exchange)
      end

      private def check_context_thresholds : String?
        session_id = @session_id
        return nil unless session_id

        # Read context status (from statusline bridge)
        status = ContextStatus.read(session_id)
        return nil unless status

        percentage = status.percentage
        return nil unless percentage

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

      private def spawn_extraction_async
        session_id = @session_id
        transcript_path = @transcript_path

        return unless session_id && transcript_path

        # Check if extraction is enabled in config
        config = Config.load
        return unless config.extraction.on_stop

        # Read the last exchange that was just captured
        last_exchange = Exchange.read(session_id)
        return unless last_exchange

        user_message = last_exchange.user_message
        assistant_content = last_exchange.full_content

        return if user_message.strip.empty? || assistant_content.strip.empty?

        # Spawn async extraction process
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
            args: ["extract-assistant", "--session", session_id, "--input-file", temp_file.path],
            input: Process::Redirect::Close,
            output: Process::Redirect::Close,
            error: Process::Redirect::Close,
          )
        rescue
          # Silently fail - extraction is best-effort
        end
      end
    end
  end
end
