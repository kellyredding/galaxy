require "json"

module GalaxyLedger
  module Hooks
    # Answers Claude Code's PermissionRequest with "allow", for the driven
    # sessions Galaxy launches with this hook in their inline settings. Those
    # sessions run with nobody at the keyboard, so a prompt would stall them.
    #
    # The request's tool input is echoed back as `updatedInput` when present:
    # the hooks reference requires it for AskUserQuestion and ExitPlanMode, and
    # handing back the unchanged input is a no-op for every other tool.
    class AllowPermission
      def run(input : IO = STDIN, output : IO = STDOUT)
        output.puts(self.class.decision(input.gets_to_end))
      end

      def self.decision(stdin : String) : String
        decision = {} of String => JSON::Any
        decision["behavior"] = JSON::Any.new("allow")
        if tool_input = tool_input(stdin)
          decision["updatedInput"] = tool_input
        end

        {
          "hookSpecificOutput" => {
            "hookEventName" => "PermissionRequest",
            "decision"      => decision,
          },
        }.to_json
      end

      private def self.tool_input(stdin : String) : JSON::Any?
        return nil if stdin.strip.empty?
        value = JSON.parse(stdin)["tool_input"]?
        value if value.try(&.as_h?)
      rescue JSON::ParseException
        nil
      end
    end
  end
end
