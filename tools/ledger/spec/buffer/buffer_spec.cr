require "../spec_helper"

describe GalaxyLedger::Buffer do
  describe "Entry" do
    describe "#valid?" do
      it "returns true for valid entry" do
        entry = GalaxyLedger::Buffer::Entry.new(
          entry_type: "learning",
          content: "Test content",
          importance: "medium"
        )
        entry.valid?.should eq(true)
      end

      it "returns false for empty entry_type" do
        entry = GalaxyLedger::Buffer::Entry.new(
          entry_type: "",
          content: "Test content",
          importance: "medium"
        )
        entry.valid?.should eq(false)
      end

      it "returns false for empty content" do
        entry = GalaxyLedger::Buffer::Entry.new(
          entry_type: "learning",
          content: "",
          importance: "medium"
        )
        entry.valid?.should eq(false)
      end

      it "returns false for invalid entry_type" do
        entry = GalaxyLedger::Buffer::Entry.new(
          entry_type: "invalid_type",
          content: "Test content",
          importance: "medium"
        )
        entry.valid?.should eq(false)
      end

      it "returns false for invalid importance" do
        entry = GalaxyLedger::Buffer::Entry.new(
          entry_type: "learning",
          content: "Test content",
          importance: "invalid"
        )
        entry.valid?.should eq(false)
      end

      it "returns false for invalid source" do
        entry = GalaxyLedger::Buffer::Entry.new(
          entry_type: "learning",
          content: "Test content",
          importance: "medium",
          source: "invalid_source"
        )
        entry.valid?.should eq(false)
      end

      it "returns true with valid source 'user'" do
        entry = GalaxyLedger::Buffer::Entry.new(
          entry_type: "direction",
          content: "Always use double quotes",
          importance: "high",
          source: "user"
        )
        entry.valid?.should eq(true)
      end

      it "returns true with valid source 'assistant'" do
        entry = GalaxyLedger::Buffer::Entry.new(
          entry_type: "learning",
          content: "API uses JWT",
          importance: "medium",
          source: "assistant"
        )
        entry.valid?.should eq(true)
      end

      it "returns true with nil source" do
        entry = GalaxyLedger::Buffer::Entry.new(
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
        entry = GalaxyLedger::Buffer::Entry.new(
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

        entry = GalaxyLedger::Buffer::Entry.from_json(json)
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

        entry = GalaxyLedger::Buffer::Entry.from_json(json)
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

        entry = GalaxyLedger::Buffer::Entry.from_json(json)
        entry.source.should be_nil
        entry.metadata.should be_nil
      end
    end

    describe "entry types" do
      GalaxyLedger::Buffer::ENTRY_TYPES.each do |entry_type|
        it "validates entry_type '#{entry_type}'" do
          entry = GalaxyLedger::Buffer::Entry.new(
            entry_type: entry_type,
            content: "Test",
            importance: "medium"
          )
          entry.valid?.should eq(true)
        end
      end
    end

    describe "importance levels" do
      GalaxyLedger::Buffer::IMPORTANCE_LEVELS.each do |level|
        it "validates importance '#{level}'" do
          entry = GalaxyLedger::Buffer::Entry.new(
            entry_type: "learning",
            content: "Test",
            importance: level
          )
          entry.valid?.should eq(true)
        end
      end
    end
  end

  describe "constants" do
    it "ENTRY_TYPES includes expected types" do
      GalaxyLedger::Buffer::ENTRY_TYPES.should contain("learning")
      GalaxyLedger::Buffer::ENTRY_TYPES.should contain("decision")
      GalaxyLedger::Buffer::ENTRY_TYPES.should contain("guideline")
      GalaxyLedger::Buffer::ENTRY_TYPES.should contain("file_read")
      GalaxyLedger::Buffer::ENTRY_TYPES.should contain("file_edit")
      GalaxyLedger::Buffer::ENTRY_TYPES.should contain("file_write")
    end

    it "IMPORTANCE_LEVELS includes expected levels" do
      GalaxyLedger::Buffer::IMPORTANCE_LEVELS.should eq(["high", "medium", "low"])
    end
  end
end
