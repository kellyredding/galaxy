require "json"

module GalaxyLedger
  module Hooks
    # Handles the SessionStart(clear) hook.
    #
    # Thin wrapper that parses hook input and delegates to
    # ContextHandoff for shared context restoration logic.
    class OnClear
      @stdin_session_identifier : String?
      @source : String?
      @transcript_path : String?

      def run
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        parse_hook_input

        # Close any orphaned turn from this session
        # (e.g. context limit hit before Stop could fire)
        if sid = @stdin_session_identifier
          if TurnState.exists?(sid)
            lsid = resolve_session_for_timeline
            TurnState.close_orphan(sid, lsid) if lsid > 0
          end
        end

        # Record timeline event synchronously (basic data).
        # Must fire before ContextHandoff.run which calls exit.
        timeline_event_id = record_timeline_event(
          event_type: "context:cleared",
        )

        ledger_session_id = ContextHandoff.run(
          @stdin_session_identifier,
          @source,
          transcript_path: @transcript_path,
          timeline_event_id: timeline_event_id,
        )

        # Signal Galaxy.app that the clear hook has finished and
        # the new prompt is imminent. Galaxy listens for this
        # event in EventCoordinator and uses it as the readiness
        # gate before sending /handoff via clearAndHandoff.
        # Errors are silently rescued by EventPublisher; the
        # hook behaves identically whether or not Galaxy is
        # listening.
        if lsid = ledger_session_id
          EventPublisher.publish(
            ledger_session_id: lsid,
            event: "session:ready",
            ref: "clear",
          )
        end
      end

      private def parse_hook_input
        begin
          input = STDIN.gets_to_end
          return if input.empty?

          json = JSON.parse(input)
          @stdin_session_identifier = json["session_id"]?.try(&.as_s?)
          @source = json["source"]?.try(&.as_s?)
          @transcript_path = json["transcript_path"]?.try(&.as_s?)
        rescue
          # Silently ignore parse errors
        end
      end

      private def record_timeline_event(
        event_type : String,
      ) : Int64?
        ledger_session_id = resolve_session_for_timeline
        return nil if ledger_session_id == 0_i64

        output = IO::Memory.new
        status = Process.run(
          TIMELINE_BIN.to_s,
          args: [
            "record", "--json",
            "--ledger-session-id",
            ledger_session_id.to_s,
            "--event-type", event_type,
            "--source",
            "galaxy-ledger/hooks/on_clear",
            "--detail-data",
            {
              source:     @source,
              cwd:        Dir.current,
              git_branch: compute_git_branch,
            }.to_json,
          ],
          output: output,
          error: Process::Redirect::Close,
        )
        return nil unless status.success?

        json = JSON.parse(output.to_s)
        json["id"].as_i64
      rescue
        nil
      end

      private def resolve_session_for_timeline : Int64
        claude_pid = Process.ppid.to_i64
        env_session_id = ENV[
          GalaxyLedger::Hooks::Resolver::ENV_SESSION_ID_KEY,
        ]?

        GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: claude_pid,
          env_session_id: env_session_id,
          stdin_session_id: @stdin_session_identifier,
        ) || 0_i64
      end

      private def compute_git_branch : String?
        output = IO::Memory.new
        status = Process.run(
          "git", ["rev-parse", "--abbrev-ref", "HEAD"],
          output: output,
          error: Process::Redirect::Close,
        )
        return nil unless status.success?
        branch = output.to_s.strip
        branch.empty? ? nil : branch
      rescue
        nil
      end
    end
  end
end
