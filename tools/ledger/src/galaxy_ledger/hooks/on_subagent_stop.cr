require "json"

module GalaxyLedger
  module Hooks
    # Dispatches SubagentStop hook to galaxy-agents CLI.
    #
    # Parses hook JSON from stdin, filters empty agent_type
    # (skills), resolves ledger_session_id, and shells out
    # to galaxy-agents stop with agent transcript path.
    # Pipes last_assistant_message via stdin using the
    # --last-message-stdin flag.
    #
    # Fire-and-forget: errors are silently ignored.
    class OnSubagentStop
      AGENTS_BIN = GalaxyLedger::AGENTS_BIN.to_s

      @stdin_session_id : String?
      @stdin_agent_id : String?
      @stdin_agent_type : String?
      @stdin_agent_transcript_path : String?
      @stdin_last_message : String?

      def run
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        parse_hook_input

        # Filter out skills (empty agent_type)
        agent_type = @stdin_agent_type
        return if agent_type.nil? || agent_type.empty?

        agent_id = @stdin_agent_id
        return unless agent_id

        # Resolve session
        claude_pid = Process.ppid.to_i64
        env_session_id =
          ENV[Resolver::ENV_SESSION_ID_KEY]?

        ledger_session_id = Resolver.resolve_session(
          claude_pid: claude_pid,
          env_session_id: env_session_id,
          stdin_session_id: @stdin_session_id,
        )
        return unless ledger_session_id

        # Build args
        args = [
          "stop",
          "--ledger-session-id",
          ledger_session_id.to_s,
          "--agent-id", agent_id,
        ]
        if tp = @stdin_agent_transcript_path
          args << "--agent-transcript-path"
          args << tp
        end

        # Pass last_message via stdin
        last_msg = @stdin_last_message
        input = if last_msg
                  args << "--last-message-stdin"
                  IO::Memory.new(last_msg)
                else
                  Process::Redirect::Close
                end

        Process.new(
          AGENTS_BIN,
          args: args,
          input: input,
          output: Process::Redirect::Close,
          error: Process::Redirect::Close,
        )
      rescue
        # Best-effort
      end

      private def parse_hook_input
        input = STDIN.gets_to_end
        return if input.empty?

        json = JSON.parse(input)
        @stdin_session_id =
          json["session_id"]?.try(&.as_s?)
        @stdin_agent_id =
          json["agent_id"]?.try(&.as_s?)
        @stdin_agent_type =
          json["agent_type"]?.try(&.as_s?)
        @stdin_agent_transcript_path =
          json["agent_transcript_path"]?
            .try(&.as_s?)
        @stdin_last_message =
          json["last_assistant_message"]?
            .try(&.as_s?)
      rescue
        # Silently ignore parse errors
      end
    end
  end
end
