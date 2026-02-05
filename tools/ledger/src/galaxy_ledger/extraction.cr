require "json"
require "./extraction/*"

module GalaxyLedger
  # Extraction module for Phase 6
  # Handles Claude CLI one-shot calls to extract learnings, directions, and summaries
  module Extraction
    # Result of an extraction operation
    class Result
      include JSON::Serializable

      # Extracted entries (learnings, decisions, directions, etc.)
      property extractions : Array(ExtractedEntry)

      # Summary of the exchange (only for assistant response extraction)
      property summary : Exchange::ExchangeSummary?

      def initialize(
        @extractions : Array(ExtractedEntry) = [] of ExtractedEntry,
        @summary : Exchange::ExchangeSummary? = nil,
      )
      end

      def empty? : Bool
        extractions.empty? && summary.nil?
      end
    end

    # A single extracted entry
    # Phase 6.2: Enhanced with category, keywords, applies_when, source_file
    class ExtractedEntry
      include JSON::Serializable

      # Entry type: direction, preference, constraint, learning, decision, discovery, guideline, implementation_plan
      @[JSON::Field(key: "type")]
      property entry_type : String

      # The content of the extraction
      property content : String

      # Importance level: high, medium, low
      property importance : String

      # Optional metadata
      property metadata : JSON::Any?

      # Phase 6.2: Category/domain for filtering (e.g., "ruby-style", "rspec")
      property category : String?

      # Phase 6.2: Searchable keywords (nilable for JSON compatibility)
      property keywords : Array(String)?

      # Phase 6.2: When this entry applies
      @[JSON::Field(key: "applies_when")]
      property applies_when : String?

      # Phase 6.2: Source file basename
      @[JSON::Field(key: "source_file")]
      property source_file : String?

      def initialize(
        @entry_type : String,
        @content : String,
        @importance : String = "medium",
        @metadata : JSON::Any? = nil,
        @category : String? = nil,
        @keywords : Array(String)? = nil,
        @applies_when : String? = nil,
        @source_file : String? = nil,
      )
      end

      # Helper to get keywords as non-nil array
      def keywords_array : Array(String)
        keywords || [] of String
      end

      # Convert to Entry
      def to_entry(source : String? = nil) : Entry
        Entry.new(
          entry_type: entry_type,
          content: content,
          importance: importance,
          source: source,
          metadata: metadata,
          category: category,
          keywords: keywords,
          applies_when: applies_when,
          source_file: source_file,
        )
      end

      # Validate the entry type and importance
      def valid? : Bool
        return false unless ENTRY_TYPES.includes?(entry_type)
        return false unless IMPORTANCE_LEVELS.includes?(importance)
        return false if content.empty?
        true
      end
    end

    # Extract user directions from a user prompt
    # Returns extractions for directions, preferences, constraints
    def self.extract_user_directions(prompt : String) : Result
      return Result.new if prompt.strip.empty?

      output = ClaudeCLI.run(
        content: prompt,
        prompt: Prompts.user_prompt_extraction,
      )

      return Result.new if output.nil?

      parse_extraction_result(output)
    end

    # Extract learnings from an assistant response
    # Also generates a summary for the exchange
    def self.extract_assistant_learnings(
      user_message : String,
      assistant_content : String,
    ) : Result
      return Result.new if assistant_content.strip.empty?

      # Build the prompt with context
      full_prompt = Prompts.assistant_response_extraction(user_message)

      output = ClaudeCLI.run(
        content: assistant_content,
        prompt: full_prompt,
      )

      return Result.new if output.nil?

      parse_extraction_result(output, include_summary: true)
    end

    # Extract guidelines from a guideline file
    # Phase 6.2: Passes source_file for auto-keyword generation
    def self.extract_guidelines(file_path : String, content : String) : Result
      return Result.new if content.strip.empty?

      output = ClaudeCLI.run(
        content: content,
        prompt: Prompts.guideline_extraction(file_path),
      )

      return Result.new if output.nil?

      parse_extraction_result(output, source_file: file_path)
    end

    # Extract context from an implementation plan file
    # Phase 6.2: Passes source_file for auto-keyword generation
    def self.extract_implementation_plan(file_path : String, content : String) : Result
      return Result.new if content.strip.empty?

      output = ClaudeCLI.run(
        content: content,
        prompt: Prompts.implementation_plan_extraction(file_path),
      )

      return Result.new if output.nil?

      parse_extraction_result(output, source_file: file_path)
    end

    # Parse the JSON output from Claude CLI
    # Phase 6.2: Enhanced to extract category, keywords, applies_when
    private def self.parse_extraction_result(
      output : String,
      include_summary : Bool = false,
      source_file : String? = nil,
    ) : Result
      begin
        json = JSON.parse(output)

        # Phase 6.2: Auto-extract source file basename
        source_file_basename = source_file.try { |sf| File.basename(sf) }

        # Parse extractions array
        extractions = [] of ExtractedEntry
        if extractions_json = json["extractions"]?.try(&.as_a?)
          extractions_json.each do |entry_json|
            entry_type = entry_json["type"]?.try(&.as_s?) || "learning"
            content = entry_json["content"]?.try(&.as_s?) || ""
            importance = entry_json["importance"]?.try(&.as_s?) || "medium"

            # Phase 6.2: Parse new fields
            category = entry_json["category"]?.try(&.as_s?)
            applies_when = entry_json["applies_when"]?.try(&.as_s?)

            # Parse keywords array
            keywords : Array(String)? = nil
            if keywords_json = entry_json["keywords"]?.try(&.as_a?)
              keywords = keywords_json.compact_map(&.as_s?)
            end

            # Auto-add source file stem to keywords if not already present
            if source_file_basename
              file_stem = source_file_basename.gsub(/\.(md|txt|markdown)$/i, "")
              kw = keywords || [] of String
              kw << file_stem unless kw.includes?(file_stem)
              keywords = kw
            end

            # Skip empty content
            next if content.strip.empty?

            entry = ExtractedEntry.new(
              entry_type: entry_type,
              content: content,
              importance: importance,
              category: category,
              keywords: keywords,
              applies_when: applies_when,
              source_file: source_file_basename,
            )
            extractions << entry if entry.valid?
          end
        end

        # Parse summary if included
        summary : Exchange::ExchangeSummary? = nil
        if include_summary
          if summary_json = json["summary"]?
            user_request = summary_json["user_request"]?.try(&.as_s?) || ""
            assistant_response = summary_json["assistant_response"]?.try(&.as_s?) || ""

            files_modified = [] of String
            if files_array = summary_json["files_modified"]?.try(&.as_a?)
              files_modified = files_array.compact_map(&.as_s?)
            end

            key_actions = [] of String
            if actions_array = summary_json["key_actions"]?.try(&.as_a?)
              key_actions = actions_array.compact_map(&.as_s?)
            end

            unless user_request.empty? && assistant_response.empty?
              summary = Exchange::ExchangeSummary.new(
                user_request: user_request,
                assistant_response: assistant_response,
                files_modified: files_modified,
                key_actions: key_actions,
              )
            end
          end
        end

        Result.new(extractions: extractions, summary: summary)
      rescue ex
        # Parse error - return empty result
        Result.new
      end
    end
  end
end
