require "../spec_helper"

describe GalaxyLedger::Entry do
  describe "#valid?" do
    it "returns true for valid entry" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Test content",
        importance: "medium"
      )
      entry.valid?.should eq(true)
    end

    it "returns false for empty entry_type" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "",
        content: "Test content",
        importance: "medium"
      )
      entry.valid?.should eq(false)
    end

    it "returns false for empty content" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "",
        importance: "medium"
      )
      entry.valid?.should eq(false)
    end

    it "returns false for invalid entry_type" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "invalid_type",
        content: "Test content",
        importance: "medium"
      )
      entry.valid?.should eq(false)
    end

    it "returns false for invalid importance" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Test content",
        importance: "invalid"
      )
      entry.valid?.should eq(false)
    end

    it "returns false for invalid source" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Test content",
        importance: "medium",
        source: "invalid_source"
      )
      entry.valid?.should eq(false)
    end

    it "returns true with valid source 'user'" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "direction",
        content: "Always use double quotes",
        importance: "high",
        source: "user"
      )
      entry.valid?.should eq(true)
    end

    it "returns true with valid source 'assistant'" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "API uses JWT",
        importance: "medium",
        source: "assistant"
      )
      entry.valid?.should eq(true)
    end

    it "returns true with nil source" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "file_read",
        content: "app/models/user.rb",
        importance: "low",
        source: nil
      )
      entry.valid?.should eq(true)
    end
  end

  describe "serialization" do
    it "serializes to JSON" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "decision",
        content: "Use Redis for caching",
        importance: "high",
        source: "assistant",
        created_at: "2026-02-01T10:00:00Z"
      )

      json = entry.to_json
      json.should contain("entry_type")
      json.should contain("decision")
      json.should contain("Use Redis")
      json.should contain("high")
      json.should contain("assistant")
    end

    it "deserializes from JSON" do
      json = %|{
        "entry_type": "learning",
        "content": "Test learning",
        "importance": "medium",
        "source": "assistant",
        "created_at": "2026-02-01T10:00:00Z"
      }|

      entry = GalaxyLedger::Entry.from_json(json)
      entry.entry_type.should eq("learning")
      entry.content.should eq("Test learning")
      entry.importance.should eq("medium")
      entry.source.should eq("assistant")
      entry.created_at.should eq("2026-02-01T10:00:00Z")
    end

    it "handles optional metadata" do
      json = %|{
        "entry_type": "file_edit",
        "content": "app/models/user.rb",
        "importance": "low",
        "created_at": "2026-02-01T10:00:00Z",
        "metadata": {"line_count": 50}
      }|

      entry = GalaxyLedger::Entry.from_json(json)
      entry.metadata.should_not be_nil
      entry.metadata.not_nil!["line_count"].as_i.should eq(50)
    end

    it "handles missing optional fields" do
      json = %|{
        "entry_type": "learning",
        "content": "Test",
        "importance": "medium",
        "created_at": "2026-02-01T10:00:00Z"
      }|

      entry = GalaxyLedger::Entry.from_json(json)
      entry.source.should be_nil
      entry.metadata.should be_nil
    end
  end

  describe "entry types" do
    GalaxyLedger::ENTRY_TYPES.each do |entry_type|
      it "validates entry_type '#{entry_type}'" do
        entry = GalaxyLedger::Entry.new(
          entry_type: entry_type,
          content: "Test",
          importance: "medium"
        )
        entry.valid?.should eq(true)
      end
    end
  end

  describe "importance levels" do
    GalaxyLedger::IMPORTANCE_LEVELS.each do |level|
      it "validates importance '#{level}'" do
        entry = GalaxyLedger::Entry.new(
          entry_type: "learning",
          content: "Test",
          importance: level
        )
        entry.valid?.should eq(true)
      end
    end
  end
end

describe "GalaxyLedger constants" do
  it "ENTRY_TYPES includes expected types" do
    GalaxyLedger::ENTRY_TYPES.should contain("learning")
    GalaxyLedger::ENTRY_TYPES.should contain("decision")
    GalaxyLedger::ENTRY_TYPES.should contain("guideline")
    GalaxyLedger::ENTRY_TYPES.should contain("file_read")
    GalaxyLedger::ENTRY_TYPES.should contain("file_edit")
    GalaxyLedger::ENTRY_TYPES.should contain("file_write")
  end

  it "IMPORTANCE_LEVELS includes expected levels" do
    GalaxyLedger::IMPORTANCE_LEVELS.should eq(["high", "medium", "low"])
  end
end

# ============================================================
# Phase 6.2: Enhanced Schema Tests
# ============================================================

describe "GalaxyLedger::Entry Phase 6.2 Enhanced Schema" do
  describe "Entry with enhanced fields" do
    it "creates entry with category, keywords, applies_when, source_file" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "guideline",
        content: "Always use double-quotes",
        importance: "medium",
        category: "ruby-style",
        keywords: ["ruby", "strings"],
        applies_when: "Writing Ruby code",
        source_file: "ruby-style.md"
      )

      entry.category.should eq("ruby-style")
      entry.keywords.should eq(["ruby", "strings"])
      entry.keywords_array.should eq(["ruby", "strings"])
      entry.applies_when.should eq("Writing Ruby code")
      entry.source_file.should eq("ruby-style.md")
    end

    it "defaults enhanced fields to nil" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Test"
      )

      entry.category.should be_nil
      entry.keywords.should be_nil
      entry.keywords_array.should eq([] of String)
      entry.applies_when.should be_nil
      entry.source_file.should be_nil
    end

    it "keywords_array handles nil keywords" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Test",
        keywords: nil
      )
      entry.keywords_array.should eq([] of String)
    end

    it "remains valid with enhanced fields" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "guideline",
        content: "Test rule",
        importance: "high",
        category: "test",
        keywords: ["key1"],
        applies_when: "Testing",
        source_file: "test.md"
      )
      entry.valid?.should be_true
    end
  end

  describe "Entry serialization with enhanced fields" do
    it "serializes enhanced fields to JSON" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "guideline",
        content: "Test",
        importance: "medium",
        category: "ruby",
        keywords: ["key1", "key2"],
        applies_when: "Testing",
        source_file: "test.md"
      )

      json = entry.to_json
      json.should contain("\"category\":\"ruby\"")
      json.should contain("\"keywords\":[\"key1\",\"key2\"]")
      json.should contain("\"applies_when\":\"Testing\"")
      json.should contain("\"source_file\":\"test.md\"")
    end

    it "deserializes enhanced fields from JSON" do
      json = %|{
        "entry_type": "guideline",
        "content": "Test rule",
        "importance": "medium",
        "created_at": "2026-02-01T10:00:00Z",
        "category": "rspec",
        "keywords": ["testing", "rspec"],
        "applies_when": "Writing specs",
        "source_file": "rspec-style.md"
      }|

      entry = GalaxyLedger::Entry.from_json(json)
      entry.category.should eq("rspec")
      entry.keywords.should eq(["testing", "rspec"])
      entry.applies_when.should eq("Writing specs")
      entry.source_file.should eq("rspec-style.md")
    end

    it "handles missing enhanced fields in JSON" do
      json = %|{
        "entry_type": "learning",
        "content": "Test",
        "importance": "medium",
        "created_at": "2026-02-01T10:00:00Z"
      }|

      entry = GalaxyLedger::Entry.from_json(json)
      entry.category.should be_nil
      entry.keywords.should be_nil
      entry.applies_when.should be_nil
      entry.source_file.should be_nil
    end
  end
end
