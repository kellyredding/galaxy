require "json"

module GalaxyLedger
  module Hooks
    # Handles the PreCompact hook
    # - Synchronously flushes buffer to SQLite before compaction
    # - Ensures no data loss during auto-compact
    # - Blocking hook (Claude Code waits for completion)
    class OnPreCompact
      @session_id : String?
      @source : String?

      def run
        # Parse hook input from stdin
        parse_hook_input

        session_id = @session_id
        return unless session_id

        # Sync flush buffer to ensure all entries are persisted
        # before compaction clears context
        result = Buffer.flush_sync(session_id)

        if result.success && result.entries_flushed > 0
          STDERR.puts "[galaxy-ledger] Pre-compact: flushed #{result.entries_flushed} entries"
        end
      end

      private def parse_hook_input
        # Hook receives JSON via stdin:
        # {
        #   "session_id": "abc123",
        #   "source": "auto|manual",
        #   ...
        # }
        begin
          input = STDIN.gets_to_end
          return if input.empty?

          json = JSON.parse(input)
          @session_id = json["session_id"]?.try(&.as_s?)
          @source = json["source"]?.try(&.as_s?)
        rescue
          # Silently ignore parse errors
        end
      end
    end
  end
end
