require "../spec_helper"

describe GalaxyLedger::SuggestedName do
  describe ".suggestion_schema" do
    it "produces valid JSON" do
      JSON.parse(GalaxyLedger::SuggestedName.suggestion_schema).should be_truthy
    end

    # The CLI forwards the schema as a tool input_schema, which requires a
    # top-level type and rejects oneOf/allOf/anyOf at the root. A union added
    # here would be refused by the API at call time, not at compile time.
    it "declares an object at the root" do
      schema = JSON.parse(GalaxyLedger::SuggestedName.suggestion_schema)

      schema["type"].as_s.should eq("object")
    end

    it "uses no top-level combinator" do
      schema = JSON.parse(GalaxyLedger::SuggestedName.suggestion_schema).as_h

      schema.keys.should_not contain("oneOf")
      schema.keys.should_not contain("anyOf")
      schema.keys.should_not contain("allOf")
    end

    it "allows only the keys the two response shapes use" do
      schema = JSON.parse(GalaxyLedger::SuggestedName.suggestion_schema)

      schema["properties"].as_h.keys.sort.should eq(
        ["name", "needs_more_context", "quality"]
      )
      schema["additionalProperties"].as_bool.should be_false
    end

    it "requires nothing, since either shape may be absent" do
      schema = JSON.parse(GalaxyLedger::SuggestedName.suggestion_schema).as_h

      schema.keys.should_not contain("required")
    end

    it "bounds quality to the advertised range" do
      quality = JSON.parse(
        GalaxyLedger::SuggestedName.suggestion_schema
      )["properties"]["quality"]

      quality["type"].as_s.should eq("integer")
      quality["minimum"].as_i.should eq(GalaxyLedger::SuggestedName::QUALITY_MIN)
      quality["maximum"].as_i.should eq(GalaxyLedger::SuggestedName::QUALITY_MAX)
    end

    it "rejects an empty name" do
      name = JSON.parse(
        GalaxyLedger::SuggestedName.suggestion_schema
      )["properties"]["name"]

      name["type"].as_s.should eq("string")
      name["minLength"].as_i.should eq(1)
    end

    # Pinning to true would fail a reply that pairs a name with an explicit
    # false, which is redundant but usable.
    it "leaves needs_more_context an unpinned boolean" do
      field = JSON.parse(
        GalaxyLedger::SuggestedName.suggestion_schema
      )["properties"]["needs_more_context"].as_h

      field["type"].as_s.should eq("boolean")
      field.keys.should_not contain("enum")
      field.keys.should_not contain("const")
    end
  end

  # The schema and the prompt describe the same contract from different
  # files, so nothing but a spec keeps them agreeing.
  describe "schema and prompt agreement" do
    it "advertises the same quality range the schema enforces" do
      prompt = GalaxyLedger::SuggestedName.suggestion_prompt

      prompt.should contain(
        "#{GalaxyLedger::SuggestedName::QUALITY_MIN}-" \
        "#{GalaxyLedger::SuggestedName::QUALITY_MAX}"
      )
    end

    it "names every key the schema permits" do
      prompt = GalaxyLedger::SuggestedName.suggestion_prompt
      keys = JSON.parse(
        GalaxyLedger::SuggestedName.suggestion_schema
      )["properties"].as_h.keys

      keys.each { |key| prompt.should contain(key) }
    end
  end

  # A response carrying the schema's exact shapes must survive the parser.
  describe "parse_response against schema-shaped replies" do
    it "reads the naming shape" do
      result = GalaxyLedger::SuggestedName.parse_response(
        %({"name":"Fix Payment Webhook Race","quality":4})
      )

      result.needs_more_context.should be_false
      result.name.should eq("Fix Payment Webhook Race")
      result.quality.should eq(4)
    end

    it "reads the more-context shape" do
      result = GalaxyLedger::SuggestedName.parse_response(
        %({"needs_more_context":true})
      )

      result.needs_more_context.should be_true
      result.name.should be_nil
    end

    it "treats an explicit false as a naming reply" do
      result = GalaxyLedger::SuggestedName.parse_response(
        %({"name":"Some Session Name","quality":3,"needs_more_context":false})
      )

      result.needs_more_context.should be_false
      result.name.should eq("Some Session Name")
      result.quality.should eq(3)
    end
  end
end
