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
      @tool_result : String?

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
        #   "tool_result": "...",
        #   ...
        # }
        begin
          input = STDIN.gets_to_end
          return if input.empty?

          json = JSON.parse(input)
          @session_id = json["session_id"]?.try(&.as_s?)
          @tool_name = json["tool_name"]?.try(&.as_s?)
          @tool_input = json["tool_input"]?
          @tool_result = json["tool_result"]?.try(&.as_s?)
        rescue
          # Silently ignore parse errors
        end
      end

      private def process_read
        session_id = @session_id
        tool_input = @tool_input
        return unless session_id && tool_input

        file_path = tool_input["file_path"]?.try(&.as_s?)
        return unless file_path

        # Determine entry type based on file path
        entry_type = detect_special_file_type(file_path) || "file_read"

        # Create entry with file path as content
        entry = Buffer::Entry.new(
          entry_type: entry_type,
          content: file_path,
          importance: entry_type == "file_read" ? "low" : "medium",
          metadata: JSON.parse({"tool" => "Read"}.to_json)
        )

        Buffer.append(session_id, entry)
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
