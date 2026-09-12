require "json"
require "uuid"

module GalaxyLedger
  module Hooks
    # Manages turn state files for pairing UserPromptSubmit
    # and Stop hook events into duration pairs on the
    # timeline.
    #
    # One JSON file per Claude session at:
    #   ~/.claude/galaxy/ledger/turn-state/{claude_session_id}.json
    #
    # Written by UserPromptSubmit, consumed by Stop/StopFailure,
    # checked by Galaxy App for interrupt detection.
    module TurnState
      struct State
        getter uuid : String
        getter user_message : String
        getter initiated_at : String

        def initialize(
          @uuid : String,
          @user_message : String,
          @initiated_at : String,
        )
        end
      end

      # Directory where turn state files are stored.
      # Creates the directory if it doesn't exist.
      def self.dir : Path
        path = Path.new(
          ENV["GALAXY_DIR"]? || Path.home / ".claude" / "galaxy",
        ) / "ledger" / "turn-state"
        Dir.mkdir_p(path) unless Dir.exists?(path)
        path
      end

      # Write a turn state file for the given Claude session.
      #
      # Callers are expected to have checked `exists?` first —
      # UserPromptSubmit skips recording entirely when a turn is
      # already open, so this is only reached for a turn that is
      # genuinely starting. An earlier version of this comment
      # claimed the overwrite here handled queued messages; the
      # guard that came later made that unreachable, and the
      # queued message is set aside by `write_pending` instead.
      def self.write(
        claude_session_id : String,
        uuid : String,
        user_message : String,
      )
        data = {
          "uuid"         => uuid,
          "user_message" => user_message,
          "initiated_at" => Time.utc.to_rfc3339,
        }
        File.write(state_path(claude_session_id), data.to_json)
      end

      # Read and parse the turn state file for a Claude session.
      # Returns nil if the file doesn't exist or can't be parsed.
      def self.read(
        claude_session_id : String,
      ) : State?
        path = state_path(claude_session_id)
        return nil unless File.exists?(path)

        json = JSON.parse(File.read(path))
        uuid = json["uuid"]?.try(&.as_s?)
        user_message = json["user_message"]?.try(&.as_s?)
        initiated_at = json["initiated_at"]?.try(&.as_s?)

        return nil unless uuid && user_message && initiated_at

        State.new(
          uuid: uuid,
          user_message: user_message,
          initiated_at: initiated_at,
        )
      rescue
        nil
      end

      # Delete the turn state file for a Claude session.
      def self.delete(claude_session_id : String)
        path = state_path(claude_session_id)
        File.delete(path) if File.exists?(path)
      rescue
        # Best-effort — stale files are harmless
      end

      # Check if a turn state file exists without reading it.
      def self.exists?(claude_session_id : String) : Bool
        File.exists?(state_path(claude_session_id))
      end

      # MARK: - Pending prompts

      # Set aside a prompt that arrived while a turn was already
      # running.
      #
      # Claude Code queues such a message and fires UserPromptSubmit
      # at once, then never fires it again when it dequeues. Opening a
      # turn at submit time would overwrite the running one, so the
      # prompt waits here and whichever path opens the next turn
      # claims it. Discarding it is what used to leave the resulting
      # turn with no beginning and no text.
      def self.write_pending(
        claude_session_id : String,
        prompt : String,
      )
        Dir.mkdir_p(pending_dir) unless Dir.exists?(pending_dir)
        data = {
          "user_message" => prompt,
          "queued_at"    => Time.utc.to_rfc3339,
        }
        File.write(pending_path(claude_session_id), data.to_json)
      rescue
        # Best-effort — a turn without its prompt text is still a turn
      end

      # Take the stashed prompt and clear it.
      #
      # Read and delete together: two openers can race on the same
      # session, and a prompt claimed twice would label two turns with
      # one message.
      def self.take_pending(
        claude_session_id : String,
      ) : String?
        path = pending_path(claude_session_id)
        return nil unless File.exists?(path)

        prompt = JSON.parse(File.read(path))["user_message"]?
          .try(&.as_s?)
        File.delete(path)
        prompt
      rescue
        nil
      end

      # Read the stashed prompt without claiming it.
      def self.peek_pending(
        claude_session_id : String,
      ) : String?
        path = pending_path(claude_session_id)
        return nil unless File.exists?(path)

        JSON.parse(File.read(path))["user_message"]?.try(&.as_s?)
      rescue
        nil
      end

      # Discard any stashed prompt without claiming it.
      def self.delete_pending(claude_session_id : String)
        path = pending_path(claude_session_id)
        File.delete(path) if File.exists?(path)
      rescue
        # Best-effort — stale files are harmless
      end

      # Whether a prompt is waiting to become a turn.
      def self.pending?(claude_session_id : String) : Bool
        File.exists?(pending_path(claude_session_id))
      end

      # Open the turn a queued prompt is about to become. Returns
      # whether it opened one.
      #
      # Two things must both hold. A prompt is set aside — the only
      # evidence a message is waiting at all — and Claude Code's own
      # queue record still says that message is waiting. The stash
      # alone is not enough: it is written at submit time, before the
      # queue has decided whether the message becomes a turn or is
      # folded into the one already running, and the second outcome is
      # the more common. Opening on the stash alone means a turn for a
      # message that was already answered, with nothing coming to close
      # it — and the next real prompt is then set aside behind it,
      # mislabelling every turn that follows.
      #
      # A stash the transcript positively disowns is discarded here
      # rather than left to be claimed later by a turn it has nothing
      # to do with. A stash it merely cannot speak for is left alone —
      # the prompt text is the only copy of what was asked, and a turn
      # opened late carrying it beats one opened on time without it.
      #
      # Synchronous, where the writes around it are fire-and-forget.
      # Both callers have just ended a turn, and Galaxy starts and stops
      # the dot from these events in the order they arrive — a start
      # that overtook the end before it would leave the dot dark for the
      # whole turn it was meant to light.
      #
      # `ended_at` is when the previous turn ended — the Stop hook's
      # start, or the interrupting keystroke — and it separates a dequeue
      # that delivered this prompt into that turn from one starting its own.
      def self.open_pending(
        claude_session_id : String,
        ledger_session_id : Int64,
        source : String,
        transcript_path : String?,
        ended_at : Time = Time.utc,
      ) : Bool
        return false if exists?(claude_session_id)

        prompt = peek_pending(claude_session_id)
        return false unless prompt

        case TranscriptScanner.queue_state(transcript_path, prompt, ended_at)
        when .gone?
          delete_pending(claude_session_id)
          return false
        when .unknown?
          return false
        end

        return false unless take_pending(claude_session_id)

        uuid = UUID.random.to_s
        detail_data = {
          "user_message" => prompt,
        }.to_json

        Process.run(
          TIMELINE_BIN.to_s,
          args: [
            "record",
            "--ledger-session-id",
            ledger_session_id.to_s,
            "--event-type", "turn:initiated",
            "--source", source,
            "--duration-identifier",
            "turn--#{uuid}",
            "--detail-data-stdin",
          ],
          input: IO::Memory.new(detail_data),
          output: Process::Redirect::Close,
          error: Process::Redirect::Close,
        )

        write(claude_session_id, uuid, prompt)
        true
      rescue
        # Best-effort — without the state file the agent's first line of
        # text still opens a turn, which is where this started
        false
      end

      # Close an orphaned turn by recording turn:abandoned
      # and deleting the state file. Synchronous — the
      # timeline event must be recorded before the caller's
      # own event (context:cleared, session:ended, etc.)
      # to preserve chronological ordering.
      def self.close_orphan(
        claude_session_id : String,
        ledger_session_id : Int64,
      )
        state = read(claude_session_id)
        return unless state

        detail_data = {
          "user_message" => state.user_message,
        }.to_json

        Process.run(
          TIMELINE_BIN.to_s,
          args: [
            "record",
            "--ledger-session-id",
            ledger_session_id.to_s,
            "--event-type", "turn:abandoned",
            "--source", "galaxy-ledger",
            "--duration-identifier",
            "turn--#{state.uuid}",
            "--detail-data-stdin",
          ],
          input: IO::Memory.new(detail_data),
          output: Process::Redirect::Close,
          error: Process::Redirect::Close,
        )

        delete(claude_session_id)
      rescue
        # Best-effort — orphan cleanup is not fatal
      end

      # MARK: - Sweeping

      # Remove turn state left behind by sessions that are gone.
      #
      # A file survives only when its identifier is still the one its
      # ledger session is using AND that session's process is alive.
      # Both halves are needed, and the first is the one that is easy
      # to miss: a resume mints a new identifier, so a long-lived
      # session accumulates files under identifiers it has moved on
      # from. Liveness alone keeps those forever — two such files were
      # 29 and 14 days old against a session still running.
      #
      # No age threshold, deliberately. A turn can stay legitimately
      # open for days while the agent waits on a permission prompt,
      # and any timer generous enough for a fortnight's holiday is
      # also generous enough to let a leak suppress turn tracking for
      # a fortnight. Liveness answers the real question directly.
      #
      # An identifier that resolves to nothing cannot be current, so
      # it sweeps — which is what stops an unknown file living
      # forever.
      def self.sweep_orphans
        return unless Dir.exists?(dir)

        Dir.each_child(dir.to_s) do |name|
          next unless name.ends_with?(".json")
          claude_session_id = name[0...-5]
          next if session_live?(claude_session_id)

          if state = read(claude_session_id)
            close_swept(claude_session_id, state)
          end
          delete(claude_session_id)
          delete_pending(claude_session_id)
        end
      rescue
        # Best-effort — housekeeping is never worth failing a hook
      end

      # Whether this identifier still names a running session.
      def self.session_live?(claude_session_id : String) : Bool
        ledger_session_id =
          Database.resolve_session_identifier(claude_session_id)
        return false unless ledger_session_id
        return false unless ledger_session_id > 0

        record = Database.get_session_by_id(ledger_session_id)
        return false unless record

        # A session that has moved to a newer identifier has left this
        # file behind, however alive the session itself is.
        return false unless record.current_session_identifier ==
                              claude_session_id

        pid = record.current_claude_pid
        return false unless pid
        claude_process?(pid)
      rescue
        false
      end

      # Whether this pid is a live `claude`.
      #
      # The command name is checked rather than mere existence: the OS
      # recycles pids, and a dead session whose number was reused
      # would otherwise read as alive and keep its file forever.
      def self.claude_process?(pid : Int64) : Bool
        output = IO::Memory.new
        status = Process.run(
          "ps",
          args: ["-p", pid.to_s, "-o", "comm="],
          output: output,
          error: Process::Redirect::Close,
        )
        return false unless status.success?
        output.to_s.includes?("claude")
      rescue
        false
      end

      # Close a swept turn on the timeline at the time it began.
      #
      # Dated to `initiated_at` rather than now, so a turn abandoned
      # months ago does not appear as today's activity. The bar has no
      # length, which is the honest rendering: when it started is
      # known and when it stopped is not, and inventing an end would
      # be worse than showing none. `source` names what judged it stale.
      def self.close_swept(
        claude_session_id : String,
        state : State,
        source : String = "galaxy-ledger/sweep",
      )
        ledger_session_id =
          Database.resolve_session_identifier(claude_session_id)
        return unless ledger_session_id
        return unless ledger_session_id > 0

        detail_data = {
          "user_message" => state.user_message,
        }.to_json

        Process.run(
          TIMELINE_BIN.to_s,
          args: [
            "record",
            "--ledger-session-id",
            ledger_session_id.to_s,
            "--event-type", "turn:abandoned",
            "--source", source,
            "--duration-identifier",
            "turn--#{state.uuid}",
            "--occurred-at", state.initiated_at,
            "--detail-data-stdin",
          ],
          input: IO::Memory.new(detail_data),
          output: Process::Redirect::Close,
          error: Process::Redirect::Close,
        )
      rescue
        # Best-effort — the file still goes
      end

      # Full path to the state file for a Claude session.
      def self.state_path(
        claude_session_id : String,
      ) : Path
        dir / "#{claude_session_id}.json"
      end

      # Directory holding prompts set aside mid-turn. A sibling of the
      # state directory so the sweeper can treat the two alike.
      def self.pending_dir : Path
        Path.new(
          ENV["GALAXY_DIR"]? || Path.home / ".claude" / "galaxy",
        ) / "ledger" / "turn-pending"
      end

      def self.pending_path(
        claude_session_id : String,
      ) : Path
        pending_dir / "#{claude_session_id}.json"
      end
    end
  end
end
