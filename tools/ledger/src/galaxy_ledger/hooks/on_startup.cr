require "json"

module GalaxyLedger
  module Hooks
    # Handles the SessionStart(startup) hook
    # - Ensures session folder exists
    # - Cleans up orphaned flushing file for current session only
    # - Injects ledger awareness prompt
    class OnStartup
      @session_id : String?

      def run
        # Parse hook input from stdin to get session_id
        parse_hook_input

        # Ensure session folder exists for current session
        ensure_session_folder

        # Clean up orphaned flushing file for current session only
        cleanup_current_session_orphans

        # Query ledger for stats (placeholder for Phase 1 - no SQLite yet)
        stats = get_ledger_stats

        # Build the awareness context
        context = build_awareness_context(stats)

        # Output JSON with additionalContext
        output = {
          "hookSpecificOutput" => {
            "hookEventName"     => "SessionStart",
            "additionalContext" => context,
          },
        }

        puts output.to_json
      end

      private def parse_hook_input
        # Hook receives JSON via stdin
        begin
          input = STDIN.gets_to_end
          return if input.empty?

          json = JSON.parse(input)
          @session_id = json["session_id"]?.try(&.as_s?)
        rescue
          # Silently ignore parse errors - we'll continue without session_id
        end
      end

      private def ensure_session_folder
        session_id = @session_id
        return unless session_id

        session_dir = GalaxyLedger.session_dir(session_id)
        Dir.mkdir_p(session_dir) unless Dir.exists?(session_dir)
      end

      private def cleanup_current_session_orphans
        session_id = @session_id
        return unless session_id

        session_dir = GalaxyLedger.session_dir(session_id)
        return unless Dir.exists?(session_dir)

        # Check for orphaned flushing file (from crashed flush)
        flushing_file = session_dir / LEDGER_BUFFER_FLUSHING_FILENAME
        if File.exists?(flushing_file)
          begin
            # TODO: In Phase 3, process this file (flush to database) before deleting
            # For now, just delete the orphaned file
            File.delete(flushing_file)
          rescue
            # Ignore errors during cleanup
          end
        end
      end

      private def get_ledger_stats : NamedTuple(sessions: Int32, entries: Int32, last_session: String?)
        # Count sessions by scanning sessions directory
        session_count = 0
        if Dir.exists?(SESSIONS_DIR)
          Dir.each_child(SESSIONS_DIR) do |child|
            session_path = SESSIONS_DIR / child
            session_count += 1 if Dir.exists?(session_path)
          end
        end

        # Phase 1: No SQLite yet, entries count is placeholder
        # Future phases will query the actual database
        {
          sessions:     session_count,
          entries:      0,
          last_session: nil,
        }
      end

      private def build_awareness_context(stats : NamedTuple(sessions: Int32, entries: Int32, last_session: String?)) : String
        lines = [] of String
        lines << "## Galaxy Ledger Available"
        lines << ""
        lines << "You have access to a persistent context ledger that tracks learnings, decisions, and file interactions across sessions."
        lines << ""
        lines << "The ledger automatically:"
        lines << "- Extracts key insights from conversations"
        lines << "- Tracks important decisions with rationale"
        lines << "- Records file interactions"
        lines << "- Restores context after /clear or compaction"
        lines << ""

        if stats[:sessions] > 0
          lines << "### Ledger Stats"
          lines << "- Sessions tracked: #{stats[:sessions]}"
          if stats[:entries] > 0
            lines << "- Total entries: #{stats[:entries]}"
          end
          if last = stats[:last_session]
            lines << "- Last session: #{last}"
          end
          lines << ""
        end

        lines << "Use `galaxy-ledger search \"query\"` to search the ledger."

        lines.join("\n")
      end
    end
  end
end
