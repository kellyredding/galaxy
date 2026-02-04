require "../spec_helper"

describe GalaxyLedger::Extraction do
  describe "ExtractedEntry" do
    describe "#valid?" do
      it "validates entry with valid type and importance" do
        entry = GalaxyLedger::Extraction::ExtractedEntry.new(
          entry_type: "direction",
          content: "Always use trailing commas",
          importance: "medium"
        )
        entry.valid?.should be_true
      end

      it "rejects invalid entry type" do
        entry = GalaxyLedger::Extraction::ExtractedEntry.new(
          entry_type: "unknown_type",
          content: "Some content",
          importance: "medium"
        )
        entry.valid?.should be_false
      end

      it "rejects invalid importance level" do
        entry = GalaxyLedger::Extraction::ExtractedEntry.new(
          entry_type: "learning",
          content: "Some content",
          importance: "critical" # Invalid
        )
        entry.valid?.should be_false
      end

      it "rejects empty content" do
        entry = GalaxyLedger::Extraction::ExtractedEntry.new(
          entry_type: "learning",
          content: "",
          importance: "medium"
        )
        entry.valid?.should be_false
      end
    end

    describe "#to_buffer_entry" do
      it "converts to Buffer::Entry with source" do
        extracted = GalaxyLedger::Extraction::ExtractedEntry.new(
          entry_type: "direction",
          content: "Always use double quotes",
          importance: "high"
        )

        buffer_entry = extracted.to_buffer_entry(source: "user")
        buffer_entry.entry_type.should eq("direction")
        buffer_entry.content.should eq("Always use double quotes")
        buffer_entry.importance.should eq("high")
        buffer_entry.source.should eq("user")
      end
    end
  end

  describe "Result" do
    describe "#empty?" do
      it "returns true for empty result" do
        result = GalaxyLedger::Extraction::Result.new
        result.empty?.should be_true
      end

      it "returns false when has extractions" do
        entry = GalaxyLedger::Extraction::ExtractedEntry.new(
          entry_type: "learning",
          content: "Some insight",
          importance: "medium"
        )
        result = GalaxyLedger::Extraction::Result.new(extractions: [entry])
        result.empty?.should be_false
      end

      it "returns false when has summary" do
        summary = GalaxyLedger::Exchange::ExchangeSummary.new(
          user_request: "Test",
          assistant_response: "Response"
        )
        result = GalaxyLedger::Extraction::Result.new(summary: summary)
        result.empty?.should be_false
      end
    end
  end

  describe "Prompts" do
    describe ".user_prompt_extraction" do
      it "returns a non-empty prompt" do
        prompt = GalaxyLedger::Extraction::Prompts.user_prompt_extraction
        prompt.should_not be_empty
        prompt.should contain("direction")
        prompt.should contain("preference")
        prompt.should contain("constraint")
        prompt.should contain("JSON")
      end
    end

    describe ".assistant_response_extraction" do
      it "includes user message in the prompt" do
        user_msg = "Add authentication to the API"
        prompt = GalaxyLedger::Extraction::Prompts.assistant_response_extraction(user_msg)
        prompt.should_not be_empty
        prompt.should contain(user_msg)
        prompt.should contain("learning")
        prompt.should contain("decision")
        prompt.should contain("summary")
      end
    end

    describe ".guideline_extraction" do
      it "includes file path in the prompt" do
        file_path = "/path/to/ruby-style.md"
        prompt = GalaxyLedger::Extraction::Prompts.guideline_extraction(file_path)
        prompt.should_not be_empty
        prompt.should contain(file_path)
        prompt.should contain("guideline")
      end
    end

    describe ".implementation_plan_extraction" do
      it "includes file path and mentions progress types" do
        file_path = "/path/to/plan.md"
        prompt = GalaxyLedger::Extraction::Prompts.implementation_plan_extraction(file_path)
        prompt.should_not be_empty
        prompt.should contain(file_path)
        prompt.should contain("implementation_plan")
        # Should mention various progress markers (per user feedback)
        prompt.should contain("milestone")
        prompt.should contain("step")
        prompt.should contain("phase")
        prompt.should contain("PR")
      end
    end
  end
end
