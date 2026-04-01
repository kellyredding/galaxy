require "json"

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
      # Overwrites any existing state (handles queued messages
      # and hung resubmissions).
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
          TIMELINE_BIN_NAME,
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

      # Full path to the state file for a Claude session.
      def self.state_path(
        claude_session_id : String,
      ) : Path
        dir / "#{claude_session_id}.json"
      end
    end
  end
end
