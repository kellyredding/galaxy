require "json"

module GalaxyLedger
  module Hooks
    # Handles the Stop hook — RESOLVE MODE
    # - Resolves session by Claude Code PID
    # - Records turn:completed or turn:continued timeline events
    # - Parses transcript to capture last exchange
    # - Writes last interaction to DB session record
    # - Reports context usage via colored status indicator
    # - Spawns async extraction for learnings/decisions/summary
    #
    # Output: Claude Code Stop hook JSON format
    #   { "decision": "approve", "systemMessage": "🟢 Context 34% │ ..." }
    class OnStop
      @stdin_session_identifier : String?
      @transcript_path : String?
      @stdin_cwd : String?
      @stop_hook_active : Bool = false
      @last_assistant_message : String?

      def run
        # Skip if GALAXY_SKIP_HOOKS is set (prevents recursion from extraction subprocesses)
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        # Parse hook input from stdin
        parse_hook_input

        # Prevent infinite loops - if stop hook is already active, return immediately
        if @stop_hook_active
          return
        end

        # Resolve session via 3-tier chain (PID → env var → hook session_id).
        # No creation — bail if nothing resolves.
        claude_pid = Process.ppid.to_i64
        env_session_id = ENV[Resolver::ENV_SESSION_ID_KEY]?

        ledger_session_id = Resolver.resolve_session(
          claude_pid: claude_pid,
          env_session_id: env_session_id,
          stdin_session_id: @stdin_session_identifier,
        )
        return unless ledger_session_id

        # Stamp the current working directory from the hook input.
        # This captures Claude Code's CWD at end-of-turn — before any
        # /clear or auto-compact can reset it.  The handoff prefers this
        # over the status-line-driven previous_cwd because it's written
        # once per turn at a deterministic boundary, not on every async
        # status line tick.
        if cwd = @stdin_cwd
          Database.stamp_stop_cwd(ledger_session_id, cwd) unless cwd.empty?
        end

        # Get current session_identifier for extraction subprocess --session flags
        session_record = Database.get_session_by_id(ledger_session_id)
        current_sid = session_record.try(&.current_session_identifier) || @stdin_session_identifier
        return unless current_sid

        # Record turn event: turn:completed (state file exists)
        # or turn:continued (no state file, agent-initiated).
        record_turn_event(ledger_session_id, current_sid)

        # Spawn async extraction process for exchange capture + learnings/decisions/summary.
        # Exchange capture is done in the subprocess with exponential backoff because
        # Claude Code writes the assistant response to the transcript AFTER the stop hook fires.
        extraction_spawned = spawn_extraction_async(ledger_session_id, current_sid)

        # Spawn async name suggestion process.
        # Short-circuits internally if name already finalized.
        name_suggestion_spawned = spawn_name_suggestion_async(ledger_session_id, current_sid)

        # Re-read session record to get latest context_percentage
        session_record = Database.get_session_by_id(ledger_session_id)
        return unless session_record

        # Build and output structured JSON system message
        system_message = build_system_message(
          percentage: session_record.context_percentage,
          extraction_spawned: extraction_spawned,
          name_suggestion_spawned: name_suggestion_spawned,
        )
        puts output_stop_json(system_message)
      end

      private def parse_hook_input
        # Hook receives JSON via stdin:
        # {
        #   "session_id": "abc123",
        #   "transcript_path": "/path/to/transcript.jsonl",
        #   "cwd": "/current/working/directory",
        #   "stop_hook_active": true|false,
        #   ...
        # }
        begin
          input = STDIN.gets_to_end
          return if input.empty?

          json = JSON.parse(input)
          @stdin_session_identifier = json["session_id"]?.try(&.as_s?)
          @transcript_path = json["transcript_path"]?.try(&.as_s?)
          @stdin_cwd = json["cwd"]?.try(&.as_s?)
          @stop_hook_active = json["stop_hook_active"]?.try(&.as_bool?) || false
          @last_assistant_message = json["last_assistant_message"]?.try(&.as_s?)
        rescue
          # Silently ignore parse errors
        end
      end

      private def record_turn_event(
        ledger_session_id : Int64,
        current_sid : String,
      )
        stdin_sid = @stdin_session_identifier
        return unless stdin_sid

        # Filter: session_id must match the ledger's current
        # session identifier (skip extraction sub-sessions)
        return unless stdin_sid == current_sid

        state = TurnState.read(stdin_sid)

        if state
          # State file exists — user initiated this turn.
          # Record turn:completed with the paired UUID.
          # Scan transcript for mid-turn follow-up messages.
          follow_ups = [] of TranscriptScanner::FollowUpMessage
          if tp = @transcript_path
            follow_ups = TranscriptScanner.follow_up_messages(
              tp,
              state.initiated_at,
              stdin_sid,
            )
          end

          detail_data = JSON.build do |json|
            json.object do
              json.field "user_message", state.user_message
              json.field "follow_up_messages" do
                json.array do
                  follow_ups.each(&.to_json(json))
                end
              end
              json.field "assistant_response",
                @last_assistant_message
            end
          end

          begin
            Process.new(
              TIMELINE_BIN.to_s,
              args: [
                "record",
                "--ledger-session-id",
                ledger_session_id.to_s,
                "--event-type", "turn:completed",
                "--source", "galaxy-ledger",
                "--duration-identifier",
                "turn--#{state.uuid}",
                "--detail-data-stdin",
              ],
              input: IO::Memory.new(detail_data),
              output: Process::Redirect::Close,
              error: Process::Redirect::Close,
            )
          rescue
            # Best-effort
          end

          TurnState.delete(stdin_sid)
        else
          # No state file — agent responded without a user
          # prompt (e.g., task-notification follow-up).
          # Record turn:continued as a point event.
          assistant_msg = @last_assistant_message
          return unless assistant_msg

          detail_data = {
            "assistant_response" => assistant_msg,
          }.to_json

          begin
            Process.new(
              TIMELINE_BIN.to_s,
              args: [
                "record",
                "--ledger-session-id",
                ledger_session_id.to_s,
                "--event-type", "turn:continued",
                "--source", "galaxy-ledger",
                "--detail-data-stdin",
              ],
              input: IO::Memory.new(detail_data),
              output: Process::Redirect::Close,
              error: Process::Redirect::Close,
            )
          rescue
            # Best-effort
          end
        end
      rescue
        # Turn tracking failure is not fatal
      end

      # Build the context indicator when above warning thresholds.
      # Returns nil when below warning threshold (no indicator shown).
      # Uses configurable thresholds for warning/critical boundaries.
      # Reads ~/.claude.json to tailor the critical message based on
      # whether auto-compact is enabled.
      #
      #   nil                                                       (below warning)
      #   ⚠️ Context 72% — consider /clear soon                     (warning)
      #   🔥 Context 87% — will auto-compact soon                    (critical, auto-compact on)
      #   🔥 Context 87% — context nearly full, /clear now          (critical, auto-compact off)
      private def build_context_indicator(percentage : Float64) : String?
        config = Config.load

        pct = percentage.round.to_i
        pct = 0 if pct < 0

        if percentage >= config.thresholds.critical
          if auto_compact_enabled?
            "\u{1F525} Context #{pct}% \u2014 will auto-compact soon"
          else
            "\u{1F525} Context #{pct}% \u2014 context nearly full, /clear now"
          end
        elsif percentage >= config.thresholds.warning
          "\u26A0\uFE0F Context #{pct}% \u2014 consider /clear soon"
        else
          nil
        end
      end

      # Check if Claude Code's auto-compact feature is enabled.
      # Reads ~/.claude.json (Claude Code's app state file).
      # Defaults to true (safer assumption) if the file can't be read.
      # Path is overridable via GALAXY_CLAUDE_JSON_PATH env var for testing.
      private def auto_compact_enabled? : Bool
        path = ENV["GALAXY_CLAUDE_JSON_PATH"]? || (Path.home / ".claude.json").to_s
        return true unless File.exists?(path)

        json = JSON.parse(File.read(path))
        json["autoCompactEnabled"]?.try(&.as_bool?) || false
      rescue
        true
      end

      # Assemble the full system message from activity parts.
      # Format: {context_indicator} │ {activity parts...}
      private def build_system_message(
        percentage : Float64,
        extraction_spawned : Bool,
        name_suggestion_spawned : Bool,
      ) : String
        parts = [] of String
        indicator = build_context_indicator(percentage)
        parts << indicator if indicator

        # Collapse all background subprocesses into a single count
        bg_count = 0
        bg_count += 1 if extraction_spawned
        bg_count += 1 if name_suggestion_spawned
        if bg_count > 0
          label = bg_count == 1 ? "task" : "tasks"
          parts << "#{bg_count} background #{label} spawned"
        end

        parts.join(" \u2502 ")
      end

      # Output Claude Code Stop hook JSON format.
      private def output_stop_json(system_message : String) : String
        {
          "decision"      => "approve",
          "systemMessage" => system_message,
        }.to_json
      end

      private def spawn_extraction_async(ledger_session_id : Int64, current_sid : String) : Bool
        transcript_path = @transcript_path
        return false unless transcript_path

        # Check if extraction is enabled in config
        config = Config.load
        return false unless config.extraction.on_stop

        # Spawn async extraction process with transcript path.
        # The subprocess handles exchange capture (with exponential backoff)
        # and extraction. This avoids the transcript timing bug where the
        # assistant response hasn't been flushed yet when the stop hook fires.
        begin
          binary = Process.executable_path || "galaxy-ledger"

          Process.new(
            binary,
            args: ["extract-assistant", "--session", current_sid, "--transcript-path", transcript_path],
            input: Process::Redirect::Close,
            output: Process::Redirect::Close,
            error: Process::Redirect::Close,
          )
          true
        rescue
          false
        end
      end

      private def spawn_name_suggestion_async(ledger_session_id : Int64, current_sid : String) : Bool
        transcript_path = @transcript_path
        return false unless transcript_path

        # Check if suggestion is enabled in config
        config = Config.load
        return false unless config.suggested_name.enabled

        # Pre-check: skip if already finalized (avoid subprocess overhead)
        session = Database.get_session_by_id(ledger_session_id)
        if session
          state = SuggestedName::StateData.from_json_safe(session.suggested_name_data)
          return false if state.generation_complete?
        end

        begin
          binary = Process.executable_path || "galaxy-ledger"

          Process.new(
            binary,
            args: ["suggest-name", "--session", current_sid, "--transcript-path", transcript_path],
            input: Process::Redirect::Close,
            output: Process::Redirect::Close,
            error: Process::Redirect::Close,
          )
          true
        rescue
          false
        end
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
