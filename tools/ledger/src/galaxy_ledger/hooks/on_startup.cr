require "json"

module GalaxyLedger
  module Hooks
    # Handles the SessionStart(startup) hook
    # - Ensures session folder exists
    # - Upserts session record in DB
    # - Injects ledger awareness prompt with lookup directives
    class OnStartup
      @session_identifier : String?

      def run
        # Skip if GALAXY_SKIP_HOOKS is set (prevents recursion from extraction subprocesses)
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        # Parse hook input from stdin to get session_id
        parse_hook_input

        # Ensure session folder exists for current session
        ensure_session_folder

        # Upsert session record in database (creates if new, touches updated_at if existing)
        session_identifier = @session_identifier
        if session_identifier
          Database.upsert_session(session_identifier, cwd: Dir.current)
        end

        # Query existing session data (may have data if resuming)
        restoration : Database::RestorationResult? = nil
        files : Array(Database::SessionFile)? = nil
        if session_identifier
          restoration = Database.query_for_restoration(session_identifier)
          files = Database.session_files(session_identifier)
        end

        # Build systemMessage
        system_message = Helpers.build_system_message(
          prefix: "Ledger active",
          empty_message: "New session",
          restoration: restoration,
          files: files,
        )

        # Build the awareness context
        context = build_awareness_context

        # Persist injected context to session record
        if session_identifier
          Database.merge_session_context(session_identifier, "injected_context", context)
        end

        # Output JSON with systemMessage and additionalContext
        puts Helpers.output_json(system_message, context)
      end

      private def parse_hook_input
        # Hook receives JSON via stdin
        begin
          input = STDIN.gets_to_end
          return if input.empty?

          json = JSON.parse(input)
          @session_identifier = json["session_id"]?.try(&.as_s?)
        rescue
          # Silently ignore parse errors - we'll continue without session_identifier
        end
      end

      private def ensure_session_folder
        session_identifier = @session_identifier
        return unless session_identifier

        session_dir = GalaxyLedger.session_dir(session_identifier)
        Dir.mkdir_p(session_dir) unless Dir.exists?(session_dir)
      end

      private def build_awareness_context : String
        session_identifier = @session_identifier

        lines = [] of String
        lines << "## Galaxy Ledger"
        lines << ""

        if session_identifier
          lines << "**Session ID**: `#{session_identifier}`"
          lines << ""
        end

        lines << "A persistent context ledger is active for this session. It"
        lines << "automatically captures the following as you work:"
        lines << ""
        lines << "- **Guidelines**: Extracted rules when guideline files are read"
        lines << "- **Implementation plans**: Extracted context when plan files are read"
        lines << "- **Decisions**: Key choices and their rationale (extracted at session"
        lines << "  end)"
        lines << "- **Learnings**: Insights and discoveries (extracted at session end)"
        lines << "- **Session files**: Every file read, edited, written, or searched"
        lines << ""
        lines << "This information persists across context resets within this session."
        lines << "When you need to recall something from earlier in this session \u2014"
        lines << "before doing broader searches:"
        lines << ""

        if session_identifier
          lines << "1. **Query the ledger**: `galaxy-ledger search --query \"QUERY\" --session #{session_identifier}`"
          lines << "2. **Check recent code changes**: `git diff` and `git log --oneline -20`"
          lines << "3. **Check session files**: `galaxy-ledger list-files --session #{session_identifier}`"
          lines << "   to see every file read, edited, written, or searched this session"
          lines << "4. **Fall back to normal exploration** \u2014 Grep, Glob, Read as usual"
        else
          lines << "1. **Query the ledger**: `galaxy-ledger search --query \"QUERY\"`"
          lines << "2. **Check recent code changes**: `git diff` and `git log --oneline -20`"
          lines << "3. **Fall back to normal exploration** \u2014 Grep, Glob, Read as usual"
        end

        lines.join("\n")
      end
    end
  end
end
