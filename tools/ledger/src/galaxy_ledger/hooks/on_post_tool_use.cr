require "json"

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

      # Detect if a written file is an artifact and store it.
      # Runs silently — failures are ignored. The original file is
      # always left in place; artifact storage is a copy.
      private def detect_and_store_artifact(
        ledger_session_id : Int64,
        file_path : String,
      )
        config = Config.load
        return unless config.artifacts.enabled && config.artifacts.auto_detect

        # Classify the file
        classification = ArtifactClassifier.classify(file_path)
        return unless classification

        # Check file size limit
        source_size = ArtifactStorage.file_size(file_path)
        return if source_size <= 0
        return if source_size > config.artifacts.max_file_size

        original_filename = File.basename(file_path)
        title = ArtifactStorage.title_from_filename(original_filename)

        # Compute hash from tool_input content if available, else from file
        hash = if content = @tool_input.try(&.["content"]?.try(&.as_s?))
                 ArtifactStorage.content_hash(content)
               else
                 ArtifactStorage.file_hash(file_path)
               end

        result = Database.save_artifact(
          ledger_session_id,
          title: title,
          artifact_type: classification.artifact_type,
          mime_type: classification.mime_type,
          original_filename: original_filename,
          stored_path: "", # Placeholder, updated after storage
          source_path: file_path,
          file_size: source_size,
          content_hash: hash,
        )
        return if result.action.failed?
        number = result.number

        # Enrichment means same file, same content — skip file copy.
        return if result.action.enrichment?

        # Insert or VersionUpdate — store/overwrite the file.
        stored_path = if content = @tool_input.try(&.["content"]?.try(&.as_s?))
                        ArtifactStorage.store_content(
                          ledger_session_id, number, content, original_filename,
                        )
                      else
                        ArtifactStorage.store(
                          ledger_session_id, number, file_path, original_filename,
                        )
                      end

        # Update the stored_path in the DB record
        if stored_path
          Database.update_artifact_stored_path(ledger_session_id, number, stored_path)
        end
      rescue
        # Silently fail — artifact capture is best-effort
      end
    end
  end
end
