require "json"

module GalaxyLedger
  module Hooks
    # Dispatches SubagentStart hook to galaxy-agents CLI.
    #
    # Parses hook JSON from stdin, filters empty agent_type
    # (skills), resolves ledger_session_id, and shells out
    # to galaxy-agents start with parent transcript path
    # for .meta.json description extraction.
    #
    # Fire-and-forget: errors are silently ignored.
    class OnSubagentStart
      AGENTS_BIN = GalaxyLedger::AGENTS_BIN_NAME

      @stdin_session_id : String?
      @stdin_agent_id : String?
      @stdin_agent_type : String?
      @stdin_transcript_path : String?

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
          "start",
          "--ledger-session-id",
          ledger_session_id.to_s,
          "--agent-id", agent_id,
          "--agent-type", agent_type,
        ]
        if tp = @stdin_transcript_path
          args << "--parent-transcript-path"
          args << tp
        end

        # Shell out to galaxy-agents start
        Process.new(
          AGENTS_BIN,
          args: args,
          input: Process::Redirect::Close,
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
        @stdin_transcript_path =
          json["transcript_path"]?.try(&.as_s?)
      rescue
        # Silently ignore parse errors
      end
    end
  end
end
