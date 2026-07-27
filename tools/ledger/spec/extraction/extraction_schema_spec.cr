require "../spec_helper"

describe GalaxyLedger::Extraction do
  describe ".extraction_schema" do
    it "produces valid JSON" do
      schema = GalaxyLedger::Extraction.extraction_schema(
        GalaxyLedger::Extraction::ASSISTANT_ENTRY_TYPES
      )

      JSON.parse(schema).should be_truthy
    end

    it "requires the extractions envelope" do
      schema = JSON.parse(
        GalaxyLedger::Extraction.extraction_schema(
          GalaxyLedger::Extraction::ASSISTANT_ENTRY_TYPES
        )
      )

      schema["required"].as_a.map(&.as_s).should eq(["extractions"])
      schema["properties"]["extractions"]["type"].as_s.should eq("array")
    end

    it "requires type, content and importance on every entry" do
      schema = JSON.parse(
        GalaxyLedger::Extraction.extraction_schema(
          GalaxyLedger::Extraction::ASSISTANT_ENTRY_TYPES
        )
      )
      items = schema["properties"]["extractions"]["items"]

      items["required"].as_a.map(&.as_s).should eq(
        ["type", "content", "importance"]
      )
    end

    it "constrains the entry type to the types it was given" do
      schema = JSON.parse(
        GalaxyLedger::Extraction.extraction_schema(["direction"])
      )
      items = schema["properties"]["extractions"]["items"]

      items["properties"]["type"]["enum"].as_a.map(&.as_s).should eq(
        ["direction"]
      )
    end

    it "constrains importance to the known levels" do
      schema = JSON.parse(
        GalaxyLedger::Extraction.extraction_schema(["direction"])
      )
      items = schema["properties"]["extractions"]["items"]

      items["properties"]["importance"]["enum"].as_a.map(&.as_s).should eq(
        GalaxyLedger::Extraction::IMPORTANCE_LEVELS
      )
    end
  end

  # A type the prompt invites but the schema rejects turns a correct answer
  # into a validation failure, and the two live in different files, so
  # nothing but a spec keeps them in step.
  describe "schema and prompt agreement" do
    it "offers every assistant entry type in the assistant prompt" do
      prompt = GalaxyLedger::Extraction::Prompts
        .assistant_response_extraction("some message")

      GalaxyLedger::Extraction::ASSISTANT_ENTRY_TYPES.each do |entry_type|
        prompt.should contain(entry_type)
      end
    end

    it "offers every user entry type in the user prompt" do
      prompt = GalaxyLedger::Extraction::Prompts.user_prompt_extraction

      GalaxyLedger::Extraction::USER_ENTRY_TYPES.each do |entry_type|
        prompt.should contain(entry_type)
      end
    end

    it "offers every importance level in both prompts" do
      prompts = [
        GalaxyLedger::Extraction::Prompts
          .assistant_response_extraction("some message"),
        GalaxyLedger::Extraction::Prompts.user_prompt_extraction,
      ]

      prompts.each do |prompt|
        GalaxyLedger::Extraction::IMPORTANCE_LEVELS.each do |level|
          prompt.should contain(level)
        end
      end
    end
  end
end
