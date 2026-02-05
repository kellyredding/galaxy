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

    describe "#to_entry" do
      it "converts to Entry with source" do
        extracted = GalaxyLedger::Extraction::ExtractedEntry.new(
          entry_type: "direction",
          content: "Always use double quotes",
          importance: "high"
        )

        buffer_entry = extracted.to_entry(source: "user")
        buffer_entry.entry_type.should eq("direction")
        buffer_entry.content.should eq("Always use double quotes")
        buffer_entry.importance.should eq("high")
        buffer_entry.source.should eq("user")
      end

      it "converts with enhanced fields" do
        extracted = GalaxyLedger::Extraction::ExtractedEntry.new(
          entry_type: "guideline",
          content: "Test rule",
          importance: "medium",
          category: "ruby-style",
          keywords: ["ruby", "strings"],
          applies_when: "Writing Ruby",
          source_file: "ruby-style.md"
        )

        buffer_entry = extracted.to_entry
        buffer_entry.category.should eq("ruby-style")
        buffer_entry.keywords.should eq(["ruby", "strings"])
        buffer_entry.applies_when.should eq("Writing Ruby")
        buffer_entry.source_file.should eq("ruby-style.md")
      end
    end

    # Phase 6.2: Enhanced schema tests
    describe "Phase 6.2 enhanced fields" do
      it "supports category" do
        entry = GalaxyLedger::Extraction::ExtractedEntry.new(
          entry_type: "guideline",
          content: "Test",
          category: "ruby-style"
        )
        entry.category.should eq("ruby-style")
      end

      it "supports keywords" do
        entry = GalaxyLedger::Extraction::ExtractedEntry.new(
          entry_type: "guideline",
          content: "Test",
          keywords: ["key1", "key2"]
        )
        entry.keywords.should eq(["key1", "key2"])
        entry.keywords_array.should eq(["key1", "key2"])
      end

      it "keywords_array handles nil" do
        entry = GalaxyLedger::Extraction::ExtractedEntry.new(
          entry_type: "guideline",
          content: "Test"
        )
        entry.keywords.should be_nil
        entry.keywords_array.should eq([] of String)
      end

      it "supports applies_when" do
        entry = GalaxyLedger::Extraction::ExtractedEntry.new(
          entry_type: "guideline",
          content: "Test",
          applies_when: "Writing Ruby code"
        )
        entry.applies_when.should eq("Writing Ruby code")
      end

      it "supports source_file" do
        entry = GalaxyLedger::Extraction::ExtractedEntry.new(
          entry_type: "guideline",
          content: "Test",
          source_file: "ruby-style.md"
        )
        entry.source_file.should eq("ruby-style.md")
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
      it "includes file basename in the prompt" do
        file_path = "/path/to/ruby-style.md"
        prompt = GalaxyLedger::Extraction::Prompts.guideline_extraction(file_path)
        prompt.should_not be_empty
        # Phase 6.2: Prompt now uses basename and file stem for category/keywords
        prompt.should contain("ruby-style.md")
        prompt.should contain("ruby-style")
        prompt.should contain("guideline")
        # Should include enhanced schema instructions
        prompt.should contain("category")
        prompt.should contain("keywords")
        prompt.should contain("applies_when")
      end
    end

    describe ".implementation_plan_extraction" do
      it "includes file basename and mentions progress types" do
        file_path = "/path/to/plan.md"
        prompt = GalaxyLedger::Extraction::Prompts.implementation_plan_extraction(file_path)
        prompt.should_not be_empty
        # Phase 6.2: Prompt now uses basename
        prompt.should contain("plan.md")
        prompt.should contain("implementation_plan")
        # Should mention various progress markers (per user feedback)
        prompt.should contain("milestone")
        prompt.should contain("step")
        prompt.should contain("phase")
        prompt.should contain("PR")
        # Should include enhanced schema instructions
        prompt.should contain("category")
        prompt.should contain("keywords")
        prompt.should contain("applies_when")
      end
    end
  end
end
