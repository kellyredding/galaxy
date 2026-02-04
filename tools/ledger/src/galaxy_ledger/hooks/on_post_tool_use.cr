require "json"

module GalaxyLedger
  module Hooks
    # Handles the PostToolUse hook
    # - Tracks file operations (Read, Edit, Write, Glob, Grep)
    # - Detects guideline and implementation plan reads
    # - Buffers entries for later persistence
    class OnPostToolUse
      @session_id : String?
      @tool_name : String?
      @tool_input : JSON::Any?
      @tool_response : String?

      # Patterns for detecting guideline files (Tier 1)
      GUIDELINE_PATTERNS = [
        %r{/agent-guidelines/},
        %r{-style\.md$},
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

        session_id = @session_id
        tool_name = @tool_name
        return unless session_id && tool_name

        # Ensure session folder exists
        session_dir = GalaxyLedger.session_dir(session_id)
        Dir.mkdir_p(session_dir) unless Dir.exists?(session_dir)

        # Process based on tool type
        case tool_name
        when "Read"
          process_read
        when "Edit"
          process_edit
        when "Write"
          process_write
        when "Grep", "Glob"
          process_search
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
          @session_id = json["session_id"]?.try(&.as_s?)
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

      private def process_read
        session_id = @session_id
        tool_input = @tool_input
        tool_response = @tool_response
        return unless session_id && tool_input

        file_path = tool_input["file_path"]?.try(&.as_s?)
        return unless file_path

        # Determine entry type based on file path
        special_type = detect_special_file_type(file_path)

        if special_type && tool_response && !tool_response.empty?
          # Phase 6: For guidelines and implementation plans, spawn extraction
          spawn_extraction_async(session_id, file_path, tool_response, special_type)

          # Also buffer the file path as a marker that we read this file
          entry = Buffer::Entry.new(
            entry_type: special_type,
            content: file_path,
            importance: "medium",
            metadata: JSON.parse({"tool" => "Read", "extraction_spawned" => true}.to_json)
          )
          Buffer.append(session_id, entry)
        else
          # Regular file read - just buffer the path
          entry = Buffer::Entry.new(
            entry_type: "file_read",
            content: file_path,
            importance: "low",
            metadata: JSON.parse({"tool" => "Read"}.to_json)
          )
          Buffer.append(session_id, entry)
        end
      end

      private def spawn_extraction_async(
        session_id : String,
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
            args: ["extract-file", "--session", session_id, "--type", extraction_type, "--path", file_path],
            input: IO::Memory.new(content),
            output: Process::Redirect::Close,
            error: Process::Redirect::Close,
          )
        rescue
          # Silently fail - extraction is best-effort
        end
      end

      private def process_edit
        session_id = @session_id
        tool_input = @tool_input
        return unless session_id && tool_input

        file_path = tool_input["file_path"]?.try(&.as_s?)
        return unless file_path

        entry = Buffer::Entry.new(
          entry_type: "file_edit",
          content: file_path,
          importance: "medium",
          metadata: JSON.parse({"tool" => "Edit"}.to_json)
        )

        Buffer.append(session_id, entry)
      end

      private def process_write
        session_id = @session_id
        tool_input = @tool_input
        return unless session_id && tool_input

        file_path = tool_input["file_path"]?.try(&.as_s?)
        return unless file_path

        entry = Buffer::Entry.new(
          entry_type: "file_write",
          content: file_path,
          importance: "medium",
          metadata: JSON.parse({"tool" => "Write"}.to_json)
        )

        Buffer.append(session_id, entry)
      end

      private def process_search
        session_id = @session_id
        tool_name = @tool_name
        tool_input = @tool_input
        return unless session_id && tool_name && tool_input

        # Extract search pattern
        pattern = tool_input["pattern"]?.try(&.as_s?)
        path = tool_input["path"]?.try(&.as_s?)
        return unless pattern

        content = "#{pattern}"
        content += " in #{path}" if path

        entry = Buffer::Entry.new(
          entry_type: "search",
          content: content,
          importance: "low",
          metadata: JSON.parse({"tool" => tool_name}.to_json)
        )

        Buffer.append(session_id, entry)
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
