require "json"
require "digest/sha256"

module GalaxyLedger
  module Hooks
    # Handles the PostToolUse hook — RESOLVE MODE
    # - Resolves session by Claude Code PID
    # - Tracks file operations (Read, Edit, Write, Glob, Grep) via session_files DB table
    # - Detects file types via path-convention matching
    class OnPostToolUse
      @stdin_session_identifier : String?
      @tool_name : String?
      @tool_input : JSON::Any?

      def run
        # Skip if GALAXY_SKIP_HOOKS is set (prevents recursion from extraction subprocesses)
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        # Parse hook input from stdin
        parse_hook_input

        tool_name = @tool_name
        return unless tool_name

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

        # Process based on tool type
        case tool_name
        when "Read"
          process_read(ledger_session_id)
        when "Edit"
          process_edit(ledger_session_id)
        when "Write"
          process_write(ledger_session_id)
        when "Grep", "Glob"
          process_search(ledger_session_id)
        end
      end

      private def parse_hook_input
        # Hook receives JSON via stdin:
        # {
        #   "session_id": "abc123",
        #   "tool_name": "Read|Edit|Write|Grep|Glob",
        #   "tool_input": {...},
        #   ...
        # }
        begin
          input = STDIN.gets_to_end
          return if input.empty?

          json = JSON.parse(input)
          @stdin_session_identifier = json["session_id"]?.try(&.as_s?)
          @tool_name = json["tool_name"]?.try(&.as_s?)
          @tool_input = json["tool_input"]?
        rescue
          # Silently ignore parse errors
        end
      end

      private def process_read(ledger_session_id : Int64)
        tool_input = @tool_input
        return unless tool_input

        file_path = tool_input["file_path"]?.try(&.as_s?)
        return unless file_path

        file_type = FileTypeDetector.detect(file_path)
        Database.upsert_session_file(
          ledger_session_id, file_path, :read,
          file_type: file_type,
        )
      end

      private def process_edit(ledger_session_id : Int64)
        tool_input = @tool_input
        return unless tool_input

        file_path = tool_input["file_path"]?.try(&.as_s?)
        return unless file_path

        file_type = FileTypeDetector.detect(file_path)
        Database.upsert_session_file(
          ledger_session_id, file_path, :edit,
          file_type: file_type,
        )
      end

      private def process_write(ledger_session_id : Int64)
        tool_input = @tool_input
        return unless tool_input

        file_path = tool_input["file_path"]?.try(&.as_s?)
        return unless file_path

        file_type = FileTypeDetector.detect(file_path)
        Database.upsert_session_file(
          ledger_session_id, file_path, :write,
          file_type: file_type,
        )

        detect_and_store_artifact(ledger_session_id, file_path)
      end

      private def process_search(ledger_session_id : Int64)
        tool_name = @tool_name
        tool_input = @tool_input
        return unless tool_name && tool_input

        pattern = tool_input["pattern"]?.try(&.as_s?)
        return unless pattern

        search_path = tool_input["path"]?.try(&.as_s?) || ""

        file_type = FileTypeDetector.detect(search_path)
        Database.upsert_session_file(
          ledger_session_id, search_path, :search,
          search_pattern: pattern,
          file_type: file_type,
        )
      end

      # Detect if a written file is an artifact and delegate to
      # galaxy-artifacts for storage. Classification stays in ledger
      # as the gate logic. Runs silently — failures are ignored.
      private def detect_and_store_artifact(
        ledger_session_id : Int64,
        file_path : String,
      )
        # Classification stays in ledger — it's a hook-level gate
        classification = ArtifactClassifier.classify(file_path)
        return unless classification

        # Check file size limit
        file_size = File.size(file_path).to_i64 rescue return
        return if file_size <= 0

        artifacts_bin = (
          GalaxyLedger::GALAXY_DIR / "bin" / "galaxy-artifacts"
        ).to_s
        return unless File.exists?(artifacts_bin)

        # Compute hash from tool_input content if available, else from file
        content_hash = if content = @tool_input.try(&.["content"]?.try(&.as_s?))
                         Digest::SHA256.hexdigest(content)
                       else
                         Digest::SHA256.hexdigest(File.read(file_path))
                       end

        # Hook-classified writes are a side-effect of the
        # agent's work (commit-message scratch files, /tmp/
        # exports, etc.), not user-initiated saves. Suppress
        # the artifact.show socket event so Galaxy.app
        # doesn't auto-open a reader on the user. The
        # artifact remains available in the Artifacts tab.
        # Deliberate saves go through `galaxy-artifacts save`
        # directly (skills, agents) and continue to fire the
        # show event.
        cli_args = [
          "save",
          "--ledger-session-id", ledger_session_id.to_s,
          "--source-path", file_path,
          "--artifact-type", classification.artifact_type,
          "--mime-type", classification.mime_type,
          "--content-hash", content_hash,
          "--file-size", file_size.to_s,
          "--skip-event",
        ]

        Process.run(
          artifacts_bin,
          args: cli_args,
          output: Process::Redirect::Close,
          error: Process::Redirect::Close,
        )
      rescue
        # Silently fail — artifact capture is best-effort
      end
    end
  end
end
