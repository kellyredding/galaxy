require "json"

module GalaxyLedger
  module Hooks
    # Handles the PostToolUse hook — RESOLVE MODE
    # - Resolves session by Claude Code PID
    # - Tracks file operations (Read, Edit, Write, Glob, Grep) via session_files DB table
    # - Detects guideline and implementation plan reads for extraction
    # - Writes extraction entries directly to SQLite
    class OnPostToolUse
      @stdin_session_identifier : String?
      @tool_name : String?
      @tool_input : JSON::Any?
      @tool_response : String?

      # Patterns for detecting guideline files (Tier 1)
      GUIDELINE_PATTERNS = [
        %r{/agent-guidelines/},
      ]

      # Patterns for detecting implementation plan files (Tier 1)
      IMPLEMENTATION_PLAN_PATTERNS = [
        %r{/implementation-plans/},
      ]

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

        # Get current session_identifier for extraction subprocess --session flags
        session_record = Database.get_session_by_id(ledger_session_id)
        current_sid = session_record.try(&.current_session_identifier) || @stdin_session_identifier
        return unless current_sid

        # Process based on tool type
        case tool_name
        when "Read"
          process_read(ledger_session_id, current_sid)
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
        #   "tool_response": "..." or {...},  # Note: Claude Code uses "tool_response", not "tool_result"
        #   ...
        # }
        begin
          input = STDIN.gets_to_end
          return if input.empty?

          json = JSON.parse(input)
          @stdin_session_identifier = json["session_id"]?.try(&.as_s?)
          @tool_name = json["tool_name"]?.try(&.as_s?)
          @tool_input = json["tool_input"]?

          # tool_response can be a string or an object depending on the tool
          # For Read tool, it should contain the file contents as a string
          tool_response_raw = json["tool_response"]?
          if tool_response_raw
            # Try to get as string first (most common for Read)
            @tool_response = tool_response_raw.as_s? || tool_response_raw.to_json
          end
        rescue
          # Silently ignore parse errors
        end
      end

      private def process_read(ledger_session_id : Int64, current_sid : String)
        tool_input = @tool_input
        tool_response = @tool_response
        return unless tool_input

        file_path = tool_input["file_path"]?.try(&.as_s?)
        return unless file_path

        # Determine entry type based on file path
        special_type = detect_special_file_type(file_path)

        # Track every read in session_files, regardless of file type
        Database.upsert_session_file(ledger_session_id, file_path, :read)

        if special_type && tool_response && !tool_response.empty?
          # Skip extraction if we already have a marker for this source file in this session.
          # The LLM produces unique output each time, so the content-hash unique index
          # can't catch these — we need to check by source_file instead.
          already_extracted = Database.has_extracted_source_file?(ledger_session_id, file_path)

          unless already_extracted
            # For guidelines and implementation plans, spawn extraction
            # NOTE: extraction subprocesses use --session (not --pid) because their
            # PPID is the hook process, not Claude Code.
            spawn_extraction_async(current_sid, file_path, tool_response, special_type)
          end

          # Always record a marker entry that we read this file.
          # Uses a dedicated extraction_marker type so markers don't pollute
          # guideline/implementation_plan queries or FTS search results.
          # Stores the original extraction type in metadata for re-extraction.
          entry = Entry.new(
            entry_type: "extraction_marker",
            content: file_path,
            importance: "medium",
            metadata: JSON.parse({"tool" => "Read", "extraction_type" => special_type, "extraction_spawned" => !already_extracted}.to_json),
            source_file: file_path,
          )
          Database.insert(ledger_session_id, entry)
        end
      end

      private def spawn_extraction_async(
        session_identifier : String,
        file_path : String,
        content : String,
        extraction_type : String,
      )
        # Check if extraction is enabled
        config = Config.load
        return unless config.extraction.on_guideline_read

        begin
          binary = Process.executable_path || "galaxy-ledger"

          # Pass content via stdin
          Process.new(
            binary,
            args: ["extract-file", "--session", session_identifier, "--type", extraction_type, "--path", file_path],
            input: IO::Memory.new(content),
            output: Process::Redirect::Close,
            error: Process::Redirect::Close,
          )
        rescue
          # Silently fail - extraction is best-effort
        end
      end

      private def process_edit(ledger_session_id : Int64)
        tool_input = @tool_input
        return unless tool_input

        file_path = tool_input["file_path"]?.try(&.as_s?)
        return unless file_path

        # Record in session_files table
        Database.upsert_session_file(ledger_session_id, file_path, :edit)

        # Mark extracted entries stale if this is a special file
        check_stale_extraction(ledger_session_id, file_path)
      end

      private def process_write(ledger_session_id : Int64)
        tool_input = @tool_input
        return unless tool_input

        file_path = tool_input["file_path"]?.try(&.as_s?)
        return unless file_path

        # Record in session_files table
        Database.upsert_session_file(ledger_session_id, file_path, :write)

        # Mark extracted entries stale if this is a special file
        check_stale_extraction(ledger_session_id, file_path)

        # Artifact detection
        detect_and_store_artifact(ledger_session_id, file_path)
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

      # When a guideline or implementation plan file is edited/written,
      # mark its extracted entries as stale so the Stop hook knows to
      # re-extract fresh content from disk.
      private def check_stale_extraction(ledger_session_id : Int64, file_path : String)
        special_type = detect_special_file_type(file_path)
        return unless special_type

        Database.mark_entries_stale(ledger_session_id, file_path)
      end

      private def process_search(ledger_session_id : Int64)
        tool_name = @tool_name
        tool_input = @tool_input
        return unless tool_name && tool_input

        # Extract search pattern
        pattern = tool_input["pattern"]?.try(&.as_s?)
        return unless pattern

        search_path = tool_input["path"]?.try(&.as_s?) || ""

        # Record in session_files table
        Database.upsert_session_file(ledger_session_id, search_path, :search, search_pattern: pattern)
      end

      private def detect_special_file_type(file_path : String) : String?
        # Check for guideline files
        GUIDELINE_PATTERNS.each do |pattern|
          return "guideline" if pattern.matches?(file_path)
        end

        # Check for implementation plan files
        IMPLEMENTATION_PLAN_PATTERNS.each do |pattern|
          return "implementation_plan" if pattern.matches?(file_path)
        end

        nil
      end
    end
  end
end
