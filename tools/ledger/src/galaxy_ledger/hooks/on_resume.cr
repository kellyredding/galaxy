require "json"

module GalaxyLedger
  module Hooks
    # Handles the SessionStart(resume) hook.
    #
    # Resolves the original session via env var (preferred) or stdin
    # session_id. PID is NOT used for resolution — on resume the PID is
    # always a new process, and OnStartup may have claimed it for an
    # orphan when env_session_id was missing at startup time.
    #
    # After resolving, conditionally cleans up any orphan session
    # created by OnStartup. The cleanup is strictly guardrailed: only
    # sessions that look freshly created and empty are merged. A PID
    # pointing at an older session is treated as OS PID recycling and
    # the old session is left intact — register_claude_pid updates the
    # stale PID row in place. See cleanup_startup_orphan for details.
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

        # Orphan cleanup: if OnStartup created a fresh orphan for this
        # PID, merge it into the resolved session. Guardrailed — sessions
        # with accumulated data are preserved (OS PID recycling, not an
        # orphan). See cleanup_startup_orphan for the safety criteria.
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

        # Fetch session record for cwd/git_branch
        session_record = Database.get_session_by_id(ledger_session_id)

        # Query existing session data for awareness + restoration
        restoration = Database.query_for_restoration(ledger_session_id)
        files = Database.session_files(ledger_session_id)

        # Record timeline event (fire-and-forget)
        begin
          decisions = restoration.tier1
            .high_importance_decisions.size +
                      restoration.tier2.medium_decisions.size
          learnings = restoration.tier2.learnings.size

          Process.new(
            TIMELINE_BIN.to_s,
            args: [
              "record",
              "--ledger-session-id",
              ledger_session_id.to_s,
              "--event-type", "session:resumed",
              "--source",
              "galaxy-ledger/hooks/on_resume",
              "--duration-identifier",
              "ledger-session-id--#{ledger_session_id}",
              "--detail-data",
              {
                cwd:             Dir.current,
                git_branch:      compute_git_branch,
                decisions_count: decisions,
                learnings_count: learnings,
                files_count:     files.size,
              }.to_json,
            ],
            input: Process::Redirect::Close,
            output: Process::Redirect::Close,
            error: Process::Redirect::Close,
          )
        rescue
          # Best-effort — timeline unavailable is not fatal
        end

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
          cwd: Helpers.best_cwd(session_record),
          git_branch: session_record.try(&.git_branch),
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
      # OnStartup can create an orphan session when env_session_id is
      # missing on --resume (fresh-start fallback path creates a new
      # session before OnResume resolves the real one). If the PID now
      # maps to a different session than the one we resolved, that's
      # the candidate orphan.
      #
      # GUARDRAIL: a "different session" mapping can also mean the OS
      # recycled a PID that was last registered weeks ago to a real
      # long-running session. We MUST NOT CASCADE-delete those. Only
      # proceed if the candidate looks like a freshly-created, empty
      # orphan (recent started_at, zero entries/files, minimal PIDs and
      # identifiers). Otherwise leave it alone — register_claude_pid on
      # the caller will UPDATE the stale PID row in place, preserving
      # the real session's data.
      private def cleanup_startup_orphan(claude_pid : Int64, resolved_session_id : Int64)
        # Check what session the PID currently points to.
        pid_session_id = Database.resolve_claude_pid(claude_pid)
        return unless pid_session_id
        return if pid_session_id == resolved_session_id

        # Guardrail: only touch sessions that look like OnStartup orphans.
        # Anything else is a legitimate session with a stale PID row.
        unless looks_like_fresh_orphan?(pid_session_id)
          STDERR.puts "[galaxy-ledger] on_resume: skipping orphan " \
                      "cleanup for session #{pid_session_id} " \
                      "(has accumulated data — likely stale PID " \
                      "recycled by the OS, not a fresh orphan)"
          return
        end

        # Candidate is a fresh OnStartup orphan. Save all mappings
        # before CASCADE delete wipes them, then re-register against
        # the resolved session.
        orphan_identifiers = Database.session_identifiers(pid_session_id)
        orphan_pids = Database.session_pids(pid_session_id)

        Database.delete_session(pid_session_id)

        orphan_identifiers.each do |sid|
          Database.register_session_identifier(resolved_session_id, sid) unless sid.empty?
        end
        orphan_pids.each do |pid|
          Database.register_claude_pid(resolved_session_id, pid) if pid > 0
        end
      end

      # A session qualifies as an OnStartup-created orphan only if it
      # was created moments ago and holds nothing beyond the PID +
      # identifier rows OnStartup itself registers. Any deviation
      # (entries, session files, age, extra PIDs/identifiers) means
      # the row belongs to a real session we must preserve.
      FRESH_ORPHAN_MAX_AGE_SECONDS = 300

      private def looks_like_fresh_orphan?(candidate_session_id : Int64) : Bool
        session = Database.get_session_by_id(candidate_session_id)
        return false unless session

        started_at = session.started_at
        return false unless started_at
        begin
          created = Time.parse(
            started_at,
            "%Y-%m-%d %H:%M:%S",
            Time::Location::UTC,
          )
          age = (Time.utc - created).total_seconds
          return false if age > FRESH_ORPHAN_MAX_AGE_SECONDS
        rescue
          return false
        end

        return false if Database.count_by_session(candidate_session_id) > 0
        return false unless Database.session_files(candidate_session_id).empty?
        return false if Database.session_pids(candidate_session_id).size > 1
        return false if Database.session_identifiers(candidate_session_id).size > 2

        true
      end

      private def build_resume_context(
        claude_pid : Int64,
        restoration : Database::RestorationResult,
        files : Array(Database::SessionFile),
        cwd : String? = nil,
        git_branch : String? = nil,
      ) : String
        lines = [] of String

        # Ledger awareness (same as on_startup)
        lines << "## Galaxy Ledger"
        lines << ""
        lines << "**Ledger PID**: `#{claude_pid}`"
        if cwd_val = cwd
          lines << "**Working directory**: `#{Helpers.shorten_home_path(cwd_val)}`" unless cwd_val.empty?
        end
        if branch = git_branch
          lines << "**Git branch**: `#{branch}`" unless branch.empty?
        end

        # CWD restore directive — tells Claude to cd on resume
        if cwd_val = cwd
          unless cwd_val.empty?
            lines << ""
            lines << "**REQUIRED**: If your current working directory"
            lines << "differs from the Working directory above, `cd`"
            lines << "to it before responding to the user."
          end
        end

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
        lines << "All of the above are captured automatically by hooks \u2014 no agent"
        lines << "action needed for any of these."
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
          g = files.count { |f| f.file_type == "guideline" }
          counts << "#{g} guideline#{g == 1 ? "" : "s"}" if g > 0
          p = files.count { |f| f.file_type == "implementation_plan" }
          counts << "#{p} plan#{p == 1 ? "" : "s"}" if p > 0
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
        lines << "1. **List session files**: `galaxy-ledger list-files --pid #{claude_pid}`"
        lines << "2. **Check code state**: `git diff` and `git log --oneline -20`"
        lines << "3. **Session recall**: invoke the `galaxy:recall` skill for"
        lines << "   tiered recipes \u2014 ledger FTS, paired turn dialogue,"
        lines << "   time-range windows, surrounding-context queries, keyword scans"
        lines << "4. **Normal exploration**: Grep, Glob, Read as usual"

        lines.join("\n")
      end

      private def compute_git_branch : String?
        output = IO::Memory.new
        status = Process.run(
          "git", ["rev-parse", "--abbrev-ref", "HEAD"],
          output: output,
          error: Process::Redirect::Close,
        )
        return nil unless status.success?
        branch = output.to_s.strip
        branch.empty? ? nil : branch
      rescue
        nil
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
