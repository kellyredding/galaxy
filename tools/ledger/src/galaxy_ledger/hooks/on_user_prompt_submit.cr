require "json"
require "uuid"

module GalaxyLedger
  module Hooks
    # Handles the UserPromptSubmit hook — RESOLVE MODE
    # - Resolves session by Claude Code PID
    # - Publishes socket-only turn:initiated for task
    #   notifications (no timeline record, no TurnState)
    # - Records turn:initiated timeline event and writes
    #   TurnState for ALL user prompts (including short)
    # - Persists initial message and spawns extraction
    #   only for prompts >= 10 chars
    # - Async, non-blocking
    class OnUserPromptSubmit
      @stdin_session_identifier : String?
      @prompt : String?

      def run
        # Skip if GALAXY_SKIP_HOOKS is set (prevents
        # recursion from extraction subprocesses)
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        # Parse hook input from stdin
        parse_hook_input

        prompt = @prompt
        return unless prompt
        return if prompt.strip.empty?

        # Resolve session (needed for all paths).
        # No creation — bail if nothing resolves.
        claude_pid = Process.ppid.to_i64
        env_session_id = ENV[Resolver::ENV_SESSION_ID_KEY]?

        ledger_session_id = Resolver.resolve_session(
          claude_pid: claude_pid,
          env_session_id: env_session_id,
          stdin_session_id: @stdin_session_identifier,
        )
        return unless ledger_session_id

        # Task notifications: socket-only turn:initiated
        # for Galaxy real-time UI. No timeline record, no
        # TurnState file (on_stop records turn:continued).
        if prompt.starts_with?("<task-notification>")
          EventPublisher.publish(
            ledger_session_id: ledger_session_id,
            event: "timeline.turn:initiated",
          )
          return
        end

        # Get current session_identifier for extraction
        # subprocess --session flag
        session_record = Database.get_session_by_id(
          ledger_session_id,
        )
        current_sid = session_record
          .try(&.current_session_identifier) ||
                      @stdin_session_identifier
        return unless current_sid

        # Record turn:initiated timeline event and write
        # TurnState file for ALL user prompts (no size
        # filter). The timeline record also publishes to
        # the socket as timeline.turn:initiated.
        record_turn_initiated(
          ledger_session_id, current_sid, prompt,
        )

        # Short prompts: skip extraction + persistence.
        # Turn tracking above still runs — Galaxy needs
        # the turn:initiated signal for short answers
        # like "yes", "ok", "continue".
        return if prompt.strip.size < 10

        # Persist the initial message to session context
        # (write_once so only the first prompt is stored)
        Database.merge_session_context(
          ledger_session_id,
          "initial_message",
          prompt,
          write_once: true,
        )

        # Spawn async extraction for user directions.
        # NOTE: extraction subprocesses use --session
        # (not --pid) because their PPID is the hook
        # process, not Claude Code.
        spawn_extraction_async(current_sid, prompt)
      end

      private def record_turn_initiated(
        ledger_session_id : Int64,
        current_sid : String,
        prompt : String,
      )
        stdin_sid = @stdin_session_identifier
        return unless stdin_sid

        # Filter: session_id must match the ledger's
        # current session identifier (skip extraction
        # sub-sessions)
        return unless stdin_sid == current_sid

        # Skip if a turn is already in progress.
        # Follow-up messages typed while Claude is
        # working are part of the existing turn — they
        # should not create new turn:initiated events
        # or overwrite the TurnState file (which would
        # orphan the original turn:initiated).
        return if TurnState.exists?(stdin_sid)

        # Generate UUID for duration pairing
        uuid = UUID.random.to_s

        # Record turn:initiated timeline event
        # (fire-and-forget)
        detail_data = {
          "user_message" => prompt,
        }.to_json
        begin
          Process.new(
            TIMELINE_BIN.to_s,
            args: [
              "record",
              "--ledger-session-id",
              ledger_session_id.to_s,
              "--event-type", "turn:initiated",
              "--source", "galaxy-ledger",
              "--duration-identifier",
              "turn--#{uuid}",
              "--detail-data-stdin",
            ],
            input: IO::Memory.new(detail_data),
            output: Process::Redirect::Close,
            error: Process::Redirect::Close,
          )
        rescue
          # Best-effort — timeline unavailable is not
          # fatal
        end

        # Write turn state file for Stop hook to consume
        TurnState.write(stdin_sid, uuid, prompt)
      rescue
        # Best-effort — turn tracking failure is not
        # fatal
      end

      private def spawn_extraction_async(
        session_identifier : String,
        prompt : String,
      )
        begin
          binary = Process.executable_path ||
                   "galaxy-ledger"

          # Pass the prompt via stdin
          Process.new(
            binary,
            args: [
              "extract-user",
              "--session",
              session_identifier,
            ],
            input: IO::Memory.new(prompt),
            output: Process::Redirect::Close,
            error: Process::Redirect::Close,
          )
        rescue
          # Silently fail - extraction is best-effort
        end
      end

      private def parse_hook_input
        # Hook receives JSON via stdin:
        # {
        #   "session_id": "abc123",
        #   "prompt": "User's message content",
        #   ...
        # }
        begin
          input = STDIN.gets_to_end
          return if input.empty?

          json = JSON.parse(input)
          @stdin_session_identifier =
            json["session_id"]?.try(&.as_s?)
          @prompt = json["prompt"]?.try(&.as_s?)
        rescue
          # Silently ignore parse errors
        end
      end
    end
  end
end
