require "json"

module GalaxyLedger
  module Hooks
    # Handles the SessionEnd hook — fires once when the session
    # actually exits (Ctrl+D, /exit, etc.). This is the inverse
    # of OnStartup and records a single session:ended timeline
    # event with final session metrics.
    #
    # Not to be confused with the Stop hook, which fires after
    # every assistant turn.
    #
    # Claude Code fires SessionEnd before SessionStart(clear),
    # so /clear triggers a spurious session:ended event. We
    # skip the timeline event when reason is "clear" because
    # the session continues — only the context was reset.
    class OnSessionEnd
      # Reasons that indicate a context reset, not a true
      # session exit. SessionEnd with these reasons is noise.
      CONTEXT_RESET_REASONS = ["clear"]

      @stdin_session_identifier : String?
      @stdin_cwd : String?
      @stdin_reason : String?

      def run
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        parse_hook_input

        # Skip timeline event for context resets — the
        # session continues, only the context was cleared.
        return if context_reset?

        claude_pid = Process.ppid.to_i64
        env_session_id = ENV[Resolver::ENV_SESSION_ID_KEY]?

        ledger_session_id = Resolver.resolve_session(
          claude_pid: claude_pid,
          env_session_id: env_session_id,
          stdin_session_id: @stdin_session_identifier,
        )
        return unless ledger_session_id

        # Close any orphaned turn before recording session end
        if sid = @stdin_session_identifier
          if TurnState.exists?(sid)
            TurnState.close_orphan(sid, ledger_session_id)
          end
        end

        # Abandon any still-running agents (best-effort)
        begin
          Process.new(
            AGENTS_BIN.to_s,
            args: [
              "abandon",
              "--ledger-session-id",
              ledger_session_id.to_s,
            ],
            input: Process::Redirect::Close,
            output: Process::Redirect::Close,
            error: Process::Redirect::Close,
          )
        rescue
          # Best-effort — galaxy-agents unavailable is
          # not fatal
        end

        session_record = Database.get_session_by_id(
          ledger_session_id,
        )
        return unless session_record

        # Record timeline event (fire-and-forget)
        begin
          Process.new(
            TIMELINE_BIN.to_s,
            args: [
              "record",
              "--ledger-session-id",
              ledger_session_id.to_s,
              "--event-type", "session:ended",
              "--source",
              "galaxy-ledger/hooks/on_session_end",
              "--duration-identifier",
              "ledger-session-id--#{ledger_session_id}",
              "--detail-data",
              {
                cwd:                @stdin_cwd,
                git_branch:         compute_git_branch,
                context_percentage: session_record
                  .context_percentage,
                tokens_used: session_record.tokens_used,
                tokens_max:  session_record.tokens_max,
                cost_usd:    session_record.cost_usd,
              }.to_json,
            ],
            input: Process::Redirect::Close,
            output: Process::Redirect::Close,
            error: Process::Redirect::Close,
          )
        rescue
          # Best-effort — timeline unavailable is not fatal
        end
      end

      private def context_reset? : Bool
        return false unless reason = @stdin_reason
        CONTEXT_RESET_REASONS.includes?(reason)
      end

      private def parse_hook_input
        begin
          input = STDIN.gets_to_end
          return if input.empty?

          json = JSON.parse(input)
          @stdin_session_identifier = json["session_id"]?
            .try(&.as_s?)
          @stdin_cwd = json["cwd"]?.try(&.as_s?)
          @stdin_reason = json["reason"]?.try(&.as_s?)
        rescue
          # Silently ignore parse errors
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
    end
  end
end
