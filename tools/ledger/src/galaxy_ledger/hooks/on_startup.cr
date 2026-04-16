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
        current_cwd = Dir.current
        current_git_branch = compute_git_branch

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
            cwd: current_cwd,
            git_branch: current_git_branch,
          )

          return if ledger_session_id <= 0

          # Register env var mapping if available.
          # create_session already registers session_id + PID internally.
          if env_id = env_session_id
            unless env_id.empty?
              Database.register_session_identifier(ledger_session_id, env_id)
            end
          end

          # Delegate all backup orchestration to the Galaxy CLI.
          begin
            Process.run(
              GALAXY_BIN.to_s,
              ["backups", "create", "--session-id", ledger_session_id.to_s],
              output: Process::Redirect::Close,
              error: Process::Redirect::Pipe,
            ) do |proc|
              stderr = proc.error.gets_to_end
              unless proc.wait.success?
                STDERR.puts "[galaxy-ledger] Backup failed: #{stderr.strip}"
              end
            end
          rescue ex
            STDERR.puts "[galaxy-ledger] Backup error: #{ex.message}"
          end
        end

        # Record timeline event (fire-and-forget).
        # The timeline tool persists the event and publishes
        # timeline.session:started to the Galaxy socket.
        begin
          Process.new(
            TIMELINE_BIN.to_s,
            args: [
              "record",
              "--ledger-session-id",
              ledger_session_id.to_s,
              "--event-type", "session:started",
              "--source",
              "galaxy-ledger/hooks/on_startup",
              "--duration-identifier",
              "ledger-session-id--#{ledger_session_id}",
              "--detail-data",
              {
                cwd:                current_cwd,
                git_branch:         current_git_branch,
                session_identifier: session_id,
                env_session_id:     env_session_id,
              }.to_json,
            ],
            input: Process::Redirect::Close,
            output: Process::Redirect::Close,
            error: Process::Redirect::Close,
          )
        rescue
          # Best-effort — timeline unavailable is not fatal
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
        context = build_awareness_context(claude_pid, current_cwd, current_git_branch)

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

      private def build_awareness_context(
        claude_pid : Int64,
        cwd : String? = nil,
        git_branch : String? = nil,
      ) : String
        lines = [] of String
        lines << "## Galaxy Ledger"
        lines << ""
        lines << "**Ledger PID**: `#{claude_pid}`"
        if cwd_val = cwd
          lines << "**Working directory**: `#{Helpers.shorten_home_path(cwd_val)}`" unless cwd_val.empty?
        end
        if branch = git_branch
          lines << "**Git branch**: `#{branch}`" unless branch.empty?
        end
        lines << ""

        lines << "A persistent context ledger is active for this session. It"
        lines << "automatically captures the following as you work:"
        lines << ""
        lines << "- **Guidelines**: Guideline files tracked by file type when read"
        lines << "- **Implementation plans**: Plan files tracked by file type when read"
        lines << "- **Decisions**: Key choices and their rationale (extracted at session"
        lines << "  end)"
        lines << "- **Learnings**: Insights and discoveries (extracted at session end)"
        lines << "- **Session files**: Every file read, edited, written, or searched"
        lines << ""
        lines << "All of the above are captured automatically by hooks \u2014 no agent"
        lines << "action needed for any of these."
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
        lines << ""
        lines << "### Artifact Awareness"
        lines << ""
        lines << "The Ledger automatically captures document artifacts (reports,"
        lines << "data exports, diagrams, images, etc.) when you create them via"
        lines << "the Write tool \u2014 no action needed for those."
        lines << ""
        lines << "**When you create artifacts via Bash** (e.g., pandoc, mermaid-cli,"
        lines << "python scripts generating files, curl downloads of documents),"
        lines << "register them silently:"
        lines << ""
        lines << "    galaxy-artifacts save --pid #{claude_pid} \\\\"
        lines << "      --title \"Descriptive title\" \\\\"
        lines << "      --source-path /path/to/created/file \\\\"
        lines << "      --description \"Brief context about what this contains\""
        lines << ""
        lines << "Do this automatically after Bash commands that produce document"
        lines << "files. Do not mention artifact capture to the user unless they"
        lines << "ask about artifacts."

        lines.join("\n")
      end
    end
  end
end
