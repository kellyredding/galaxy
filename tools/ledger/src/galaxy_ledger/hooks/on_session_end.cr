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
    class OnSessionEnd
      @stdin_session_identifier : String?
      @stdin_cwd : String?

      def run
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        parse_hook_input

        claude_pid = Process.ppid.to_i64
        env_session_id = ENV[Resolver::ENV_SESSION_ID_KEY]?

        ledger_session_id = Resolver.resolve_session(
          claude_pid: claude_pid,
          env_session_id: env_session_id,
          stdin_session_id: @stdin_session_identifier,
        )
        return unless ledger_session_id

        session_record = Database.get_session_by_id(
          ledger_session_id,
        )
        return unless session_record

        # Record timeline event (fire-and-forget)
        begin
          Process.new(
            "galaxy-timeline",
            args: [
              "record",
              "--ledger-session-id",
              ledger_session_id.to_s,
              "--event-type", "session:ended",
              "--source",
              "galaxy-ledger/hooks/on_session_end",
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

      private def parse_hook_input
        begin
          input = STDIN.gets_to_end
          return if input.empty?

          json = JSON.parse(input)
          @stdin_session_identifier = json["session_id"]?
            .try(&.as_s?)
          @stdin_cwd = json["cwd"]?.try(&.as_s?)
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
