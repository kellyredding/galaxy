require "json"

module GalaxyLedger
  module Hooks
    # Handles the SessionStart(startup) hook.
    #
    # On genuine fresh start (no env var match): creates a new session
    # record and registers all available identifiers.
    #
    # On --resume (env var matches existing session): resolves to the
    # existing session instead of creating an orphan. Claude Code fires
    # startup before resume on --resume; without this check, an orphan
    # record would be created.
    #
    # PID is not used for resolution here — on startup the PID is always
    # a new process, so any PID match would be stale.
    class OnStartup
      @session_identifier : String?

      def run
        # Skip if GALAXY_SKIP_HOOKS is set (prevents recursion from extraction subprocesses)
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        # Parse hook input from stdin to get session_id
        parse_hook_input

        claude_pid = Process.ppid.to_i64
        env_session_id = ENV[Resolver::ENV_SESSION_ID_KEY]?
        session_id = @session_identifier

        return unless session_id && !session_id.empty?

        # Check if env var resolves to an existing session.
        # On --resume, Claude Code fires startup before resume. If the env
        # var already maps to a session, this is a resume — resolve to it
        # instead of creating an orphan.
        ledger_session_id : Int64? = nil
        if env_id = env_session_id
          unless env_id.empty?
            ledger_session_id = Database.resolve_session_identifier(env_id)
          end
        end

        if ledger_session_id && ledger_session_id > 0
          # Existing session found via env var — update PID and register
          # new hook session_id. Don't create a new session.
          Database.register_claude_pid(ledger_session_id, claude_pid)
          Database.register_session_identifier(ledger_session_id, session_id)
        else
          # No env var match — genuine fresh start. Create new session.
          ledger_session_id = Database.create_session(
            session_id,
            claude_pid: claude_pid,
            cwd: Dir.current,
          )

          return if ledger_session_id <= 0

          # Register env var mapping if available.
          # create_session already registers session_id + PID internally.
          if env_id = env_session_id
            unless env_id.empty?
              Database.register_session_identifier(ledger_session_id, env_id)
            end
          end
        end

        # Query existing session data (will be empty for fresh session)
        restoration = Database.query_for_restoration(ledger_session_id)
        files = Database.session_files(ledger_session_id)

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
        Database.merge_session_context(ledger_session_id, "injected_context", context)

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
