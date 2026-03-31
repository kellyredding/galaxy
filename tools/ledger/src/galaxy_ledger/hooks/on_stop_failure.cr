require "json"

module GalaxyLedger
  module Hooks
    # Handles the StopFailure hook — fires when the agent
    # response fails (API error, rate limit, etc.).
    #
    # Minimal hook — only consumes the turn state file and
    # records a turn:failed timeline event. No extraction,
    # no context indicator.
    class OnStopFailure
      @stdin_session_identifier : String?
      @transcript_path : String?
      @last_assistant_message : String?

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
        current_sid = session_record
          .try(&.current_session_identifier) ||
                      @stdin_session_identifier
        return unless current_sid

        record_turn_failed(ledger_session_id, current_sid)
      end

      private def record_turn_failed(
        ledger_session_id : Int64,
        current_sid : String,
      )
        stdin_sid = @stdin_session_identifier
        return unless stdin_sid

        # Filter: session_id must match the ledger's current
        # session identifier (skip extraction sub-sessions)
        return unless stdin_sid == current_sid

        state = TurnState.read(stdin_sid)
        return unless state

        # Scan transcript for mid-turn follow-up messages.
        follow_ups = [] of TranscriptScanner::FollowUpMessage
        if tp = @transcript_path
          follow_ups = TranscriptScanner.follow_up_messages(
            tp,
            state.initiated_at,
            stdin_sid,
          )
        end

        detail_data = JSON.build do |json|
          json.object do
            json.field "user_message", state.user_message
            json.field "follow_up_messages" do
              json.array do
                follow_ups.each(&.to_json(json))
              end
            end
            json.field "error", true
          end
        end

        begin
          Process.new(
            "galaxy-timeline",
            args: [
              "record",
              "--ledger-session-id",
              ledger_session_id.to_s,
              "--event-type", "turn:failed",
              "--source", "galaxy-ledger",
              "--duration-identifier",
              "turn--#{state.uuid}",
              "--detail-data-stdin",
            ],
            input: IO::Memory.new(detail_data),
            output: Process::Redirect::Close,
            error: Process::Redirect::Close,
          )
        rescue
          # Best-effort
        end

        TurnState.delete(stdin_sid)
      rescue
        # Turn tracking failure is not fatal
      end

      private def parse_hook_input
        begin
          input = STDIN.gets_to_end
          return if input.empty?

          json = JSON.parse(input)
          @stdin_session_identifier = json["session_id"]?
            .try(&.as_s?)
          @transcript_path = json["transcript_path"]?
            .try(&.as_s?)
          @last_assistant_message =
            json["last_assistant_message"]?.try(&.as_s?)
        rescue
          # Silently ignore parse errors
        end
      end
    end
  end
end
