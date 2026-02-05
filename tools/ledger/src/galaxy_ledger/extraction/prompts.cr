module GalaxyLedger
  module Extraction
    # Extraction prompts for Claude CLI one-shot calls
    module Prompts
      # Prompt for extracting user directions from a user message
      def self.user_prompt_extraction : String
        <<-PROMPT
        You are extracting durable directions and preferences from a user message in Claude Code.

        ## Extract ONLY:
        - **Directions**: Explicit instructions that should persist ("always X", "never Y", "use X instead of Y")
        - **Preferences**: Stated preferences about style, approach, or conventions
        - **Constraints**: Limitations or requirements ("don't modify X", "must use Y")

        ## Do NOT extract:
        - Questions or requests for information
        - Brainstorming or exploration without decisions
        - Acknowledgments ("yes", "ok", "continue", "sounds good", "that looks good")
        - One-time instructions for the current task only (e.g., "add a comment here" is one-time; "always add comments for complex logic" is durable)
        - Standard language/framework conventions that any developer would know

        ## Importance levels:
        - **high**: Security requirements, architectural constraints, explicit "always/never" rules
        - **medium**: Style preferences, approach choices, tool preferences
        - **low**: Minor preferences, soft suggestions

        ## Output format (JSON only, no markdown):
        {
          "extractions": [
            {
              "type": "direction|preference|constraint",
              "content": "Brief, actionable description",
              "importance": "high|medium|low"
            }
          ]
        }

        Return empty extractions array if nothing significant. Quality over quantity.
        Output ONLY valid JSON, no explanation or markdown.
        PROMPT
      end

      # Prompt for extracting learnings from an assistant response
      def self.assistant_response_extraction(user_message : String) : String
        <<-PROMPT
        You are extracting key information from a Claude Code assistant response.

        ## Extract from the assistant response:

        - **Learnings**: Insights about how the codebase works (architecture, patterns, how components connect)
        - **Discoveries**: Specific technical facts encountered (deprecated APIs, version requirements, config values, gotchas)
        - **Decisions**: Choices made between alternatives, with the rationale

        ## Do NOT extract:
        - Standard programming knowledge any professional developer knows
        - Temporary states ("I'm reading the file now", "Let me check...")
        - Speculative options that weren't chosen
        - Framework conventions documented in official guides

        ## Importance levels:

        For **learnings/discoveries**:
        - **high**: Critical for understanding the codebase, affects multiple features
        - **medium**: Useful context, affects the current feature area
        - **low**: Minor detail, nice to know

        For **decisions**:
        - **high**: Affects multiple files, hard to reverse, security/architecture implications
        - **medium**: Meaningful choice but localized impact
        - **low**: Minor implementation detail

        ## Summary guidelines:
        - Keep descriptions to 1-2 sentences
        - Don't include diffs, full code blocks, or large artifacts
        - Focus on what was accomplished, not the process
        - For multi-step exchanges, capture the final outcome

        ## Output format (JSON only, no markdown):
        {
          "summary": {
            "user_request": "What the user asked for",
            "assistant_response": "What was accomplished (1-2 sentences)",
            "files_modified": ["only files that were edited/written, not read"],
            "key_actions": ["significant action 1", "significant action 2"]
          },
          "extractions": [
            {
              "type": "learning|discovery|decision",
              "content": "Brief, actionable description",
              "importance": "high|medium|low"
            }
          ]
        }

        Return empty extractions array if nothing significant. Quality over quantity.
        Output ONLY valid JSON, no explanation or markdown.

        User message (for context):
        #{user_message}
        PROMPT
      end

      # Prompt for extracting rules from a guideline file
      # Phase 6.2: Enhanced schema with category, keywords, applies_when
      def self.guideline_extraction(file_path : String) : String
        # Extract category from file name (e.g., "ruby-style.md" -> "ruby-style")
        file_basename = File.basename(file_path)
        file_stem = file_basename.gsub(/\.(md|txt|markdown)$/i, "")

        <<-PROMPT
        This is a guideline file for coding conventions.
        File: #{file_basename}

        ## Extract actionable rules and patterns:
        - Code style rules
        - Testing patterns
        - Naming conventions
        - Architecture guidelines

        ## Prioritize rules that:
        - Differ from common language/framework conventions
        - Are specific to this codebase or project
        - Relate to patterns unique to the project's architecture

        ## For conditional rules:
        Keep the full condition together as a single extraction rather than splitting:
        - Good: "Use let! for database records; use let for simple values"
        - Bad: Splitting into "Use let!" and "Use let for simple values" (loses context)

        ## Category inference:
        Based on the file name "#{file_stem}", infer a category for all extractions.
        Examples: "ruby-style", "rspec", "git-workflow", "testing", "architecture"

        ## Keywords:
        For each extraction, generate 3-5 searchable keywords that would help find this rule.
        Include the file stem "#{file_stem}" and related technology/concept keywords.
        Example for a Ruby string quote rule: ["ruby-style", "strings", "quotes", "ruby", "formatting"]

        ## Applies when:
        Describe when this rule should be applied (e.g., "Writing Ruby code", "Writing RSpec tests")

        ## Importance levels:
        - **high**: Rules that differ significantly from defaults, security-related, architectural
        - **medium**: Style preferences, testing patterns, naming conventions
        - **low**: Minor preferences, edge case handling

        ## Output format (JSON only, no markdown):
        {
          "extractions": [
            {
              "type": "guideline",
              "content": "Brief, actionable rule",
              "importance": "high|medium|low",
              "category": "#{file_stem}",
              "keywords": ["keyword1", "keyword2", "keyword3"],
              "applies_when": "When writing/reviewing X code"
            }
          ]
        }

        Focus on rules that are specific and actionable, not general descriptions.
        Output ONLY valid JSON, no explanation or markdown.
        PROMPT
      end

      # Prompt for extracting context from an implementation plan file
      # Phase 6.2: Enhanced schema with category, keywords, applies_when
      def self.implementation_plan_extraction(file_path : String) : String
        # Extract category from file name
        file_basename = File.basename(file_path)
        file_stem = file_basename.gsub(/\.(md|txt|markdown)$/i, "")

        <<-PROMPT
        This is an implementation plan for a multi-step development effort.
        File: #{file_basename}

        ## Extract key context:
        - Overall goal/purpose of the effort
        - Current progress status (what milestones/steps/phases/PRs are complete, what's the current focus, what's next)
        - Key architectural decisions already made
        - Important constraints or requirements
        - Dependencies between steps/phases/PRs

        ## Prioritize information that:
        - Helps an agent understand where they are in the larger effort
        - Captures decisions that affect future work
        - Notes implementation details that future steps depend on

        ## Category inference:
        Infer a category based on the project/feature being implemented.
        Use the file stem "#{file_stem}" or extract from the plan title.
        Examples: "galaxy-ledger", "authentication", "api-v2", "performance"

        ## Keywords:
        For each extraction, generate 3-5 searchable keywords.
        Include the project name, technologies, and key concepts.
        Example: ["galaxy-ledger", "phase-6", "extraction", "sqlite", "context"]

        ## Applies when:
        Describe when this context is relevant (e.g., "Working on Galaxy Ledger", "Implementing Phase 6")

        ## Importance levels:
        - **high**: Progress status, blocking dependencies, architectural decisions
        - **medium**: Implementation details, design rationale
        - **low**: Minor notes, future considerations

        ## Output format (JSON only, no markdown):
        {
          "extractions": [
            {
              "type": "implementation_plan",
              "content": "Brief, contextual information",
              "importance": "high|medium|low",
              "category": "project-name",
              "keywords": ["keyword1", "keyword2", "keyword3"],
              "applies_when": "Working on X feature/project"
            }
          ]
        }

        Focus on context that helps maintain continuity across sessions.
        Output ONLY valid JSON, no explanation or markdown.
        PROMPT
      end
    end
  end
end
