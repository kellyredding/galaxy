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

        # Buffer the user prompt for potential direction extraction
        # Actual extraction via Claude CLI happens in Phase 6
        # For now, we just record that a user prompt was submitted
        # This allows Phase 6 to process accumulated prompts
        entry = Buffer::Entry.new(
          entry_type: "direction",  # Will be classified properly in Phase 6
          content: prompt,
          importance: "medium",
          source: "user",
          metadata: JSON.parse({"raw_prompt" => true}.to_json)
        )

        Buffer.append(session_id, entry)
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
