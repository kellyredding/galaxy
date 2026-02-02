require "json"

module GalaxyLedger
  module Hooks
    # Handles the Stop hook
    # - Parses transcript to capture last exchange
    # - Writes to ledger_last-exchange.json
    # - Checks context thresholds and shows warnings
    # - Spawns async extraction (Phase 6)
    class OnStop
      @session_id : String?
      @transcript_path : String?
      @stop_hook_active : Bool = false

      def run
        # Parse hook input from stdin
        parse_hook_input

        # Prevent infinite loops - if stop hook is already active, return immediately
        if @stop_hook_active
          return
        end

        # Capture last exchange from transcript
        capture_last_exchange

        # Check context thresholds and build warning message if needed
        warning = check_context_thresholds

        # If we have a warning, output it
        if warning
          puts warning
        end

        # TODO Phase 6: Spawn async extraction process here
        # spawn_extraction_process
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
    end
  end
end
