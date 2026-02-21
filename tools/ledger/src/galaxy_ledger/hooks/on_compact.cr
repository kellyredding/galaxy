require "json"

module GalaxyLedger
  module Hooks
    # Handles the SessionStart(compact) hook.
    #
    # Thin wrapper that parses hook input and delegates to
    # ContextHandoff for shared context restoration logic.
    # Identical to OnClear for now, but the separate class allows
    # future divergence (e.g. compact-specific context trimming).
    class OnCompact
      @stdin_session_identifier : String?
      @source : String?

      def run
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        parse_hook_input
        ContextHandoff.run(@stdin_session_identifier, @source, event_name: "session.compact")
      end

      private def parse_hook_input
        begin
          input = STDIN.gets_to_end
          return if input.empty?

          json = JSON.parse(input)
          @stdin_session_identifier = json["session_id"]?.try(&.as_s?)
          @source = json["source"]?.try(&.as_s?)
        rescue
          # Silently ignore parse errors
        end
      end
    end
  end
end
