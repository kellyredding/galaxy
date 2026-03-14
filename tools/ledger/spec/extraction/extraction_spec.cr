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
          entry_type: "constraint",
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

    describe "enhanced schema fields" do
      it "supports category" do
        entry = GalaxyLedger::Extraction::ExtractedEntry.new(
          entry_type: "constraint",
          content: "Test",
          category: "ruby-style"
        )
        entry.category.should eq("ruby-style")
      end

      it "supports keywords" do
        entry = GalaxyLedger::Extraction::ExtractedEntry.new(
          entry_type: "constraint",
          content: "Test",
          keywords: ["key1", "key2"]
        )
        entry.keywords.should eq(["key1", "key2"])
        entry.keywords_array.should eq(["key1", "key2"])
      end

      it "keywords_array handles nil" do
        entry = GalaxyLedger::Extraction::ExtractedEntry.new(
          entry_type: "constraint",
          content: "Test"
        )
        entry.keywords.should be_nil
        entry.keywords_array.should eq([] of String)
      end

      it "supports applies_when" do
        entry = GalaxyLedger::Extraction::ExtractedEntry.new(
          entry_type: "constraint",
          content: "Test",
          applies_when: "Writing Ruby code"
        )
        entry.applies_when.should eq("Writing Ruby code")
      end

      it "supports source_file" do
        entry = GalaxyLedger::Extraction::ExtractedEntry.new(
          entry_type: "constraint",
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

      it "returns true when has only usage data (usage alone is not content)" do
        result = GalaxyLedger::Extraction::Result.new(cost_usd: 5.0, total_tokens: 10000_i64)
        result.empty?.should be_true
      end
    end

    describe "usage fields" do
      it "defaults cost_usd to 0.0" do
        result = GalaxyLedger::Extraction::Result.new
        result.cost_usd.should eq(0.0)
      end

      it "defaults total_tokens to 0" do
        result = GalaxyLedger::Extraction::Result.new
        result.total_tokens.should eq(0_i64)
      end

      it "stores cost_usd when provided" do
        result = GalaxyLedger::Extraction::Result.new(cost_usd: 0.128)
        result.cost_usd.should eq(0.128)
      end

      it "stores total_tokens when provided" do
        result = GalaxyLedger::Extraction::Result.new(total_tokens: 34752_i64)
        result.total_tokens.should eq(34752_i64)
      end

      it "cost_usd and total_tokens are settable via property" do
        result = GalaxyLedger::Extraction::Result.new
        result.cost_usd = 1.50
        result.total_tokens = 25000_i64
        result.cost_usd.should eq(1.50)
        result.total_tokens.should eq(25000_i64)
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

      it "does not include session_title in the output format" do
        prompt = GalaxyLedger::Extraction::Prompts.assistant_response_extraction("test")
        prompt.should_not contain("session_title")
      end
    end
  end
end
