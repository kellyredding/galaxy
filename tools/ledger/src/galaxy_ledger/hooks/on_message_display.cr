require "json"
require "uuid"

module GalaxyLedger
  module Hooks
    # Opens a turn when the agent is speaking and nothing is tracked.
    #
    # ### Why this exists
    #
    # A message submitted while a turn is running is queued by Claude
    # Code, which fires UserPromptSubmit at once and never again when it
    # dequeues. That submission is set aside rather than recorded, so
    # the turn it eventually becomes has no start — and `Stop` does not
    # fire on an interrupt, so nothing later reclaims it either. Both
    # were measured. This is the only signal left on that path.
    #
    # ### What it reads
    #
    # `session_id`, and nothing else. The payload also carries
    # `turn_id`, `prompt_id`, `index` and `final` — all real, none
    # documented. Depending on them would tie turn tracking to a surface
    # that can change without notice. If this event ever stops arriving,
    # turns simply go untracked again, which is where they are without
    # it: the failure is a return to the old behaviour, not a new one.
    #
    # ### Cost
    #
    # Claude Code fires this several times per assistant message and
    # offers no matcher to narrow it, so the common path must stay a
    # file check and an exit. Real work happens only when no turn is
    # open, which after an ordinary UserPromptSubmit never happens.
    class OnMessageDisplay
      @stdin_session_identifier : String?

      def run
        # Skip if GALAXY_SKIP_HOOKS is set (prevents recursion from
        # extraction subprocesses)
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        parse_hook_input

        stdin_sid = @stdin_session_identifier
        return unless stdin_sid
        return if stdin_sid.empty?

        # The fast path, and the overwhelmingly common one: a turn is
        # already tracked, so there is nothing to do and no reason to
        # open the database.
        return if TurnState.exists?(stdin_sid)

        # Stop has just ended the turn and left nothing waiting, so what is
        # being displayed is the hook's own message, not the agent starting
        # another. A prompt Stop set aside but could not open is different:
        # its turn is what comes next, and this is what opens it.
        return if TurnState.closed_by_stop?(stdin_sid) &&
                  !TurnState.pending?(stdin_sid)

        claude_pid = Process.ppid.to_i64
        env_session_id = ENV[Resolver::ENV_SESSION_ID_KEY]?

        ledger_session_id = Resolver.resolve_session(
          claude_pid: claude_pid,
          env_session_id: env_session_id,
          stdin_session_id: stdin_sid,
        )
        return unless ledger_session_id
        return unless ledger_session_id > 0

        # The prompt that was set aside when it arrived mid-turn, if
        # this is that message being picked up. Empty when the agent is
        # speaking for some other reason — a turn with no text is still
        # better than a turn nobody can see.
        prompt = TurnState.take_pending(stdin_sid) || ""

        uuid = UUID.random.to_s
        record_turn_initiated(ledger_session_id, uuid, prompt)
        TurnState.write(stdin_sid, uuid, prompt)
      rescue
        # Best-effort — a missing turn start is not worth a failed hook
      end

      private def parse_hook_input
        # Hook receives JSON via stdin:
        # {
        #   "session_id": "abc123",
        #   "hook_event_name": "MessageDisplay",
        #   ...
        # }
        input = STDIN.gets_to_end
        return if input.empty?

        json = JSON.parse(input)
        @stdin_session_identifier = json["session_id"]?.try(&.as_s?)
      rescue
        # Silently ignore parse errors
      end

      private def record_turn_initiated(
        ledger_session_id : Int64,
        uuid : String,
        prompt : String,
      )
        detail_data = {
          "user_message" => prompt,
        }.to_json

        Process.new(
          TIMELINE_BIN.to_s,
          args: [
            "record",
            "--ledger-session-id",
            ledger_session_id.to_s,
            "--event-type", "turn:initiated",
            "--source", "galaxy-ledger/message-display",
            "--duration-identifier",
            "turn--#{uuid}",
            "--detail-data-stdin",
          ],
          input: IO::Memory.new(detail_data),
          output: Process::Redirect::Close,
          error: Process::Redirect::Close,
        )
      rescue
        # Best-effort — timeline unavailable is not fatal
      end
    end
  end
end
