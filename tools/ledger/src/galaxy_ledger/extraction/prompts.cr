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
        - assistant_response: 2-4 sentences. What was accomplished AND
          the approach taken. Include reasoning, not just outcomes.
        - decisions: For each meaningful choice made, capture what was
          chosen, why, and what alternatives were considered (if any).
          Only include non-trivial decisions — skip obvious choices.
        - learnings: Insights about how the codebase works, gotchas
          encountered, or technical facts that would help a future
          agent working in the same area.
        - Don't include diffs, full code blocks, or large artifacts.
        - For multi-step exchanges, capture the final outcome and the
          key intermediate decisions.

        ## Output format (JSON only, no markdown):
        {
          "summary": {
            "user_request": "What the user asked for",
            "assistant_response": "2-4 sentences: what was accomplished and the approach/reasoning",
            "files_modified": ["only files that were edited/written, not read"],
            "key_actions": ["significant action 1", "significant action 2"],
            "decisions": [
              {
                "choice": "What was chosen",
                "rationale": "Why this approach",
                "alternatives": "What else was considered (optional, omit if none)"
              }
            ],
            "learnings": [
              "Insight about codebase or technical fact discovered"
            ]
          },
          "extractions": [
            {
              "type": "learning|discovery|decision",
              "content": "Brief, actionable description",
              "importance": "high|medium|low"
            }
          ]
        }

        Return empty arrays for decisions/learnings/extractions if nothing significant. Quality over quantity.
        Output ONLY valid JSON, no explanation or markdown.

        User message (for context):
        #{user_message}
        PROMPT
      end
    end
  end
end
