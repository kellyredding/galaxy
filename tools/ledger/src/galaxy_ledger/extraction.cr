require "json"
require "./extraction/*"

module GalaxyLedger
  # Handles Claude CLI one-shot calls to extract learnings, directions, and summaries
  module Extraction
    # Hard-coded model for all extraction one-shots (Sonnet).
    # Ensures deterministic extraction quality regardless of user's default model.
    EXTRACTION_MODEL = "sonnet"

    # Result of an extraction operation
    class Result
      include JSON::Serializable

      # Extracted entries (learnings, decisions, directions, etc.)
      property extractions : Array(ExtractedEntry)

      # Summary of the exchange (only for assistant response extraction)
      property summary : Exchange::ExchangeSummary?

      # One-shot cost in USD from the Claude CLI call
      property cost_usd : Float64

      # Total tokens consumed by the one-shot (sum of all token types)
      property total_tokens : Int64

      def initialize(
        @extractions : Array(ExtractedEntry) = [] of ExtractedEntry,
        @summary : Exchange::ExchangeSummary? = nil,
        @cost_usd : Float64 = 0.0,
        @total_tokens : Int64 = 0_i64,
      )
      end

      def empty? : Bool
        extractions.empty? && summary.nil?
      end
    end

    # A single extracted entry
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

      # Category/domain for filtering (e.g., "ruby-style", "rspec")
      property category : String?

      # Searchable keywords (nilable for JSON compatibility)
      property keywords : Array(String)?

      # When this entry applies
      @[JSON::Field(key: "applies_when")]
      property applies_when : String?

      # Source file path (full path for extracted guideline/implementation_plan entries)
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

      run_result = ClaudeCLI.run(
        content: prompt,
        prompt: Prompts.user_prompt_extraction,
        model: EXTRACTION_MODEL,
      )

      return Result.new if run_result[:result].nil?

      result = parse_extraction_result(run_result[:result].not_nil!)
      apply_usage(result, run_result)
      result
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

      run_result = ClaudeCLI.run(
        content: assistant_content,
        prompt: full_prompt,
        model: EXTRACTION_MODEL,
      )

      return Result.new if run_result[:result].nil?

      result = parse_extraction_result(run_result[:result].not_nil!, include_summary: true)
      apply_usage(result, run_result)
      result
    end

    # Apply usage data from a ClaudeCLI RunResult to an extraction Result
    private def self.apply_usage(result : Result, run_result : ClaudeCLI::RunResult)
      result.cost_usd = run_result[:cost_usd]
      result.total_tokens = run_result[:input_tokens] +
                            run_result[:output_tokens] +
                            run_result[:cache_creation_tokens] +
                            run_result[:cache_read_tokens]
    end

    # Parse the JSON output from Claude CLI
    private def self.parse_extraction_result(
      output : String,
      include_summary : Bool = false,
      source_file : String? = nil,
    ) : Result
      begin
        json = JSON.parse(output)

        # Use source file path as-is (full path) for entries
        source_file_path = source_file

        # Parse extractions array
        extractions = [] of ExtractedEntry
        if extractions_json = json["extractions"]?.try(&.as_a?)
          extractions_json.each do |entry_json|
            entry_type = entry_json["type"]?.try(&.as_s?) || "learning"
            content = entry_json["content"]?.try(&.as_s?) || ""
            importance = entry_json["importance"]?.try(&.as_s?) || "medium"

            # Parse enhanced schema fields
            category = entry_json["category"]?.try(&.as_s?)
            applies_when = entry_json["applies_when"]?.try(&.as_s?)

            # Parse keywords array
            keywords : Array(String)? = nil
            if keywords_json = entry_json["keywords"]?.try(&.as_a?)
              keywords = keywords_json.compact_map(&.as_s?)
            end

            # Auto-add source file stem to keywords if not already present
            if source_file_path
              file_stem = File.basename(source_file_path).gsub(/\.(md|txt|markdown)$/i, "")
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
              source_file: source_file_path,
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

            decisions : Array(Exchange::ExchangeDecision)? = nil
            if decisions_array = summary_json["decisions"]?.try(&.as_a?)
              parsed_decisions = decisions_array.compact_map do |d|
                next nil unless d.as_h?
                choice = d["choice"]?.try(&.as_s?) || ""
                rationale = d["rationale"]?.try(&.as_s?) || ""
                next nil if choice.empty? && rationale.empty?
                alternatives = d["alternatives"]?.try(&.as_s?)
                Exchange::ExchangeDecision.new(
                  choice: choice,
                  rationale: rationale,
                  alternatives: alternatives,
                )
              end
              decisions = parsed_decisions unless parsed_decisions.empty?
            end

            learnings : Array(String)? = nil
            if learnings_array = summary_json["learnings"]?.try(&.as_a?)
              parsed_learnings = learnings_array.compact_map(&.as_s?).reject(&.empty?)
              learnings = parsed_learnings unless parsed_learnings.empty?
            end

            unless user_request.empty? && assistant_response.empty?
              summary = Exchange::ExchangeSummary.new(
                user_request: user_request,
                assistant_response: assistant_response,
                files_modified: files_modified,
                key_actions: key_actions,
                decisions: decisions,
                learnings: learnings,
              )
            end
          end
        end

        Result.new(extractions: extractions, summary: summary)
      rescue ex
        STDERR.puts "[galaxy-ledger] Extraction parse error: #{ex.message}"
        Result.new
      end
    end
  end
end
