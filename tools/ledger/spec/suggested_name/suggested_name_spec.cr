require "../spec_helper"

describe "SuggestedName" do
  # ---------------------------------------------------------------------------
  # StateData
  # ---------------------------------------------------------------------------
  describe "StateData" do
    describe ".from_json_safe" do
      it "returns fresh state for empty string" do
        state = GalaxyLedger::SuggestedName::StateData.from_json_safe("")
        state.attempts.should eq(0)
        state.quality.should eq(0)
        state.finalized.should be_false
        state.status.should eq("")
      end

      it "returns fresh state for empty object" do
        state = GalaxyLedger::SuggestedName::StateData.from_json_safe("{}")
        state.attempts.should eq(0)
        state.quality.should eq(0)
        state.finalized.should be_false
      end

      it "parses valid JSON" do
        json = %({"attempts":2,"quality":3,"finalized":false,"status":"awaiting_improvement","exchange_count":5})
        state = GalaxyLedger::SuggestedName::StateData.from_json_safe(json)
        state.attempts.should eq(2)
        state.quality.should eq(3)
        state.finalized.should be_false
        state.status.should eq("awaiting_improvement")
        state.exchange_count.should eq(5)
      end

      it "returns fresh state for malformed JSON" do
        state = GalaxyLedger::SuggestedName::StateData.from_json_safe("not json{")
        state.attempts.should eq(0)
        state.quality.should eq(0)
        state.finalized.should be_false
      end
    end

    describe "#should_suggest?" do
      it "returns true when not finalized and attempts < max" do
        state = GalaxyLedger::SuggestedName::StateData.new
        state.should_suggest?.should be_true
      end

      it "returns false when finalized" do
        state = GalaxyLedger::SuggestedName::StateData.new
        state.set_name_generated(4, 3)
        state.finalized.should be_true
        state.should_suggest?.should be_false
      end

      it "returns false when max attempts reached" do
        state = GalaxyLedger::SuggestedName::StateData.new
        state.set_name_generated(2, 1)
        state.set_name_generated(2, 2)
        state.set_name_generated(2, 3)
        state.attempts.should eq(3)
        state.should_suggest?.should be_false
      end
    end

    describe "#generation_complete?" do
      it "returns false for fresh state" do
        state = GalaxyLedger::SuggestedName::StateData.new
        state.generation_complete?.should be_false
      end

      it "returns true when finalized" do
        state = GalaxyLedger::SuggestedName::StateData.new
        state.set_name_generated(5, 3)
        state.generation_complete?.should be_true
      end
    end

    describe "#set_needs_more_context" do
      it "sets status without incrementing attempts" do
        state = GalaxyLedger::SuggestedName::StateData.new
        state.set_needs_more_context
        state.status.should eq("needs_more_context")
        state.attempts.should eq(0)
        state.last_attempt_at.should_not be_nil
      end
    end

    describe "#set_code_detected" do
      it "sets status without incrementing attempts" do
        state = GalaxyLedger::SuggestedName::StateData.new
        state.set_code_detected
        state.status.should eq("code_detected")
        state.attempts.should eq(0)
        state.last_attempt_at.should_not be_nil
      end
    end

    describe "#set_name_generated" do
      it "increments attempts" do
        state = GalaxyLedger::SuggestedName::StateData.new
        state.set_name_generated(3, 2)
        state.attempts.should eq(1)
      end

      it "finalizes at quality >= 4" do
        state = GalaxyLedger::SuggestedName::StateData.new
        state.set_name_generated(4, 3)
        state.finalized.should be_true
        state.status.should eq("finalized_quality_met")
        state.quality.should eq(4)
      end

      it "finalizes at max attempts" do
        state = GalaxyLedger::SuggestedName::StateData.new
        state.set_name_generated(2, 1)
        state.set_name_generated(3, 2)
        state.set_name_generated(3, 3)
        state.finalized.should be_true
        state.status.should eq("finalized_max_attempts")
      end

      it "returns true when new quality >= current (should save)" do
        state = GalaxyLedger::SuggestedName::StateData.new
        result = state.set_name_generated(3, 2)
        result.should be_true
      end

      it "returns false when new quality < current (name stability)" do
        state = GalaxyLedger::SuggestedName::StateData.new
        state.set_name_generated(3, 2)
        result = state.set_name_generated(2, 3)
        result.should be_false
        # Quality should NOT be downgraded
        state.quality.should eq(3)
      end

      it "returns true when new quality == current (prefer fresher)" do
        state = GalaxyLedger::SuggestedName::StateData.new
        state.set_name_generated(3, 2)
        result = state.set_name_generated(3, 4)
        result.should be_true
      end

      it "updates exchange_count" do
        state = GalaxyLedger::SuggestedName::StateData.new
        state.set_name_generated(3, 5)
        state.exchange_count.should eq(5)
      end

      it "sets last_attempt_at" do
        state = GalaxyLedger::SuggestedName::StateData.new
        state.set_name_generated(3, 2)
        state.last_attempt_at.should_not be_nil
      end

      it "sets awaiting_improvement when below threshold and attempts remain" do
        state = GalaxyLedger::SuggestedName::StateData.new
        state.set_name_generated(2, 1)
        state.status.should eq("awaiting_improvement")
        state.finalized.should be_false
      end
    end

    describe "JSON serialization round-trip" do
      it "serializes and deserializes correctly" do
        state = GalaxyLedger::SuggestedName::StateData.new
        state.set_name_generated(3, 4)

        json = state.to_json
        restored = GalaxyLedger::SuggestedName::StateData.from_json_safe(json)
        restored.attempts.should eq(1)
        restored.quality.should eq(3)
        restored.exchange_count.should eq(4)
        restored.status.should eq("awaiting_improvement")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # parse_response
  # ---------------------------------------------------------------------------
  describe ".parse_response" do
    it "parses valid name JSON" do
      result = GalaxyLedger::SuggestedName.parse_response(%({"name": "Event System Design", "quality": 4}))
      result.name.should eq("Event System Design")
      result.quality.should eq(4)
      result.needs_more_context.should be_false
    end

    it "parses needs_more_context JSON" do
      result = GalaxyLedger::SuggestedName.parse_response(%({"needs_more_context": true}))
      result.name.should be_nil
      result.needs_more_context.should be_true
    end

    it "returns empty result for nil" do
      result = GalaxyLedger::SuggestedName.parse_response(nil)
      result.name.should be_nil
      result.quality.should eq(0)
      result.needs_more_context.should be_false
    end

    it "returns empty result for empty string" do
      result = GalaxyLedger::SuggestedName.parse_response("")
      result.name.should be_nil
    end

    it "returns empty result for malformed JSON" do
      result = GalaxyLedger::SuggestedName.parse_response("not json{")
      result.name.should be_nil
      result.quality.should eq(0)
    end

    it "strips whitespace from name" do
      result = GalaxyLedger::SuggestedName.parse_response(%({"name": "  Spaced Name  ", "quality": 3}))
      result.name.should eq("Spaced Name")
    end

    it "returns nil name for empty name string" do
      result = GalaxyLedger::SuggestedName.parse_response(%({"name": "", "quality": 3}))
      result.name.should be_nil
    end

    it "defaults quality to 0 when missing" do
      result = GalaxyLedger::SuggestedName.parse_response(%({"name": "Some Name"}))
      result.quality.should eq(0)
    end
  end

  # ---------------------------------------------------------------------------
  # name_appears_to_be_code?
  # ---------------------------------------------------------------------------
  describe ".name_appears_to_be_code?" do
    it "returns false for nil" do
      GalaxyLedger::SuggestedName.name_appears_to_be_code?(nil).should be_false
    end

    it "returns false for empty string" do
      GalaxyLedger::SuggestedName.name_appears_to_be_code?("").should be_false
    end

    it "returns false for clean names" do
      GalaxyLedger::SuggestedName.name_appears_to_be_code?("Event System Design").should be_false
      GalaxyLedger::SuggestedName.name_appears_to_be_code?("Fix Payment Race Condition").should be_false
      GalaxyLedger::SuggestedName.name_appears_to_be_code?("Session Enrichment Data").should be_false
    end

    it "detects code keywords" do
      GalaxyLedger::SuggestedName.name_appears_to_be_code?("def initialize session").should be_true
      GalaxyLedger::SuggestedName.name_appears_to_be_code?("class UserController").should be_true
      GalaxyLedger::SuggestedName.name_appears_to_be_code?("const authMiddleware").should be_true
      GalaxyLedger::SuggestedName.name_appears_to_be_code?("import React from").should be_true
    end

    it "detects code symbols" do
      GalaxyLedger::SuggestedName.name_appears_to_be_code?("{object}").should be_true
      GalaxyLedger::SuggestedName.name_appears_to_be_code?("array[0]").should be_true
      GalaxyLedger::SuggestedName.name_appears_to_be_code?("call();").should be_true
    end

    it "detects file extensions" do
      GalaxyLedger::SuggestedName.name_appears_to_be_code?("user_model.rb").should be_true
      GalaxyLedger::SuggestedName.name_appears_to_be_code?("main.swift").should be_true
    end

    it "detects HTML-like content" do
      GalaxyLedger::SuggestedName.name_appears_to_be_code?("<div class>").should be_true
    end

    it "detects comment-like content" do
      GalaxyLedger::SuggestedName.name_appears_to_be_code?("# comment here").should be_true
      GalaxyLedger::SuggestedName.name_appears_to_be_code?("// comment here").should be_true
    end
  end

  # ---------------------------------------------------------------------------
  # summarize_code_content
  # ---------------------------------------------------------------------------
  describe ".summarize_code_content" do
    it "returns empty for nil" do
      GalaxyLedger::SuggestedName.summarize_code_content(nil).should eq("")
    end

    it "returns empty for empty string" do
      GalaxyLedger::SuggestedName.summarize_code_content("").should eq("")
    end

    it "replaces fenced code blocks" do
      content = "Here is code:\n```ruby\ndef hello; end\n```\nMore text."
      result = GalaxyLedger::SuggestedName.summarize_code_content(content)
      result.should contain("[code block]")
      result.should_not contain("def hello")
    end

    it "replaces inline code" do
      content = "Use the `foo_bar` method to do things"
      result = GalaxyLedger::SuggestedName.summarize_code_content(content)
      result.should contain("[code]")
      result.should_not contain("foo_bar")
    end

    it "truncates long content" do
      long_text = "x" * 1000
      result = GalaxyLedger::SuggestedName.summarize_code_content(long_text)
      result.size.should eq(GalaxyLedger::SuggestedName::MAX_CONTENT_PER_MESSAGE)
    end

    it "returns '[Code shared]' for mostly-code content" do
      code_block = "```\n" + ("def foo; end\n" * 100) + "```"
      content = "Here:\n#{code_block}"
      result = GalaxyLedger::SuggestedName.summarize_code_content(content)
      result.should eq("[Code shared]")
    end
  end

  # ---------------------------------------------------------------------------
  # build_context
  # ---------------------------------------------------------------------------
  describe ".build_context" do
    it "returns empty for no exchanges" do
      context, count = GalaxyLedger::SuggestedName.build_context([] of GalaxyLedger::Transcript::ExtractedExchange)
      context.should eq("")
      count.should eq(0)
    end

    it "formats exchanges correctly" do
      exchanges = [
        GalaxyLedger::Transcript::ExtractedExchange.new(
          user_message: "Add dark mode",
          assistant_entries: [
            GalaxyLedger::Transcript::AssistantEntry.new(content: "I've added dark mode support"),
          ],
        ),
      ]
      context, count = GalaxyLedger::SuggestedName.build_context(exchanges)
      context.should contain("User: Add dark mode")
      context.should contain("Assistant: I've added dark mode support")
      count.should eq(1)
    end

    it "handles multiple exchanges" do
      exchanges = [
        GalaxyLedger::Transcript::ExtractedExchange.new(
          user_message: "First question",
          assistant_entries: [GalaxyLedger::Transcript::AssistantEntry.new(content: "First answer")],
        ),
        GalaxyLedger::Transcript::ExtractedExchange.new(
          user_message: "Second question",
          assistant_entries: [GalaxyLedger::Transcript::AssistantEntry.new(content: "Second answer")],
        ),
      ]
      context, count = GalaxyLedger::SuggestedName.build_context(exchanges)
      context.should contain("First question")
      context.should contain("Second question")
      count.should eq(2)
    end

    it "handles exchange with no assistant response" do
      exchanges = [
        GalaxyLedger::Transcript::ExtractedExchange.new(
          user_message: "A question",
          assistant_entries: [] of GalaxyLedger::Transcript::AssistantEntry,
        ),
      ]
      context, count = GalaxyLedger::SuggestedName.build_context(exchanges)
      context.should contain("User: A question")
      context.should_not contain("Assistant:")
      count.should eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  # suggestion_prompt
  # ---------------------------------------------------------------------------
  describe ".suggestion_prompt" do
    it "returns a non-empty prompt" do
      prompt = GalaxyLedger::SuggestedName.suggestion_prompt
      prompt.should_not be_empty
      prompt.should contain("3-5 words")
      prompt.should contain("quality")
      prompt.should contain("needs_more_context")
    end
  end
end
