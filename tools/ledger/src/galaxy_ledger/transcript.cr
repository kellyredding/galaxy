require "json"

module GalaxyLedger
  # Parses Claude Code transcript JSONL files
  # Used to extract the last user/assistant exchange for the ledger
  module Transcript
    # Parse a transcript JSONL file into an array of entries
    # Returns empty array if file doesn't exist or can't be parsed
    def self.parse(path : String) : Array(TranscriptEntry)
      entries = [] of TranscriptEntry

      return entries unless File.exists?(path)

      begin
        File.each_line(path) do |line|
          next if line.strip.empty?

          begin
            entry = TranscriptEntry.from_json(line)
            entries << entry
          rescue
            # Skip malformed lines, continue parsing
          end
        end
      rescue
        # Return empty array if we can't read the file
      end

      entries
    end

    # Extract the last exchange from transcript entries
    # Returns the last user message and all subsequent assistant messages
    def self.extract_last_exchange(entries : Array(TranscriptEntry)) : ExtractedExchange?
      return nil if entries.empty?

      # Find the last REAL user message (scanning backwards)
      # Skip: tool_result entries, command entries, local-command entries
      last_user_idx : Int32? = nil
      (entries.size - 1).downto(0) do |i|
        entry = entries[i]
        if entry.type == "user" && entry.message
          content = entry.message.try(&.content)
          next unless content

          # Skip system-generated entries
          next if content.includes?("<command-name>")
          next if content.includes?("<local-command")
          next if entry.message.try(&.is_tool_result?)

          last_user_idx = i
          break
        end
      end

      return nil unless last_user_idx

      user_entry = entries[last_user_idx]
      user_message = user_entry.message.try(&.content)
      return nil unless user_message

      # Collect all assistant messages after the user message
      assistant_messages = [] of AssistantEntry
      ((last_user_idx + 1)...entries.size).each do |i|
        entry = entries[i]

        # Only include assistant type entries with message content
        if entry.type == "assistant" && entry.message
          content = entry.message.try(&.content)
          next unless content

          # Extract tool uses from the entry (if available)
          tool_uses = extract_tool_uses(entry)

          assistant_messages << AssistantEntry.new(
            content: content,
            timestamp: entry.timestamp,
            tool_uses: tool_uses
          )
        end
      end

      ExtractedExchange.new(
        user_message: user_message,
        user_timestamp: user_entry.timestamp,
        assistant_entries: assistant_messages
      )
    end

    # Convert extracted exchange to LastExchange format for storage
    def self.to_last_exchange(extracted : ExtractedExchange) : Exchange::LastExchange
      # Combine all assistant messages into full_content
      full_content = extracted.assistant_entries.map(&.content).join("\n\n")

      # Convert to AssistantMessage format
      assistant_messages = extracted.assistant_entries.map do |entry|
        Exchange::AssistantMessage.new(
          content: entry.content,
          timestamp: entry.timestamp,
          tool_uses: entry.tool_uses
        )
      end

      Exchange::LastExchange.new(
        user_message: extracted.user_message,
        user_timestamp: extracted.user_timestamp,
        full_content: full_content,
        assistant_messages: assistant_messages,
        summary: nil # Generated in Phase 6
      )
    end

    # Extract tool uses from a transcript entry
    # This is a simplified extraction - actual tool use tracking comes in Phase 5
    private def self.extract_tool_uses(entry : TranscriptEntry) : Array(String)
      # For now, return empty array
      # Full tool use extraction will be implemented in Phase 5 when we have
      # access to the full tool use events in the transcript
      [] of String
    end

    # A single entry from the transcript JSONL file
    class TranscriptEntry
      include JSON::Serializable

      property uuid : String?

      @[JSON::Field(key: "parentUuid")]
      property parent_uuid : String?

      @[JSON::Field(key: "sessionId")]
      property session_id : String?

      property timestamp : String?

      property type : String?

      property message : TranscriptMessage?

      property cwd : String?

      @[JSON::Field(key: "isSidechain")]
      property is_sidechain : Bool?

      @[JSON::Field(key: "userType")]
      property user_type : String?

      property version : String?
    end

    # Message content within a transcript entry
    # The content field can be either:
    # - A simple string (for user text messages)
    # - An array of content blocks (for tool results, assistant responses with thinking/tool_use/text)
    class TranscriptMessage
      include JSON::Serializable

      property role : String?

      # Use JSON::Any to handle polymorphic content (string or array)
      @[JSON::Field(key: "content")]
      property raw_content : JSON::Any?

      # Extract readable text content from the message
      def content : String?
        raw = raw_content
        return nil unless raw

        case raw.raw
        when String
          # Simple string content
          raw.as_s
        when Array
          # Array of content blocks - extract text from each
          extract_text_from_content_blocks(raw.as_a)
        else
          nil
        end
      end

      # Check if this message is a tool_result (system-generated, not real user input)
      def is_tool_result? : Bool
        raw = raw_content
        return false unless raw

        case raw.raw
        when Array
          raw.as_a.any? do |block|
            if obj = block.as_h?
              obj["type"]?.try(&.as_s?) == "tool_result"
            else
              false
            end
          end
        else
          false
        end
      end

      private def extract_text_from_content_blocks(blocks : Array(JSON::Any)) : String?
        texts = [] of String

        blocks.each do |block|
          next unless block.as_h?
          obj = block.as_h

          block_type = obj["type"]?.try(&.as_s?)

          case block_type
          when "text"
            # Text blocks have "text" field
            if text = obj["text"]?.try(&.as_s?)
              texts << text
            end
          when "tool_result"
            # Tool results have "content" field (usually the output)
            if content = obj["content"]?.try(&.as_s?)
              # Skip tool results for now - they're verbose and not the "user message"
              # We could include them but they clutter the exchange
            end
          when "thinking"
            # Skip thinking blocks - internal to Claude
          when "tool_use"
            # Skip tool_use blocks - they're captured separately
          end
        end

        texts.empty? ? nil : texts.join("\n\n")
      end
    end

    # Result of extracting the last exchange from a transcript
    class ExtractedExchange
      getter user_message : String
      getter user_timestamp : String?
      getter assistant_entries : Array(AssistantEntry)

      def initialize(
        @user_message : String,
        @user_timestamp : String? = nil,
        @assistant_entries : Array(AssistantEntry) = [] of AssistantEntry,
      )
      end

      def has_assistant_response? : Bool
        !assistant_entries.empty?
      end

      def combined_content : String
        assistant_entries.map(&.content).join("\n\n")
      end
    end

    # A single assistant message from the transcript
    class AssistantEntry
      getter content : String
      getter timestamp : String?
      getter tool_uses : Array(String)

      def initialize(
        @content : String,
        @timestamp : String? = nil,
        @tool_uses : Array(String) = [] of String,
      )
      end
    end
  end
end
