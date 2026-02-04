require "json"

module GalaxyLedger
  module Hooks
    # Handles the UserPromptSubmit hook
    # - Captures user message for potential direction extraction
    # - Buffers for later processing by Claude CLI (Phase 6)
    # - Async, non-blocking
    class OnUserPromptSubmit
      @session_id : String?
      @prompt : String?

      def run
        # Skip if GALAXY_SKIP_HOOKS is set (prevents recursion from extraction subprocesses)
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        # Parse hook input from stdin
        parse_hook_input

        session_id = @session_id
        prompt = @prompt
        return unless session_id && prompt

        # Skip empty or very short prompts
        return if prompt.strip.empty?
        return if prompt.strip.size < 10 # Skip "yes", "ok", "continue", etc.

        # Ensure session folder exists
        session_dir = GalaxyLedger.session_dir(session_id)
        Dir.mkdir_p(session_dir) unless Dir.exists?(session_dir)

        # Phase 6: Spawn async extraction for user directions
        # Instead of buffering raw prompts, we extract actual directions/preferences/constraints
        spawn_extraction_async(session_id, prompt)
      end

      private def spawn_extraction_async(session_id : String, prompt : String)
        begin
          binary = Process.executable_path || "galaxy-ledger"

          # Pass the prompt via stdin
          Process.new(
            binary,
            args: ["extract-user", "--session", session_id],
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
          @session_id = json["session_id"]?.try(&.as_s?)
          @prompt = json["prompt"]?.try(&.as_s?)
        rescue
          # Silently ignore parse errors
        end
      end
    end
  end
end
