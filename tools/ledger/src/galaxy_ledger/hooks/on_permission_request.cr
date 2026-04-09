require "json"

module GalaxyLedger
  module Hooks
    # Handles the PermissionRequest hook.
    # Resolves the session and publishes a permission_request
    # event to Galaxy.app via the Unix domain socket.
    class OnPermissionRequest
      @stdin_session_identifier : String?

      def run
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        parse_hook_input

        claude_pid = Process.ppid.to_i64
        env_session_id =
          ENV[Resolver::ENV_SESSION_ID_KEY]?

        ledger_session_id = Resolver.resolve_session(
          claude_pid: claude_pid,
          env_session_id: env_session_id,
          stdin_session_id: @stdin_session_identifier,
        )
        return unless ledger_session_id

        EventPublisher.publish(
          ledger_session_id: ledger_session_id,
          event: "permission_request",
        )
      rescue
        # Best-effort
      end

      private def parse_hook_input
        input = STDIN.gets_to_end
        return if input.empty?

        json = JSON.parse(input)
        @stdin_session_identifier =
          json["session_id"]?.try(&.as_s?)
      rescue
        # Silently ignore parse errors
      end
    end
  end
end
