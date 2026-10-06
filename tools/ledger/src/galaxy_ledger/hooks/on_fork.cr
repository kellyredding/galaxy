require "json"

module GalaxyLedger
  module Hooks
    # Handles the SessionStart(fork) hook.
    #
    # Claude Code moves a conversation to a background worker by forking it
    # under a new session id in a new process. When the fork replaced its
    # parent, the ledger session follows it: the fork's id and pid become
    # current, as on resume. A fork that left its parent running is not
    # adopted — the current id is what every per-turn hook checks, so taking
    # it would silence the parent.
    class OnFork
      # The parent's transcript gained its continued-in record 1.5 s before
      # this hook ran, the one time it was measured.
      HANDOFF_WAIT_MS = 5_000
      HANDOFF_POLL    = 250.milliseconds
      SYSTEM_MESSAGE  = "Forked │ Ledger tracking follows the background session"

      @stdin_session_identifier : String?
      @transcript_path : String?

      def run
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        parse_hook_input
        sid = @stdin_session_identifier
        transcript = @transcript_path
        return output_empty unless sid && !sid.empty? && transcript

        ledger_session_id = resolve_parent(sid, transcript)
        return output_empty unless ledger_session_id && ledger_session_id > 0

        previous_sid = Database.get_session_by_id(ledger_session_id)
          .try(&.current_session_identifier)
        return output_empty unless previous_sid
        return puts(Helpers.output_json(SYSTEM_MESSAGE, "")) if previous_sid == sid

        unless handed_off?(transcript, previous_sid, sid)
          STDERR.puts "[galaxy-ledger] on_fork: #{sid} forked from session " \
                      "#{ledger_session_id} without replacing " \
                      "#{previous_sid}; not adopted"
          return output_empty
        end

        Database.update_session(
          ledger_session_id,
          session_identifier: sid,
          claude_pid: Process.ppid.to_i64,
        )
        record_timeline_event(ledger_session_id, previous_sid, sid)

        puts Helpers.output_json(SYSTEM_MESSAGE, "")

        # The parent's turn state is stranded under an id the session has
        # moved on from; the sweep closes it as abandoned.
        TurnState.sweep_orphans
      end

      private def parse_hook_input
        input = STDIN.gets_to_end
        return if input.empty?

        json = JSON.parse(input)
        @stdin_session_identifier = json["session_id"]?.try(&.as_s?)
        @transcript_path = json["transcript_path"]?.try(&.as_s?)
      rescue
        # Silently ignore parse errors
      end

      # Env var, then the fork transcript's record of its parent. Never the
      # pid: the worker is a process the ledger has not seen.
      private def resolve_parent(sid : String, transcript : String) : Int64?
        if env_id = ENV[Resolver::ENV_SESSION_ID_KEY]?
          unless env_id.empty?
            lid = Database.resolve_session_identifier(env_id)
            return lid if lid
          end
        end

        if parent = TranscriptScanner.forked_from(transcript, sid)
          return Database.resolve_session_identifier(parent)
        end

        nil
      end

      # The parent transcript sits beside the fork's: Claude Code launches
      # the fork in the parent's original working directory.
      private def handed_off?(
        transcript : String,
        previous_sid : String,
        sid : String,
      ) : Bool
        parent = (Path[transcript].parent / "#{previous_sid}.jsonl").to_s
        deadline = Time.monotonic + handoff_wait

        loop do
          return true if TranscriptScanner.continued_in(parent) == sid
          return false if Time.monotonic >= deadline
          sleep HANDOFF_POLL
        end
      end

      # Overridable so specs of the not-adopted path need not wait it out.
      private def handoff_wait : Time::Span
        ms = ENV["GALAXY_FORK_HANDOFF_WAIT_MS"]?.try(&.to_i?) || HANDOFF_WAIT_MS
        ms.milliseconds
      end

      private def record_timeline_event(
        ledger_session_id : Int64,
        from : String,
        to : String,
      )
        Process.new(
          TIMELINE_BIN.to_s,
          args: [
            "record",
            "--ledger-session-id",
            ledger_session_id.to_s,
            "--event-type", "session:forked",
            "--source", "galaxy-ledger/hooks/on_fork",
            "--detail-data",
            {from: from, to: to, cwd: Dir.current}.to_json,
          ],
          input: Process::Redirect::Close,
          output: Process::Redirect::Close,
          error: Process::Redirect::Close,
        )
      rescue
        # Best-effort — timeline unavailable is not fatal
      end

      private def output_empty
        puts Helpers.output_json("Forked", "")
      end
    end
  end
end
