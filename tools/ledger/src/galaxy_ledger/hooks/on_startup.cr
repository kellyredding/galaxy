require "json"

module GalaxyLedger
  module Hooks
    # Handles the SessionStart(startup) hook — REGISTER MODE
    # - Creates session record in DB with Claude Code PID
    # - Registers session identifier and PID in mapping tables
    # - Injects ledger awareness prompt with lookup directives
    # This is the ONLY hook that creates session records.
    class OnStartup
      @session_identifier : String?

      def run
        # Skip if GALAXY_SKIP_HOOKS is set (prevents recursion from extraction subprocesses)
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        # Parse hook input from stdin to get session_id
        parse_hook_input

        # Register: create session record with PID, register mappings.
        # Try resolving first in case this session_identifier already exists
        # (e.g., process restart with same session ID).
        session_identifier = @session_identifier
        claude_pid = Process.ppid.to_i64
        ledger_session_id = 0_i64
        if session_identifier
          resolved = Database.resolve_session_identifier(session_identifier)
          if resolved
            ledger_session_id = resolved
            Database.register_claude_pid(ledger_session_id, claude_pid)
            Database.update_session(ledger_session_id, claude_pid: claude_pid)
          else
            ledger_session_id = Database.create_session(session_identifier, claude_pid: claude_pid, cwd: Dir.current)
          end
        end

        # Query existing session data (may have data if resuming)
        restoration : Database::RestorationResult? = nil
        files : Array(Database::SessionFile)? = nil
        if ledger_session_id > 0
          restoration = Database.query_for_restoration(ledger_session_id)
          files = Database.session_files(ledger_session_id)
        end

        # Build systemMessage
        system_message = Helpers.build_system_message(
          prefix: "Ledger active",
          empty_message: "New session",
          restoration: restoration,
          files: files,
        )

        # Build the awareness context
        context = build_awareness_context(claude_pid)

        # Persist injected context to session record
        if ledger_session_id > 0
          Database.merge_session_context(ledger_session_id, "injected_context", context)
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

      private def build_awareness_context(claude_pid : Int64) : String
        lines = [] of String
        lines << "## Galaxy Ledger"
        lines << ""
        lines << "**Ledger PID**: `#{claude_pid}`"
        lines << ""

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

        lines << "1. **Query the ledger**: `galaxy-ledger search --query \"QUERY\" --pid #{claude_pid}`"
        lines << "2. **Check recent code changes**: `git diff` and `git log --oneline -20`"
        lines << "3. **Check session files**: `galaxy-ledger list-files --pid #{claude_pid}`"
        lines << "   to see every file read, edited, written, or searched this session"
        lines << "4. **Fall back to normal exploration** \u2014 Grep, Glob, Read as usual"

        lines.join("\n")
      end
    end
  end
end
