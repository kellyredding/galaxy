require "json"
require "uuid"

module GalaxyLedger
  module Hooks
    # Handles the UserPromptSubmit hook — RESOLVE MODE
    # - Resolves session by Claude Code PID
    # - Captures user message for potential direction extraction
    # - Persists initial message to session context in DB
    # - Records turn:initiated timeline event and writes turn state file
    # - Spawns async extraction that writes directly to SQLite
    # - Async, non-blocking
    class OnUserPromptSubmit
      @stdin_session_identifier : String?
      @prompt : String?

      def run
        # Skip if GALAXY_SKIP_HOOKS is set (prevents recursion from extraction subprocesses)
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        # Parse hook input from stdin
        parse_hook_input

        prompt = @prompt
        return unless prompt

        # Skip empty or very short prompts
        return if prompt.strip.empty?
        return if prompt.strip.size < 10 # Skip "yes", "ok", "continue", etc.

        # Resolve session via 3-tier chain (PID → env var → hook session_id).
        # No creation — bail if nothing resolves.
        claude_pid = Process.ppid.to_i64
        env_session_id = ENV[Resolver::ENV_SESSION_ID_KEY]?

        ledger_session_id = Resolver.resolve_session(
          claude_pid: claude_pid,
          env_session_id: env_session_id,
          stdin_session_id: @stdin_session_identifier,
        )
        return unless ledger_session_id

        # Get current session_identifier for extraction subprocess --session flag
        session_record = Database.get_session_by_id(ledger_session_id)
        current_sid = session_record.try(&.current_session_identifier) || @stdin_session_identifier
        return unless current_sid

        # Record turn:initiated event and write state file.
        # Only for the main session (not extraction sub-sessions)
        # and not for task-notification injections.
        record_turn_initiated(ledger_session_id, current_sid, prompt)

        # Persist the initial message to session context (write_once so only the first prompt is stored)
        Database.merge_session_context(ledger_session_id, "initial_message", prompt, write_once: true)

        # Spawn async extraction for user directions
        # Extract actual directions/preferences/constraints and write to database
        # NOTE: extraction subprocesses use --session (not --pid) because their
        # PPID is the hook process, not Claude Code.
        spawn_extraction_async(current_sid, prompt)
      end

      private def record_turn_initiated(
        ledger_session_id : Int64,
        current_sid : String,
        prompt : String,
      )
        stdin_sid = @stdin_session_identifier
        return unless stdin_sid

        # Filter: session_id must match the ledger's current
        # session identifier (skip extraction sub-sessions)
        return unless stdin_sid == current_sid

        # Filter: skip task-notification injections from
        # background agent completions
        return if prompt.starts_with?("<task-notification>")

        # Generate UUID for duration pairing
        uuid = UUID.random.to_s

        # Record turn:initiated timeline event (fire-and-forget)
        detail_data = {"user_message" => prompt}.to_json
        begin
          Process.new(
            TIMELINE_BIN_NAME,
            args: [
              "record",
              "--ledger-session-id",
              ledger_session_id.to_s,
              "--event-type", "turn:initiated",
              "--source", "galaxy-ledger",
              "--duration-identifier", "turn--#{uuid}",
              "--detail-data-stdin",
            ],
            input: IO::Memory.new(detail_data),
            output: Process::Redirect::Close,
            error: Process::Redirect::Close,
          )
        rescue
          # Best-effort — timeline unavailable is not fatal
        end

        # Write turn state file for Stop hook to consume
        TurnState.write(stdin_sid, uuid, prompt)
      rescue
        # Best-effort — turn tracking failure is not fatal
      end

      private def spawn_extraction_async(session_identifier : String, prompt : String)
        begin
          binary = Process.executable_path || "galaxy-ledger"

          # Pass the prompt via stdin
          Process.new(
            binary,
            args: ["extract-user", "--session", session_identifier],
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
          @stdin_session_identifier = json["session_id"]?.try(&.as_s?)
          @prompt = json["prompt"]?.try(&.as_s?)
        rescue
          # Silently ignore parse errors
        end
      end
    end
  end
end
