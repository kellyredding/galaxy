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
          event_type: "context:compacted",
        )

        ContextHandoff.run(
          @stdin_session_identifier,
          @source,
          event_name: "session.compact",
          transcript_path: @transcript_path,
          timeline_event_id: timeline_event_id,
        )
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
          "galaxy-timeline",
          args: [
            "record", "--json",
            "--ledger-session-id",
            ledger_session_id.to_s,
            "--event-type", event_type,
            "--source",
            "galaxy-ledger/hooks/on_compact",
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
