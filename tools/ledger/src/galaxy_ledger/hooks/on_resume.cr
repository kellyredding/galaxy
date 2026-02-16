require "json"

module GalaxyLedger
  module Hooks
    # Handles the SessionStart(resume) hook.
    #
    # Resolves the original session via env var (preferred) or stdin
    # session_id. PID is NOT used for resolution — on resume the PID is
    # always a new process, and OnStartup may have already claimed it
    # for an orphan session.
    #
    # After resolving, cleans up any orphan session created by OnStartup
    # (which fires before OnResume on --resume). If PID points to a
    # different session than the one we resolved, that's the orphan —
    # all its mappings are saved, the orphan is deleted, and mappings
    # are re-registered against the real session.
    #
    # Unlike clear/compact, the agent already has conversation history
    # restored by Claude Code on resume. So we inject awareness context
    # (how to query the ledger) plus a brief summary of what the ledger
    # has accumulated, rather than the full handoff markdown.
    class OnResume
      @stdin_session_identifier : String?

      def run
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        parse_hook_input

        claude_pid = Process.ppid.to_i64
        env_session_id = ENV[Resolver::ENV_SESSION_ID_KEY]?

        # Resolve to original session. PID is useless on resume (new
        # process, and OnStartup may have already claimed it for an orphan).
        # Resolution: env var → stdin session_id. No create fallback.
        ledger_session_id = resolve_for_resume(
          env_session_id: env_session_id,
          stdin_session_id: @stdin_session_identifier,
          claude_pid: claude_pid,
        )

        return output_empty unless ledger_session_id && ledger_session_id > 0

        # Orphan cleanup: OnStartup may have created an orphan session and
        # registered our PID against it. If PID points to a different session
        # than the one we just resolved, that's the orphan — delete it and
        # consolidate all its mappings.
        cleanup_startup_orphan(claude_pid, ledger_session_id)

        # Register the new PID and hook session_id against the resolved session.
        Database.register_claude_pid(ledger_session_id, claude_pid)

        if stdin_id = @stdin_session_identifier
          unless stdin_id.empty?
            Database.register_session_identifier(ledger_session_id, stdin_id)
            Database.update_session(
              ledger_session_id,
              session_identifier: stdin_id,
              claude_pid: claude_pid,
            )
          end
        end

        # Query existing session data for awareness + restoration
        restoration = Database.query_for_restoration(ledger_session_id)
        files = Database.session_files(ledger_session_id)

        # Build systemMessage
        system_message = Helpers.build_system_message(
          prefix: "Resumed",
          empty_message: "Session resumed",
          restoration: restoration,
          files: files,
        )

        # Build awareness context with brief restoration summary
        context = build_resume_context(
          claude_pid: claude_pid,
          restoration: restoration,
          files: files,
        )

        puts Helpers.output_json(system_message, context)
      end

      private def parse_hook_input
        begin
          input = STDIN.gets_to_end
          return if input.empty?

          json = JSON.parse(input)
          @stdin_session_identifier = json["session_id"]?.try(&.as_s?)
        rescue
          # Silently ignore parse errors
        end
      end

      # Resume-specific resolution: env var → stdin session_id.
      # PID is never used (always a new process on resume).
      # No create fallback — if nothing resolves, return nil.
      private def resolve_for_resume(
        env_session_id : String?,
        stdin_session_id : String?,
        claude_pid : Int64,
      ) : Int64?
        # 1. Env var (durable identity from persona)
        if env_id = env_session_id
          unless env_id.empty?
            lid = Database.resolve_session_identifier(env_id)
            return lid if lid
          end
        end

        # 2. Stdin session_id (original session UUID on resume)
        # Skip PID — it's always a new process on resume, and OnStartup
        # may have already claimed it for an orphan.
        if sid = stdin_session_id
          unless sid.empty?
            lid = Database.resolve_session_identifier(sid)
            return lid if lid
          end
        end

        # No create fallback. If nothing resolves, the ledger has no record
        # of this session. The orphan from OnStartup (if any) survives and
        # becomes the de facto session for PID-based hooks going forward.
        nil
      end

      # Clean up orphan session created by OnStartup on --resume.
      #
      # OnStartup fires before OnResume and may create an orphan session
      # with our PID. If the PID currently maps to a different session
      # than the one we resolved, that's the orphan.
      #
      # Defensive: saves ALL identifier and PID mappings from the orphan
      # before CASCADE-deleting it, then re-registers them against the
      # resolved session so nothing is lost.
      private def cleanup_startup_orphan(claude_pid : Int64, resolved_session_id : Int64)
        # Check what session the PID currently points to.
        pid_session_id = Database.resolve_claude_pid(claude_pid)
        return unless pid_session_id
        return if pid_session_id == resolved_session_id

        # PID points to a different session — that's the orphan.
        # Save all mappings before CASCADE delete wipes them.
        orphan_identifiers = Database.session_identifiers(pid_session_id)
        orphan_pids = Database.session_pids(pid_session_id)

        Database.delete_session(pid_session_id)

        # Re-register all orphan mappings against the resolved session.
        orphan_identifiers.each do |sid|
          Database.register_session_identifier(resolved_session_id, sid) unless sid.empty?
        end
        orphan_pids.each do |pid|
          Database.register_claude_pid(resolved_session_id, pid) if pid > 0
        end
      end

      private def build_resume_context(
        claude_pid : Int64,
        restoration : Database::RestorationResult,
        files : Array(Database::SessionFile),
      ) : String
        lines = [] of String

        # Ledger awareness (same as on_startup)
        lines << "## Galaxy Ledger"
        lines << ""
        lines << "**Ledger PID**: `#{claude_pid}`"
        lines << ""
        lines << "A persistent context ledger is active for this session. It"
        lines << "automatically captures the following as you work:"
        lines << ""
        lines << "- **Guidelines**: Extracted rules when guideline files are read"
        lines << "- **Implementation plans**: Extracted context when plan files are read"
        lines << "- **Decisions**: Key choices and their rationale (extracted at session end)"
        lines << "- **Learnings**: Insights and discoveries (extracted at session end)"
        lines << "- **Session files**: Every file read, edited, written, or searched"
        lines << ""

        # Brief restoration summary (not the full handoff — Claude Code
        # already restores the conversation history on resume)
        has_data = restoration.total_count > 0 || files.size > 0

        if has_data
          lines << "This is a **resumed session**. The conversation history is already"
          lines << "restored by Claude Code. The ledger has additional accumulated"
          lines << "context from this session:"
          lines << ""

          counts = [] of String
          g = restoration.tier1.guidelines.size
          counts << "#{g} guidelines" if g > 0
          p = restoration.tier1.implementation_plans.size
          counts << "#{p} implementation plans" if p > 0
          d = restoration.tier1.high_importance_decisions.size +
              restoration.tier2.medium_decisions.size
          counts << "#{d} decisions" if d > 0
          l = restoration.tier2.learnings.size
          counts << "#{l} learnings" if l > 0
          f = files.size
          counts << "#{f} session files tracked" if f > 0

          lines << "- #{counts.join(", ")}" if counts.any?
          lines << ""
        end

        lines << "When you need to recall something from this session:"
        lines << ""
        lines << "1. **Query the ledger**: `galaxy-ledger search --query \"QUERY\" --pid #{claude_pid}`"
        lines << "2. **Check recent code changes**: `git diff` and `git log --oneline -20`"
        lines << "3. **Check session files**: `galaxy-ledger list-files --pid #{claude_pid}`"
        lines << "   to see every file read, edited, written, or searched this session"
        lines << "4. **Fall back to normal exploration** \u2014 Grep, Glob, Read as usual"

        lines.join("\n")
      end

      private def output_empty
        puts Helpers.output_json(
          "Resumed \u2502 Session resumed",
          "",
        )
      end
    end
  end
end
