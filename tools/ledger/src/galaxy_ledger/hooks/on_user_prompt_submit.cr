require "json"

module GalaxyLedger
  module Hooks
    # Handles the UserPromptSubmit hook — RESOLVE MODE
    # - Resolves session by Claude Code PID
    # - Captures user message for potential direction extraction
    # - Persists initial message to session context in DB
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

        # Persist the initial message to session context (write_once so only the first prompt is stored)
        Database.merge_session_context(ledger_session_id, "initial_message", prompt, write_once: true)

        # Spawn async extraction for user directions
        # Extract actual directions/preferences/constraints and write to database
        # NOTE: extraction subprocesses use --session (not --pid) because their
        # PPID is the hook process, not Claude Code.
        spawn_extraction_async(current_sid, prompt)
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
