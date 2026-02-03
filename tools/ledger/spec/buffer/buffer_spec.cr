require "../spec_helper"

# Helper to create a test session and clean up after
def with_test_session(&)
  session_id = "buffer-test-#{Random.rand(100000)}"
  session_dir = GalaxyLedger.session_dir(session_id)
  Dir.mkdir_p(session_dir)

  begin
    yield session_id
  ensure
    FileUtils.rm_rf(session_dir.to_s)
  end
end

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

  describe ".append" do
    it "appends entry to buffer file" do
      with_test_session do |session_id|
        entry = GalaxyLedger::Buffer::Entry.new(
          entry_type: "learning",
          content: "Test learning",
          importance: "medium"
        )

        result = GalaxyLedger::Buffer.append(session_id, entry)
        result.should eq(true)

        # Verify file was created and contains entry
        buffer_file = GalaxyLedger::Buffer.buffer_path(session_id)
        File.exists?(buffer_file).should eq(true)

        content = File.read(buffer_file)
        content.should contain("learning")
        content.should contain("Test learning")
      end
    end

    it "appends multiple entries" do
      with_test_session do |session_id|
        entry1 = GalaxyLedger::Buffer::Entry.new(
          entry_type: "learning",
          content: "Learning 1",
          importance: "medium"
        )
        entry2 = GalaxyLedger::Buffer::Entry.new(
          entry_type: "decision",
          content: "Decision 1",
          importance: "high"
        )

        GalaxyLedger::Buffer.append(session_id, entry1).should eq(true)
        GalaxyLedger::Buffer.append(session_id, entry2).should eq(true)

        entries = GalaxyLedger::Buffer.read(session_id)
        entries.size.should eq(2)
      end
    end

    it "returns false for empty session_id" do
      entry = GalaxyLedger::Buffer::Entry.new(
        entry_type: "learning",
        content: "Test",
        importance: "medium"
      )

      result = GalaxyLedger::Buffer.append("", entry)
      result.should eq(false)
    end

    it "returns false for invalid entry" do
      with_test_session do |session_id|
        entry = GalaxyLedger::Buffer::Entry.new(
          entry_type: "invalid_type",
          content: "Test",
          importance: "medium"
        )

        result = GalaxyLedger::Buffer.append(session_id, entry)
        result.should eq(false)
      end
    end

    it "creates session directory if needed" do
      session_id = "new-buffer-session-#{Random.rand(100000)}"
      session_dir = GalaxyLedger.session_dir(session_id)

      # Ensure it doesn't exist
      FileUtils.rm_rf(session_dir.to_s)

      begin
        entry = GalaxyLedger::Buffer::Entry.new(
          entry_type: "learning",
          content: "Test",
          importance: "medium"
        )

        result = GalaxyLedger::Buffer.append(session_id, entry)
        result.should eq(true)
        Dir.exists?(session_dir).should eq(true)
      ensure
        FileUtils.rm_rf(session_dir.to_s)
      end
    end
  end

  describe ".append_many" do
    it "appends multiple entries in one call" do
      with_test_session do |session_id|
        entries = [
          GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L1", importance: "medium"),
          GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "D1", importance: "high"),
          GalaxyLedger::Buffer::Entry.new(entry_type: "file_read", content: "F1", importance: "low"),
        ]

        count = GalaxyLedger::Buffer.append_many(session_id, entries)
        count.should eq(3)

        read_entries = GalaxyLedger::Buffer.read(session_id)
        read_entries.size.should eq(3)
      end
    end

    it "skips invalid entries" do
      with_test_session do |session_id|
        entries = [
          GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "Valid", importance: "medium"),
          GalaxyLedger::Buffer::Entry.new(entry_type: "invalid", content: "Invalid", importance: "medium"),
          GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "Valid2", importance: "high"),
        ]

        count = GalaxyLedger::Buffer.append_many(session_id, entries)
        count.should eq(2)

        read_entries = GalaxyLedger::Buffer.read(session_id)
        read_entries.size.should eq(2)
      end
    end

    it "returns 0 for empty session_id" do
      entries = [
        GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "Test", importance: "medium"),
      ]

      count = GalaxyLedger::Buffer.append_many("", entries)
      count.should eq(0)
    end

    it "returns 0 for empty entries array" do
      with_test_session do |session_id|
        count = GalaxyLedger::Buffer.append_many(session_id, [] of GalaxyLedger::Buffer::Entry)
        count.should eq(0)
      end
    end
  end

  describe ".read" do
    it "reads entries from buffer file" do
      with_test_session do |session_id|
        # Write entries
        entry1 = GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L1", importance: "medium")
        entry2 = GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "D1", importance: "high")
        GalaxyLedger::Buffer.append(session_id, entry1)
        GalaxyLedger::Buffer.append(session_id, entry2)

        # Read entries
        entries = GalaxyLedger::Buffer.read(session_id)
        entries.size.should eq(2)
        entries[0].entry_type.should eq("learning")
        entries[1].entry_type.should eq("decision")
      end
    end

    it "returns empty array when buffer doesn't exist" do
      with_test_session do |session_id|
        entries = GalaxyLedger::Buffer.read(session_id)
        entries.should be_empty
      end
    end

    it "returns empty array for empty session_id" do
      entries = GalaxyLedger::Buffer.read("")
      entries.should be_empty
    end

    it "skips malformed lines" do
      with_test_session do |session_id|
        buffer_file = GalaxyLedger::Buffer.buffer_path(session_id)

        # Write mixed valid and invalid lines
        File.write(buffer_file, <<-JSONL)
        {"entry_type":"learning","content":"Valid1","importance":"medium","created_at":"2026-02-01T10:00:00Z"}
        not valid json
        {"entry_type":"decision","content":"Valid2","importance":"high","created_at":"2026-02-01T10:00:00Z"}
        JSONL

        entries = GalaxyLedger::Buffer.read(session_id)
        entries.size.should eq(2)
      end
    end

    it "handles empty lines" do
      with_test_session do |session_id|
        buffer_file = GalaxyLedger::Buffer.buffer_path(session_id)

        File.write(buffer_file, <<-JSONL)
        {"entry_type":"learning","content":"Valid","importance":"medium","created_at":"2026-02-01T10:00:00Z"}

        {"entry_type":"decision","content":"Valid2","importance":"high","created_at":"2026-02-01T10:00:00Z"}
        JSONL

        entries = GalaxyLedger::Buffer.read(session_id)
        entries.size.should eq(2)
      end
    end
  end

  describe ".count" do
    it "counts entries in buffer" do
      with_test_session do |session_id|
        entries = [
          GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L1", importance: "medium"),
          GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L2", importance: "medium"),
          GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L3", importance: "medium"),
        ]
        GalaxyLedger::Buffer.append_many(session_id, entries)

        GalaxyLedger::Buffer.count(session_id).should eq(3)
      end
    end

    it "returns 0 when buffer doesn't exist" do
      with_test_session do |session_id|
        GalaxyLedger::Buffer.count(session_id).should eq(0)
      end
    end

    it "returns 0 for empty session_id" do
      GalaxyLedger::Buffer.count("").should eq(0)
    end
  end

  describe ".exists?" do
    it "returns true when buffer file exists" do
      with_test_session do |session_id|
        entry = GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "Test", importance: "medium")
        GalaxyLedger::Buffer.append(session_id, entry)

        GalaxyLedger::Buffer.exists?(session_id).should eq(true)
      end
    end

    it "returns false when buffer file doesn't exist" do
      with_test_session do |session_id|
        GalaxyLedger::Buffer.exists?(session_id).should eq(false)
      end
    end

    it "returns false for empty session_id" do
      GalaxyLedger::Buffer.exists?("").should eq(false)
    end
  end

  describe ".flush_in_progress?" do
    it "returns false when no flush in progress" do
      with_test_session do |session_id|
        GalaxyLedger::Buffer.flush_in_progress?(session_id).should eq(false)
      end
    end

    it "returns true when flushing file exists" do
      with_test_session do |session_id|
        flushing_file = GalaxyLedger::Buffer.flushing_path(session_id)
        File.write(flushing_file, "test")

        GalaxyLedger::Buffer.flush_in_progress?(session_id).should eq(true)
      end
    end

    it "returns false for empty session_id" do
      GalaxyLedger::Buffer.flush_in_progress?("").should eq(false)
    end
  end

  describe ".clear" do
    it "deletes buffer file" do
      with_test_session do |session_id|
        entry = GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "Test", importance: "medium")
        GalaxyLedger::Buffer.append(session_id, entry)

        GalaxyLedger::Buffer.exists?(session_id).should eq(true)
        GalaxyLedger::Buffer.clear(session_id).should eq(true)
        GalaxyLedger::Buffer.exists?(session_id).should eq(false)
      end
    end

    it "returns true when buffer doesn't exist" do
      with_test_session do |session_id|
        GalaxyLedger::Buffer.clear(session_id).should eq(true)
      end
    end

    it "returns false for empty session_id" do
      GalaxyLedger::Buffer.clear("").should eq(false)
    end
  end

  describe ".flush_sync" do
    it "flushes buffer and returns success" do
      with_test_session do |session_id|
        entries = [
          GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L1", importance: "medium"),
          GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "D1", importance: "high"),
        ]
        GalaxyLedger::Buffer.append_many(session_id, entries)

        result = GalaxyLedger::Buffer.flush_sync(session_id)
        result.success.should eq(true)
        result.entries_flushed.should eq(2)

        # Buffer should be cleared
        GalaxyLedger::Buffer.exists?(session_id).should eq(false)
        # Flushing file should be cleaned up
        GalaxyLedger::Buffer.flush_in_progress?(session_id).should eq(false)
      end
    end

    it "returns success with 0 entries when buffer is empty" do
      with_test_session do |session_id|
        result = GalaxyLedger::Buffer.flush_sync(session_id)
        result.success.should eq(true)
        result.entries_flushed.should eq(0)
        result.reason.should eq("nothing to flush")
      end
    end

    it "returns failure for empty session_id" do
      result = GalaxyLedger::Buffer.flush_sync("")
      result.success.should eq(false)
      result.reason.should eq("empty session_id")
    end

    it "returns failure when session doesn't exist" do
      session_id = "nonexistent-#{Random.rand(100000)}"
      FileUtils.rm_rf(GalaxyLedger.session_dir(session_id).to_s)

      result = GalaxyLedger::Buffer.flush_sync(session_id)
      result.success.should eq(false)
      result.reason.should eq("session directory does not exist")
    end

    it "returns failure when another flush is in progress" do
      with_test_session do |session_id|
        # Create buffer and flushing file
        entry = GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "Test", importance: "medium")
        GalaxyLedger::Buffer.append(session_id, entry)

        flushing_file = GalaxyLedger::Buffer.flushing_path(session_id)
        File.write(flushing_file, "in progress")

        result = GalaxyLedger::Buffer.flush_sync(session_id)
        result.success.should eq(false)
        result.reason.should eq("another flush in progress")
      end
    end

    it "atomic rename isolates flush data" do
      with_test_session do |session_id|
        # Write initial entries
        entries = [
          GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L1", importance: "medium"),
        ]
        GalaxyLedger::Buffer.append_many(session_id, entries)

        # Flush
        result = GalaxyLedger::Buffer.flush_sync(session_id)
        result.success.should eq(true)
        result.entries_flushed.should eq(1)

        # Write more entries after flush
        more_entries = [
          GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "D1", importance: "high"),
        ]
        GalaxyLedger::Buffer.append_many(session_id, more_entries)

        # New entries should be in fresh buffer
        GalaxyLedger::Buffer.count(session_id).should eq(1)

        # Flush again
        result2 = GalaxyLedger::Buffer.flush_sync(session_id)
        result2.success.should eq(true)
        result2.entries_flushed.should eq(1)
      end
    end
  end

  describe ".flush_async" do
    it "returns success immediately" do
      with_test_session do |session_id|
        entry = GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "Test", importance: "medium")
        GalaxyLedger::Buffer.append(session_id, entry)

        result = GalaxyLedger::Buffer.flush_async(session_id)
        result.success.should eq(true)
        result.reason.not_nil!.should contain("async flush started")
      end
    end

    it "returns failure for empty session_id" do
      result = GalaxyLedger::Buffer.flush_async("")
      result.success.should eq(false)
      result.reason.should eq("empty session_id")
    end

    # Note: We can't easily test that the async flush actually completes
    # because it runs in a forked process. Integration tests will cover this.
  end

  describe ".process_orphaned_flushing_file" do
    it "processes and deletes orphaned flushing file" do
      with_test_session do |session_id|
        # Create orphaned flushing file
        flushing_file = GalaxyLedger::Buffer.flushing_path(session_id)
        File.write(flushing_file, <<-JSONL)
        {"entry_type":"learning","content":"Orphan1","importance":"medium","created_at":"2026-02-01T10:00:00Z"}
        {"entry_type":"decision","content":"Orphan2","importance":"high","created_at":"2026-02-01T10:00:00Z"}
        JSONL

        count = GalaxyLedger::Buffer.process_orphaned_flushing_file(session_id)
        count.should eq(2)

        # File should be deleted
        File.exists?(flushing_file).should eq(false)
      end
    end

    it "returns 0 when no orphaned file exists" do
      with_test_session do |session_id|
        count = GalaxyLedger::Buffer.process_orphaned_flushing_file(session_id)
        count.should eq(0)
      end
    end

    it "returns 0 for empty session_id" do
      count = GalaxyLedger::Buffer.process_orphaned_flushing_file("")
      count.should eq(0)
    end
  end

  describe "path helpers" do
    it ".buffer_path returns correct path" do
      path = GalaxyLedger::Buffer.buffer_path("test-session")
      path.to_s.should contain("sessions/test-session")
      path.to_s.should end_with("ledger_buffer.jsonl")
    end

    it ".flushing_path returns correct path" do
      path = GalaxyLedger::Buffer.flushing_path("test-session")
      path.to_s.should contain("sessions/test-session")
      path.to_s.should end_with("ledger_buffer.flushing.jsonl")
    end

    it ".lock_path returns correct path" do
      path = GalaxyLedger::Buffer.lock_path("test-session")
      path.to_s.should contain("sessions/test-session")
      path.to_s.should end_with("ledger_buffer.lock")
    end
  end
end
