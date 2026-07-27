require "json"

module GalaxyLedger
  module SuggestedName
    # State machine constants
    MAX_ATTEMPTS              =   3
    QUALITY_THRESHOLD         =   4 # Quality >= 4 auto-finalizes
    MAX_EXCHANGES_FOR_CONTEXT =   5
    MAX_CONTENT_PER_MESSAGE   = 500

    # Bounds of the quality score the suggestion prompt asks for. A spec
    # asserts the prompt still advertises this same range, since the schema
    # rejecting a score the prompt invited would fail a correct answer.
    QUALITY_MIN = 1
    QUALITY_MAX = 5

    # Model for name suggestion one-shots (Haiku — cheap, fast)
    SUGGESTION_MODEL = "haiku"

    # Status values
    STATUS_NEEDS_MORE_CONTEXT   = "needs_more_context"
    STATUS_CODE_DETECTED        = "code_detected"
    STATUS_AWAITING_IMPROVEMENT = "awaiting_improvement"
    STATUS_FINALIZED_QUALITY    = "finalized_quality_met"
    STATUS_FINALIZED_MAX        = "finalized_max_attempts"

    FINAL_STATUSES = [STATUS_FINALIZED_QUALITY, STATUS_FINALIZED_MAX]

    # State data stored in suggested_name_data JSON column
    class StateData
      include JSON::Serializable

      property attempts : Int32 = 0
      property quality : Int32 = 0
      property finalized : Bool = false
      property status : String = ""
      property exchange_count : Int32 = 0
      property last_attempt_at : String? = nil

      def initialize
      end

      def self.from_json_safe(json_str : String) : StateData
        return StateData.new if json_str.empty? || json_str == "{}"
        StateData.from_json(json_str)
      rescue
        StateData.new
      end

      def should_suggest? : Bool
        return false if finalized
        return false if attempts >= MAX_ATTEMPTS
        true
      end

      def generation_complete? : Bool
        finalized || attempts >= MAX_ATTEMPTS
      end

      # Call when LLM returns needs_more_context.
      # Does NOT increment attempts — not a real attempt.
      def set_needs_more_context
        @status = STATUS_NEEDS_MORE_CONTEXT
        @last_attempt_at = Time.utc.to_rfc3339
      end

      # Call when server-side code detection catches a bad name.
      # Does NOT increment attempts — not a real attempt.
      def set_code_detected
        @status = STATUS_CODE_DETECTED
        @last_attempt_at = Time.utc.to_rfc3339
      end

      # Call when a valid name is generated.
      # Returns true if the name should be saved (quality >= current).
      def set_name_generated(new_quality : Int32, exchange_count : Int32) : Bool
        should_save = new_quality >= @quality

        @attempts += 1
        @exchange_count = exchange_count
        @last_attempt_at = Time.utc.to_rfc3339

        if new_quality >= QUALITY_THRESHOLD
          @quality = new_quality if should_save
          @finalized = true
          @status = STATUS_FINALIZED_QUALITY
        elsif @attempts >= MAX_ATTEMPTS
          @quality = new_quality if should_save
          @finalized = true
          @status = STATUS_FINALIZED_MAX
        else
          @quality = new_quality if should_save
          @status = STATUS_AWAITING_IMPROVEMENT
        end

        should_save
      end
    end

    # LLM response shape
    class SuggestionResult
      property name : String?
      property quality : Int32
      property needs_more_context : Bool

      def initialize(
        @name : String? = nil,
        @quality : Int32 = 0,
        @needs_more_context : Bool = false,
      )
      end
    end

    EMPTY_RESULT = SuggestionResult.new

    # Parse the LLM JSON response
    def self.parse_response(response : String?) : SuggestionResult
      return EMPTY_RESULT if response.nil? || response.empty?

      data = JSON.parse(response.strip)

      if data["needs_more_context"]?.try(&.as_bool?)
        SuggestionResult.new(needs_more_context: true)
      else
        SuggestionResult.new(
          name: data["name"]?.try(&.as_s?).try(&.strip).try { |s| s.empty? ? nil : s },
          quality: data["quality"]?.try(&.as_i?) || 0,
        )
      end
    rescue JSON::ParseException
      EMPTY_RESULT
    end

    # Server-side code detection safety net
    CODE_PATTERNS = [
      /^(def|class|module|function|const|let|var|import|export|require)\s/i,
      /^[{\[(<]/,
      /[{}\[\]();]$/,
      /\.(rb|cr|js|ts|py|jsx|tsx|css|html|json|swift)$/i,
      /^<[a-zA-Z]/,
      /^\s*(#|\/\/|\/\*|\*)/,
      /^[a-z_]+\s*[=:]\s*[{(\['"]/i,
      /\b(nil|null|undefined|true|false)\b.*[=:]/,
    ]

    def self.name_appears_to_be_code?(name : String?) : Bool
      return false if name.nil? || name.empty?
      CODE_PATTERNS.any? { |pattern| name.matches?(pattern) }
    end

    # Name suggestion prompt
    def self.suggestion_prompt : String
      <<-PROMPT
      Analyze this Claude Code session conversation and generate a descriptive name.

      RULES:
      1. The name must be 3-5 words that help identify this session in a sidebar list
      2. Focus on the USER'S INTENT, not code or technical details
      3. If the conversation is about code, describe WHAT they're trying to accomplish
      4. Use title case
      5. Quality score meaning: 1=very generic, 2=somewhat generic, 3=acceptable, 4=good, 5=excellent

      QUALITY SCORE REQUIREMENTS:
      - If the conversation has fewer than 3 substantive exchanges, the maximum quality score is 3 (acceptable)
      - Score 4 (good) or 5 (excellent) requires at least 3 substantive exchanges
      - Substantive exchanges have specific questions, tasks, or technical content
      - Generic exchanges do NOT count: greetings, "where were we?", context handoff/restoration messages, vague requests

      CRITICAL - NEVER INCLUDE CODE IN NAMES:
      - Never include code snippets, syntax, or code-like text
      - Never include function names, method names, class names, or variable names
      - Never include file names, file extensions, or file paths
      - Never include programming keywords (def, class, function, const, let, var, import, etc.)
      - Never include symbols commonly used in code ({, }, [, ], (, ), ;, =>, ->, etc.)
      - Never include technical identifiers (snake_case, camelCase, PascalCase names)

      CRITICAL - RETURN "needs_more_context" FOR NON-SUBSTANTIVE CONVERSATIONS:
      Return {"needs_more_context": true} when the conversation consists only of:
      - Context restoration or handoff messages (system-injected session context)
      - Vague catch-up questions ("where were we?", "what were we working on?")
      - Generic requests ("I need some help", "I have a question")
      - Any conversation that lacks a clear, specific topic or goal

      Wait for substantive content before generating a name. A good name requires:
      - A specific question, task, or problem from the user
      - Enough context to understand what the user is trying to accomplish

      Good names: "Session Enrichment Data", "Fix Payment Race Condition", "Event System Socket Infrastructure"
      Bad names: "const authMiddleware", "fix bug", "help with code", "Code Review", "Working on Project"

      EXAMPLES:
      - User asks about implementing a feature (1-2 exchanges) → {"name": "Add User Authentication", "quality": 3}
      - User only has restoration context → {"needs_more_context": true}
      - User says "where were we?" → {"needs_more_context": true}
      - 3+ substantive exchanges about refactoring → {"name": "Refactor Payment Processing", "quality": 4}
      - 4+ exchanges deep into a specific system → {"name": "Galaxy Event System Design", "quality": 5}

      Respond ONLY with a JSON object in one of these formats:

      When you can generate a meaningful, specific name:
      {"name": "Your 3-5 Word Name", "quality": 1-5}

      When the conversation lacks specific content:
      {"needs_more_context": true}

      Respond ONLY with the JSON object. No other text.
      PROMPT
    end

    # JSON Schema constraining a suggestion response. The prompt offers two
    # shapes — a name with its quality score, or a request for more context —
    # and the natural expression of that is a oneOf union.
    #
    # A union is not available here. The CLI forwards --json-schema as a
    # tool's input_schema, which requires a top-level "type" and rejects
    # oneOf, allOf and anyOf at the root:
    #
    #   input_schema does not support oneOf, allOf, or anyOf at the top level
    #
    # Nesting the union under a wrapper property would satisfy that, at the
    # cost of changing the response shape the prompt describes and the parser
    # reads. Not worth it for what the union adds, so the schema declares
    # every field the two shapes use and leaves all of them optional.
    #
    # What this enforces: the reply is a JSON object, carries no keys beyond
    # these three, spells them correctly, and gives each the right type — a
    # non-empty name, a quality score within the advertised range.
    #
    # What it does not enforce: that a complete shape is present. An empty
    # object satisfies it, as does a name with no score. Both degrade the
    # same way they always have — the parser reads a missing score as zero
    # and a missing name as no suggestion — so the state machine's retry
    # budget remains the backstop for a reply that validates but says nothing.
    #
    # needs_more_context stays a plain boolean rather than being pinned to
    # true. Pinning made sense while the union kept false unreachable; in a
    # flat schema a reply pairing a name with an explicit false would fail
    # validation outright, losing a usable answer over a redundant field.
    def self.suggestion_schema : String
      <<-JSON
      {
        "type": "object",
        "properties": {
          "name": { "type": "string", "minLength": 1 },
          "quality": {
            "type": "integer",
            "minimum": #{QUALITY_MIN},
            "maximum": #{QUALITY_MAX}
          },
          "needs_more_context": { "type": "boolean" }
        },
        "additionalProperties": false
      }
      JSON
    end

    # Summarize code-heavy content before sending to LLM
    def self.summarize_code_content(content : String?) : String
      return "" if content.nil? || content.empty?

      # Replace fenced code blocks with placeholder
      summarized = content.gsub(/```[\s\S]*?```/, "[code block]")
      # Replace inline code with placeholder
      summarized = summarized.gsub(/`[^`]+`/, "[code]")

      if content_is_mostly_code?(content)
        "[Code shared]"
      else
        summarized.size > MAX_CONTENT_PER_MESSAGE ? summarized[0, MAX_CONTENT_PER_MESSAGE] : summarized
      end
    end

    private def self.content_is_mostly_code?(content : String) : Bool
      return false if content.empty?

      code_pattern = /```[\s\S]*?```|`[^`]+`/
      code_matches = content.scan(code_pattern)
      code_content_length = code_matches.sum { |m| m[0].size }
      code_ratio = code_content_length.to_f / content.size

      code_ratio > 0.7
    end

    # Build conversation context string from recent exchanges.
    # Returns {context_string, exchange_count}.
    def self.build_context(exchanges : Array(Transcript::ExtractedExchange)) : {String, Int32}
      return {"", 0} if exchanges.empty?

      context_parts = [] of String
      exchanges.each do |exchange|
        user_content = summarize_code_content(exchange.user_message)
        assistant_content = summarize_code_content(exchange.combined_content)

        context_parts << "User: #{user_content}"
        context_parts << "Assistant: #{assistant_content}" unless assistant_content.empty?
      end

      {context_parts.join("\n\n"), exchanges.size}
    end
  end
end
