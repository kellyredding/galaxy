require "json"

module GalaxyLedger
  module Hooks
    # Handles the UserPromptSubmit hook
    # - Captures user message for potential direction extraction
    # - Persists initial message to session context in DB
    # - Spawns async extraction that writes directly to SQLite
    # - Async, non-blocking
    class OnUserPromptSubmit
      @session_identifier : String?
      @prompt : String?

      def run
        # Skip if GALAXY_SKIP_HOOKS is set (prevents recursion from extraction subprocesses)
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        # Parse hook input from stdin
        parse_hook_input

        session_identifier = @session_identifier
        prompt = @prompt
        return unless session_identifier && prompt

        # Skip empty or very short prompts
        return if prompt.strip.empty?
        return if prompt.strip.size < 10 # Skip "yes", "ok", "continue", etc.

        # Ensure session folder exists
        session_dir = GalaxyLedger.session_dir(session_identifier)
        Dir.mkdir_p(session_dir) unless Dir.exists?(session_dir)

        # Persist the initial message to session context (write_once so only the first prompt is stored)
        Database.merge_session_context(session_identifier, "initial_message", prompt, write_once: true)

        # Spawn async extraction for user directions
        # Extract actual directions/preferences/constraints and write to database
        spawn_extraction_async(session_identifier, prompt)
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
          @session_identifier = json["session_id"]?.try(&.as_s?)
          @prompt = json["prompt"]?.try(&.as_s?)
        rescue
          # Silently ignore parse errors
        end
      end
    end
  end
end
