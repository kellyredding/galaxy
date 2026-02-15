require "../spec_helper"

describe GalaxyLedger::Database do
  # Clean database before each test
  before_each do
    db_path = GalaxyLedger::Database.database_path
    File.delete(db_path) if File.exists?(db_path)
  end

  describe ".database_path" do
    it "returns path from environment variable" do
      GalaxyLedger::Database.database_path.should eq(SPEC_DATABASE_PATH)
    end
  end

  describe ".content_hash" do
    it "generates consistent SHA256 hash" do
      hash1 = GalaxyLedger::Database.content_hash("learning", "test content")
      hash2 = GalaxyLedger::Database.content_hash("learning", "test content")
      hash1.should eq(hash2)
    end

    it "generates different hashes for different entry types" do
      hash1 = GalaxyLedger::Database.content_hash("learning", "test content")
      hash2 = GalaxyLedger::Database.content_hash("decision", "test content")
      hash1.should_not eq(hash2)
    end

    it "generates different hashes for different content" do
      hash1 = GalaxyLedger::Database.content_hash("learning", "content A")
      hash2 = GalaxyLedger::Database.content_hash("learning", "content B")
      hash1.should_not eq(hash2)
    end

    it "generates 64-character hex string" do
      hash = GalaxyLedger::Database.content_hash("learning", "test")
      hash.size.should eq(64)
      hash.match(/^[a-f0-9]+$/).should_not be_nil
    end
  end

  describe ".ensure_database_exists" do
    it "creates data directory if it doesn't exist" do
      FileUtils.rm_rf(SPEC_DATA_DIR.to_s) if Dir.exists?(SPEC_DATA_DIR)
      Dir.exists?(SPEC_DATA_DIR).should be_false

      GalaxyLedger::Database.ensure_database_exists

      Dir.exists?(SPEC_DATA_DIR).should be_true
    end

    it "creates database file with schema" do
      db_path = GalaxyLedger::Database.database_path
      File.exists?(db_path).should be_false

      GalaxyLedger::Database.ensure_database_exists

      File.exists?(db_path).should be_true
    end
  end

  describe ".create_schema" do
    it "creates ledger_sessions table" do
      GalaxyLedger::Database.create_schema

      GalaxyLedger::Database.open do |db|
        result = db.scalar(<<-SQL).as(Int64)
          SELECT COUNT(*) FROM sqlite_master
          WHERE type='table' AND name='ledger_sessions'
        SQL
        result.should eq(1)
      end
    end

    it "creates ledger_entries table" do
      GalaxyLedger::Database.create_schema

      GalaxyLedger::Database.open do |db|
        result = db.scalar(<<-SQL).as(Int64)
          SELECT COUNT(*) FROM sqlite_master
          WHERE type='table' AND name='ledger_entries'
        SQL
        result.should eq(1)
      end
    end

    it "creates ledger_session_files table" do
      GalaxyLedger::Database.create_schema

      GalaxyLedger::Database.open do |db|
        result = db.scalar(<<-SQL).as(Int64)
          SELECT COUNT(*) FROM sqlite_master
          WHERE type='table' AND name='ledger_session_files'
        SQL
        result.should eq(1)
      end
    end

    it "creates ledger_fts virtual table" do
      GalaxyLedger::Database.create_schema

      GalaxyLedger::Database.open do |db|
        result = db.scalar(<<-SQL).as(Int64)
          SELECT COUNT(*) FROM sqlite_master
          WHERE type='table' AND name='ledger_fts'
        SQL
        result.should eq(1)
      end
    end

    it "creates required indexes" do
      GalaxyLedger::Database.create_schema

      GalaxyLedger::Database.open do |db|
        indexes = [] of String
        db.query("SELECT name FROM sqlite_master WHERE type='index'") do |rs|
          rs.each do
            indexes << rs.read(String)
          end
        end

        # ledger_sessions indexes
        indexes.should contain("idx_sessions_identifier")

        # ledger_entries indexes
        indexes.should contain("idx_entries_session")
        indexes.should contain("idx_entries_session_type")
        indexes.should contain("idx_entries_source")
        indexes.should contain("idx_entries_created")
        indexes.should contain("idx_entries_importance")
        indexes.should contain("idx_entries_category")
        indexes.should contain("idx_entries_ledger_session")
        indexes.should contain("idx_content_dedup")

        # ledger_session_files indexes
        indexes.should contain("idx_files_session")
        indexes.should contain("idx_files_ledger_session")
      end
    end

    it "creates FTS triggers" do
      GalaxyLedger::Database.create_schema

      GalaxyLedger::Database.open do |db|
        triggers = [] of String
        db.query("SELECT name FROM sqlite_master WHERE type='trigger'") do |rs|
          rs.each do
            triggers << rs.read(String)
          end
        end

        triggers.should contain("ledger_ai")
        triggers.should contain("ledger_ad")
        triggers.should contain("ledger_au")
      end
    end
  end

  describe ".insert" do
    it "inserts a valid entry" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Test learning content",
        importance: "medium",
        source: "assistant"
      )

      GalaxyLedger::Database.upsert_session("test-session")
      result = GalaxyLedger::Database.insert("test-session", entry)
      result.should be_true

      GalaxyLedger::Database.count.should eq(1)
    end

    it "returns false for empty session_id" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Test content"
      )

      result = GalaxyLedger::Database.insert("", entry)
      result.should be_false
    end

    it "returns false for invalid entry" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "invalid_type",
        content: "Test content"
      )

      GalaxyLedger::Database.upsert_session("test-session")
      result = GalaxyLedger::Database.insert("test-session", entry)
      result.should be_false
    end

    it "prevents duplicate entries with same content_hash" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Duplicate test content",
        importance: "medium"
      )

      GalaxyLedger::Database.upsert_session("test-session")
      result1 = GalaxyLedger::Database.insert("test-session", entry)
      result2 = GalaxyLedger::Database.insert("test-session", entry)

      result1.should be_true
      result2.should be_false
      GalaxyLedger::Database.count.should eq(1)
    end

    it "allows same content in different sessions" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Same content different session"
      )

      GalaxyLedger::Database.upsert_session("session-1")
      GalaxyLedger::Database.upsert_session("session-2")
      result1 = GalaxyLedger::Database.insert("session-1", entry)
      result2 = GalaxyLedger::Database.insert("session-2", entry)

      result1.should be_true
      result2.should be_true
      GalaxyLedger::Database.count.should eq(2)
    end

    it "stores metadata as JSON" do
      metadata = JSON.parse(%({"source_file": "test.rb", "line": 42}))
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Test with metadata",
        metadata: metadata
      )

      GalaxyLedger::Database.upsert_session("test-session")
      GalaxyLedger::Database.insert("test-session", entry)

      entries = GalaxyLedger::Database.query_by_session("test-session")
      entries.size.should eq(1)
      entries[0].metadata.should_not be_nil
      metadata_str = entries[0].metadata.not_nil!
      metadata_str.should contain("source_file")
    end
  end

  describe ".insert_many" do
    it "inserts multiple entries" do
      entries = [
        GalaxyLedger::Entry.new(entry_type: "learning", content: "Learning 1"),
        GalaxyLedger::Entry.new(entry_type: "decision", content: "Decision 1"),
        GalaxyLedger::Entry.new(entry_type: "discovery", content: "Discovery 1"),
      ]

      GalaxyLedger::Database.upsert_session("test-session")
      count = GalaxyLedger::Database.insert_many("test-session", entries)
      count.should eq(3)
      GalaxyLedger::Database.count.should eq(3)
    end

    it "skips invalid entries" do
      entries = [
        GalaxyLedger::Entry.new(entry_type: "learning", content: "Valid"),
        GalaxyLedger::Entry.new(entry_type: "invalid", content: "Invalid"),
        GalaxyLedger::Entry.new(entry_type: "decision", content: "Valid 2"),
      ]

      GalaxyLedger::Database.upsert_session("test-session")
      count = GalaxyLedger::Database.insert_many("test-session", entries)
      count.should eq(2)
    end

    it "skips duplicates" do
      entries = [
        GalaxyLedger::Entry.new(entry_type: "learning", content: "Same content"),
        GalaxyLedger::Entry.new(entry_type: "learning", content: "Same content"),
        GalaxyLedger::Entry.new(entry_type: "learning", content: "Different content"),
      ]

      GalaxyLedger::Database.upsert_session("test-session")
      count = GalaxyLedger::Database.insert_many("test-session", entries)
      count.should eq(2)
    end

    it "returns 0 for empty session_id" do
      entries = [GalaxyLedger::Entry.new(entry_type: "learning", content: "Test")]
      count = GalaxyLedger::Database.insert_many("", entries)
      count.should eq(0)
    end

    it "returns 0 for empty entries array" do
      count = GalaxyLedger::Database.insert_many("test-session", [] of GalaxyLedger::Entry)
      count.should eq(0)
    end
  end

  describe ".delete_session" do
    it "deletes all entries for a session" do
      entries = [
        GalaxyLedger::Entry.new(entry_type: "learning", content: "L1"),
        GalaxyLedger::Entry.new(entry_type: "decision", content: "D1"),
      ]
      GalaxyLedger::Database.upsert_session("session-to-delete")
      GalaxyLedger::Database.upsert_session("other-session")
      GalaxyLedger::Database.insert_many("session-to-delete", entries)
      GalaxyLedger::Database.insert("other-session", GalaxyLedger::Entry.new(entry_type: "learning", content: "Keep"))

      deleted = GalaxyLedger::Database.delete_session("session-to-delete")

      deleted.should eq(2)
      GalaxyLedger::Database.count.should eq(1)
      GalaxyLedger::Database.count_by_session("session-to-delete").should eq(0)
      GalaxyLedger::Database.count_by_session("other-session").should eq(1)
    end

    it "returns 0 for empty session_id" do
      deleted = GalaxyLedger::Database.delete_session("")
      deleted.should eq(0)
    end

    it "returns 0 for non-existent session" do
      deleted = GalaxyLedger::Database.delete_session("non-existent")
      deleted.should eq(0)
    end
  end

  describe ".count" do
    it "returns total entry count" do
      GalaxyLedger::Database.upsert_session("s1")
      GalaxyLedger::Database.upsert_session("s2")
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "L1"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "decision", content: "D1"))
      GalaxyLedger::Database.insert("s2", GalaxyLedger::Entry.new(entry_type: "learning", content: "L2"))

      GalaxyLedger::Database.count.should eq(3)
    end

    it "returns 0 for empty database" do
      GalaxyLedger::Database.ensure_database_exists
      GalaxyLedger::Database.count.should eq(0)
    end
  end

  describe ".count_by_session" do
    it "returns count for specific session" do
      GalaxyLedger::Database.upsert_session("s1")
      GalaxyLedger::Database.upsert_session("s2")
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "L1"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "decision", content: "D1"))
      GalaxyLedger::Database.insert("s2", GalaxyLedger::Entry.new(entry_type: "learning", content: "L2"))

      GalaxyLedger::Database.count_by_session("s1").should eq(2)
      GalaxyLedger::Database.count_by_session("s2").should eq(1)
    end

    it "returns 0 for empty session_id" do
      GalaxyLedger::Database.count_by_session("").should eq(0)
    end
  end

  describe ".has_extracted_source_file?" do
    it "returns true when extraction_marker entries exist for the session" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      GalaxyLedger::Database.upsert_session("sess-dedup")
      GalaxyLedger::Database.insert("sess-dedup", entry)

      GalaxyLedger::Database.has_extracted_source_file?("sess-dedup", "/home/user/agent-guidelines/ruby-style.md").should be_true
    end

    it "returns false when no source_file entries exist for the session" do
      GalaxyLedger::Database.has_extracted_source_file?("sess-empty", "/home/user/agent-guidelines/ruby-style.md").should be_false
    end

    it "does not match entries from other sessions" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      GalaxyLedger::Database.upsert_session("sess-other")
      GalaxyLedger::Database.insert("sess-other", entry)

      GalaxyLedger::Database.has_extracted_source_file?("sess-mine", "/home/user/agent-guidelines/ruby-style.md").should be_false
    end

    it "does not match non-marker entry types" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "guideline",
        content: "Always use double-quotes",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      GalaxyLedger::Database.upsert_session("sess-filetype")
      GalaxyLedger::Database.insert("sess-filetype", entry)

      GalaxyLedger::Database.has_extracted_source_file?("sess-filetype", "/home/user/agent-guidelines/ruby-style.md").should be_false
    end

    it "does not match learning entry types" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      GalaxyLedger::Database.upsert_session("sess-filetype2")
      GalaxyLedger::Database.insert("sess-filetype2", entry)

      GalaxyLedger::Database.has_extracted_source_file?("sess-filetype2", "/home/user/agent-guidelines/ruby-style.md").should be_false
    end

    it "distinguishes files with the same basename at different paths" do
      marker1 = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/projects/kajabi/agent-guidelines/dev-setup.md",
        source_file: "/projects/kajabi/agent-guidelines/dev-setup.md",
      )
      GalaxyLedger::Database.upsert_session("sess-collision")
      GalaxyLedger::Database.insert("sess-collision", marker1)

      # Same basename, different full path — should NOT match
      GalaxyLedger::Database.has_extracted_source_file?("sess-collision", "/projects/other/agent-guidelines/dev-setup.md").should be_false
      # Original full path — should match
      GalaxyLedger::Database.has_extracted_source_file?("sess-collision", "/projects/kajabi/agent-guidelines/dev-setup.md").should be_true
    end

    it "returns false for empty inputs" do
      GalaxyLedger::Database.has_extracted_source_file?("", "/home/user/agent-guidelines/ruby-style.md").should be_false
      GalaxyLedger::Database.has_extracted_source_file?("sess", "").should be_false
    end
  end

  describe ".mark_entries_stale" do
    it "marks entries with matching source_file as stale" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      GalaxyLedger::Database.upsert_session("sess-stale")
      GalaxyLedger::Database.insert("sess-stale", entry)

      count = GalaxyLedger::Database.mark_entries_stale("sess-stale", "/home/user/agent-guidelines/ruby-style.md")
      count.should eq(1)
    end

    it "marks both marker and extracted entries for the same source_file" do
      marker = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      extracted = GalaxyLedger::Entry.new(
        entry_type: "guideline",
        content: "Always use double-quotes for strings",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      GalaxyLedger::Database.upsert_session("sess-stale2")
      GalaxyLedger::Database.insert("sess-stale2", marker)
      GalaxyLedger::Database.insert("sess-stale2", extracted)

      count = GalaxyLedger::Database.mark_entries_stale("sess-stale2", "/home/user/agent-guidelines/ruby-style.md")
      count.should eq(2)
    end

    it "does not mark entries from other sessions" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      GalaxyLedger::Database.upsert_session("sess-other")
      GalaxyLedger::Database.insert("sess-other", entry)

      count = GalaxyLedger::Database.mark_entries_stale("sess-mine", "/home/user/agent-guidelines/ruby-style.md")
      count.should eq(0)
    end

    it "does not mark entries with different source_file" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/rspec-style.md",
        source_file: "/home/user/agent-guidelines/rspec-style.md",
      )
      GalaxyLedger::Database.upsert_session("sess-stale3")
      GalaxyLedger::Database.insert("sess-stale3", entry)

      count = GalaxyLedger::Database.mark_entries_stale("sess-stale3", "/home/user/agent-guidelines/ruby-style.md")
      count.should eq(0)
    end

    it "does not cross-mark files with same basename at different paths" do
      marker = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/projects/kajabi/agent-guidelines/dev-setup.md",
        source_file: "/projects/kajabi/agent-guidelines/dev-setup.md",
      )
      GalaxyLedger::Database.upsert_session("sess-stale-collision")
      GalaxyLedger::Database.insert("sess-stale-collision", marker)

      # Marking stale with different full path (same basename) should not match
      count = GalaxyLedger::Database.mark_entries_stale("sess-stale-collision", "/projects/other/agent-guidelines/dev-setup.md")
      count.should eq(0)
    end

    it "returns 0 for empty inputs" do
      GalaxyLedger::Database.mark_entries_stale("", "/home/user/agent-guidelines/ruby-style.md").should eq(0)
      GalaxyLedger::Database.mark_entries_stale("sess", "").should eq(0)
    end
  end

  describe ".stale_entries" do
    it "returns stale extraction_marker entries with full path and extraction type" do
      marker = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
        metadata: JSON.parse({"extraction_type" => "guideline"}.to_json),
      )
      GalaxyLedger::Database.upsert_session("sess-stale-q")
      GalaxyLedger::Database.insert("sess-stale-q", marker)

      # Mark it stale
      GalaxyLedger::Database.mark_entries_stale("sess-stale-q", "/home/user/agent-guidelines/ruby-style.md")

      results = GalaxyLedger::Database.stale_entries("sess-stale-q")
      results.size.should eq(1)
      results[0][:source_file].should eq("/home/user/agent-guidelines/ruby-style.md")
      results[0][:full_path].should eq("/home/user/agent-guidelines/ruby-style.md")
      results[0][:entry_type].should eq("guideline")
    end

    it "returns implementation_plan stale entries via metadata extraction_type" do
      marker = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/implementation-plans/feature.md",
        source_file: "/home/user/implementation-plans/feature.md",
        metadata: JSON.parse({"extraction_type" => "implementation_plan"}.to_json),
      )
      GalaxyLedger::Database.upsert_session("sess-stale-ip")
      GalaxyLedger::Database.insert("sess-stale-ip", marker)
      GalaxyLedger::Database.mark_entries_stale("sess-stale-ip", "/home/user/implementation-plans/feature.md")

      results = GalaxyLedger::Database.stale_entries("sess-stale-ip")
      results.size.should eq(1)
      results[0][:entry_type].should eq("implementation_plan")
    end

    it "excludes stale extracted guideline entries (only returns markers)" do
      marker = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
        metadata: JSON.parse({"extraction_type" => "guideline"}.to_json),
      )
      extracted = GalaxyLedger::Entry.new(
        entry_type: "guideline",
        content: "Always use double-quotes for strings",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      GalaxyLedger::Database.upsert_session("sess-stale-ex")
      GalaxyLedger::Database.insert("sess-stale-ex", marker)
      GalaxyLedger::Database.insert("sess-stale-ex", extracted)
      GalaxyLedger::Database.mark_entries_stale("sess-stale-ex", "/home/user/agent-guidelines/ruby-style.md")

      results = GalaxyLedger::Database.stale_entries("sess-stale-ex")
      # Only the extraction_marker should be returned, not the guideline entry
      results.size.should eq(1)
      results[0][:full_path].should eq("/home/user/agent-guidelines/ruby-style.md")
    end

    it "defaults to guideline extraction_type when metadata is missing" do
      marker = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      GalaxyLedger::Database.upsert_session("sess-stale-nomd")
      GalaxyLedger::Database.insert("sess-stale-nomd", marker)
      GalaxyLedger::Database.mark_entries_stale("sess-stale-nomd", "/home/user/agent-guidelines/ruby-style.md")

      results = GalaxyLedger::Database.stale_entries("sess-stale-nomd")
      results.size.should eq(1)
      results[0][:entry_type].should eq("guideline")
    end

    it "returns empty when nothing is stale" do
      marker = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      GalaxyLedger::Database.upsert_session("sess-fresh")
      GalaxyLedger::Database.insert("sess-fresh", marker)

      # Not marked stale
      results = GalaxyLedger::Database.stale_entries("sess-fresh")
      results.should be_empty
    end

    it "returns empty for empty session_id" do
      GalaxyLedger::Database.stale_entries("").should be_empty
    end

    it "does not return entries from other sessions" do
      marker = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
        metadata: JSON.parse({"extraction_type" => "guideline"}.to_json),
      )
      GalaxyLedger::Database.upsert_session("sess-other-stale")
      GalaxyLedger::Database.insert("sess-other-stale", marker)
      GalaxyLedger::Database.mark_entries_stale("sess-other-stale", "/home/user/agent-guidelines/ruby-style.md")

      results = GalaxyLedger::Database.stale_entries("sess-different")
      results.should be_empty
    end
  end

  describe ".delete_entries_by_source_file" do
    it "deletes marker and extracted guideline entries for a source file" do
      marker = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      extracted = GalaxyLedger::Entry.new(
        entry_type: "guideline",
        content: "Always use double-quotes",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      GalaxyLedger::Database.upsert_session("sess-del")
      GalaxyLedger::Database.insert("sess-del", marker)
      GalaxyLedger::Database.insert("sess-del", extracted)

      deleted = GalaxyLedger::Database.delete_entries_by_source_file("sess-del", "/home/user/agent-guidelines/ruby-style.md")
      deleted.should eq(2)

      # Verify they're gone
      GalaxyLedger::Database.has_extracted_source_file?("sess-del", "/home/user/agent-guidelines/ruby-style.md").should be_false
    end

    it "does not delete entries with different source_file" do
      marker1 = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      marker2 = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/rspec-style.md",
        source_file: "/home/user/agent-guidelines/rspec-style.md",
      )
      GalaxyLedger::Database.upsert_session("sess-del2")
      GalaxyLedger::Database.insert("sess-del2", marker1)
      GalaxyLedger::Database.insert("sess-del2", marker2)

      deleted = GalaxyLedger::Database.delete_entries_by_source_file("sess-del2", "/home/user/agent-guidelines/ruby-style.md")
      deleted.should eq(1)

      # rspec-style.md marker should still exist
      GalaxyLedger::Database.has_extracted_source_file?("sess-del2", "/home/user/agent-guidelines/rspec-style.md").should be_true
    end

    it "does not delete non-guideline/implementation_plan/extraction_marker entries" do
      marker = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      learning = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Something about ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      GalaxyLedger::Database.upsert_session("sess-del3")
      GalaxyLedger::Database.insert("sess-del3", marker)
      GalaxyLedger::Database.insert("sess-del3", learning)

      deleted = GalaxyLedger::Database.delete_entries_by_source_file("sess-del3", "/home/user/agent-guidelines/ruby-style.md")
      deleted.should eq(1) # Only the extraction_marker

      GalaxyLedger::Database.count_by_session("sess-del3").should eq(1) # Learning survives
    end

    it "does not delete entries from other sessions" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      GalaxyLedger::Database.upsert_session("sess-keep")
      GalaxyLedger::Database.insert("sess-keep", entry)

      deleted = GalaxyLedger::Database.delete_entries_by_source_file("sess-other", "/home/user/agent-guidelines/ruby-style.md")
      deleted.should eq(0)

      GalaxyLedger::Database.has_extracted_source_file?("sess-keep", "/home/user/agent-guidelines/ruby-style.md").should be_true
    end

    it "does not cross-delete files with same basename at different paths" do
      marker1 = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/projects/kajabi/agent-guidelines/dev-setup.md",
        source_file: "/projects/kajabi/agent-guidelines/dev-setup.md",
      )
      marker2 = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/projects/other/agent-guidelines/dev-setup.md",
        source_file: "/projects/other/agent-guidelines/dev-setup.md",
      )
      GalaxyLedger::Database.upsert_session("sess-del-collision")
      GalaxyLedger::Database.insert("sess-del-collision", marker1)
      GalaxyLedger::Database.insert("sess-del-collision", marker2)

      # Delete one full path should not affect the other
      deleted = GalaxyLedger::Database.delete_entries_by_source_file("sess-del-collision", "/projects/kajabi/agent-guidelines/dev-setup.md")
      deleted.should eq(1)

      # The other path should still exist
      GalaxyLedger::Database.has_extracted_source_file?("sess-del-collision", "/projects/other/agent-guidelines/dev-setup.md").should be_true
    end

    it "returns 0 for empty inputs" do
      GalaxyLedger::Database.delete_entries_by_source_file("", "/home/user/agent-guidelines/ruby-style.md").should eq(0)
      GalaxyLedger::Database.delete_entries_by_source_file("sess", "").should eq(0)
    end
  end

  describe ".query_by_session" do
    it "returns entries for a session ordered by created_at DESC" do
      # Insert with different timestamps
      entry1 = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "First",
        created_at: "2026-01-01T10:00:00Z"
      )
      entry2 = GalaxyLedger::Entry.new(
        entry_type: "decision",
        content: "Second",
        created_at: "2026-01-01T11:00:00Z"
      )
      GalaxyLedger::Database.upsert_session("test-session")
      GalaxyLedger::Database.insert("test-session", entry1)
      GalaxyLedger::Database.insert("test-session", entry2)

      entries = GalaxyLedger::Database.query_by_session("test-session")

      entries.size.should eq(2)
      entries[0].content.should eq("Second") # Most recent first
      entries[1].content.should eq("First")
    end

    it "respects limit parameter" do
      GalaxyLedger::Database.upsert_session("test-session")
      5.times do |i|
        entry = GalaxyLedger::Entry.new(entry_type: "learning", content: "Entry #{i}")
        GalaxyLedger::Database.insert("test-session", entry)
      end

      entries = GalaxyLedger::Database.query_by_session("test-session", limit: 3)
      entries.size.should eq(3)
    end

    it "returns empty array for empty session_id" do
      GalaxyLedger::Database.query_by_session("").should be_empty
    end
  end

  describe ".query_by_type" do
    it "returns entries of specific type" do
      GalaxyLedger::Database.upsert_session("s1")
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "L1"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "decision", content: "D1"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "L2"))

      entries = GalaxyLedger::Database.query_by_type("s1", "learning")

      entries.size.should eq(2)
      entries.all? { |e| e.entry_type == "learning" }.should be_true
    end
  end

  describe ".query_by_importance" do
    it "returns entries of specific importance" do
      GalaxyLedger::Database.upsert_session("s1")
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "L1", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "decision", content: "D1", importance: "medium"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "L2", importance: "high"))

      entries = GalaxyLedger::Database.query_by_importance("s1", "high")

      entries.size.should eq(2)
      entries.all? { |e| e.importance == "high" }.should be_true
    end
  end

  describe ".search" do
    it "finds entries matching query" do
      GalaxyLedger::Database.upsert_session("s1")
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "JWT authentication tokens expire"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "decision", content: "Using Redis for caching"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "Database connection pooling"))

      entries = GalaxyLedger::Database.search("JWT authentication")

      entries.size.should eq(1)
      entries[0].content.should contain("JWT")
    end

    it "returns empty for no matches" do
      GalaxyLedger::Database.upsert_session("s1")
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "Something else"))

      entries = GalaxyLedger::Database.search("nonexistent term")
      entries.should be_empty
    end

    it "returns empty for empty query" do
      GalaxyLedger::Database.search("").should be_empty
      GalaxyLedger::Database.search("   ").should be_empty
    end

    it "searches across all sessions" do
      GalaxyLedger::Database.upsert_session("s1")
      GalaxyLedger::Database.upsert_session("s2")
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "JWT in session 1"))
      GalaxyLedger::Database.insert("s2", GalaxyLedger::Entry.new(entry_type: "learning", content: "JWT in session 2"))

      entries = GalaxyLedger::Database.search("JWT")
      entries.size.should eq(2)
    end
  end

  describe ".search_in_session" do
    it "searches within a specific session" do
      GalaxyLedger::Database.upsert_session("s1")
      GalaxyLedger::Database.upsert_session("s2")
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "JWT in session 1"))
      GalaxyLedger::Database.insert("s2", GalaxyLedger::Entry.new(entry_type: "learning", content: "JWT in session 2"))

      entries = GalaxyLedger::Database.search_in_session("s1", "JWT")

      entries.size.should eq(1)
      entries[0].session_identifier.should eq("s1")
    end

    it "returns empty for empty session_id" do
      GalaxyLedger::Database.search_in_session("", "query").should be_empty
    end
  end

  describe ".session_stats" do
    it "returns stats for all sessions" do
      GalaxyLedger::Database.upsert_session("s1")
      GalaxyLedger::Database.upsert_session("s2")
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "L1"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "decision", content: "D1"))
      GalaxyLedger::Database.insert("s2", GalaxyLedger::Entry.new(entry_type: "learning", content: "L2"))

      stats = GalaxyLedger::Database.session_stats

      stats.size.should eq(2)
      s1_stat = stats.find { |s| s.session_identifier == "s1" }
      s1_stat.should_not be_nil
      s1_stat.not_nil!.entry_count.should eq(2)
    end
  end

  describe GalaxyLedger::Database::StoredEntry do
    describe "#to_entry" do
      it "converts to Entry" do
        # First insert an entry
        original = GalaxyLedger::Entry.new(
          entry_type: "learning",
          content: "Test content",
          importance: "high",
          source: "assistant"
        )
        GalaxyLedger::Database.upsert_session("test-session")
        GalaxyLedger::Database.insert("test-session", original)

        # Query it back
        entries = GalaxyLedger::Database.query_by_session("test-session")
        ledger_entry = entries[0]

        # Convert back to buffer entry
        buffer_entry = ledger_entry.to_entry

        buffer_entry.entry_type.should eq("learning")
        buffer_entry.content.should eq("Test content")
        buffer_entry.importance.should eq("high")
        buffer_entry.source.should eq("assistant")
      end
    end
  end

  describe ".prepare_fts_query" do
    it "adds * suffix to each word for prefix matching" do
      result = GalaxyLedger::Database.prepare_fts_query("trailing comma")
      result.should eq("trailing* comma*")
    end

    it "does not add * if word already ends with *" do
      result = GalaxyLedger::Database.prepare_fts_query("trailing* comma")
      result.should eq("trailing* comma*")
    end

    it "preserves FTS operators" do
      result = GalaxyLedger::Database.prepare_fts_query("-excluded +required normal")
      result.should eq("-excluded +required normal*")
    end

    it "preserves column filters" do
      result = GalaxyLedger::Database.prepare_fts_query("content:test")
      result.should eq("content:test")
    end

    it "returns original query when prefix_match is false" do
      result = GalaxyLedger::Database.prepare_fts_query("trailing comma", prefix_match: false)
      result.should eq("trailing comma")
    end
  end

  describe ".search with prefix matching" do
    it "finds entries with prefix matching enabled" do
      GalaxyLedger::Database.upsert_session("s1")
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "guideline", content: "Use trailing commas on multiline structures"))

      # "trail" should match "trailing" with prefix matching
      entries = GalaxyLedger::Database.search("trail")
      entries.size.should eq(1)
      entries[0].content.should contain("trailing")
    end

    it "respects prefix_match: false for exact matching" do
      GalaxyLedger::Database.upsert_session("s1")
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "guideline", content: "Use trailing commas"))

      # "trail" should NOT match "trailing" with exact matching
      entries = GalaxyLedger::Database.search("trail", prefix_match: false)
      entries.should be_empty
    end
  end

  describe ".search with filters" do
    before_each do
      GalaxyLedger::Database.upsert_session("s1")
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "JWT tokens expire", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "decision", content: "JWT storage in Redis", importance: "medium"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "guideline", content: "JWT best practices", importance: "high"))
    end

    it "filters by entry_type" do
      entries = GalaxyLedger::Database.search("JWT", entry_type: "learning")
      entries.size.should eq(1)
      entries[0].entry_type.should eq("learning")
    end

    it "filters by importance" do
      entries = GalaxyLedger::Database.search("JWT", importance: "high")
      entries.size.should eq(2)
      entries.all? { |e| e.importance == "high" }.should be_true
    end

    it "filters by both type and importance" do
      entries = GalaxyLedger::Database.search("JWT", entry_type: "guideline", importance: "high")
      entries.size.should eq(1)
      entries[0].entry_type.should eq("guideline")
      entries[0].importance.should eq("high")
    end
  end

  describe ".query_recent_filtered" do
    before_each do
      GalaxyLedger::Database.upsert_session("s1")
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "L1", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "decision", content: "D1", importance: "medium"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "L2", importance: "low"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "guideline", content: "G1", importance: "high"))
    end

    it "returns all entries with no filters" do
      entries = GalaxyLedger::Database.query_recent_filtered(100)
      entries.size.should eq(4)
    end

    it "filters by entry_type" do
      entries = GalaxyLedger::Database.query_recent_filtered(100, entry_type: "learning")
      entries.size.should eq(2)
      entries.all? { |e| e.entry_type == "learning" }.should be_true
    end

    it "filters by importance" do
      entries = GalaxyLedger::Database.query_recent_filtered(100, importance: "high")
      entries.size.should eq(2)
      entries.all? { |e| e.importance == "high" }.should be_true
    end

    it "filters by both type and importance" do
      entries = GalaxyLedger::Database.query_recent_filtered(100, entry_type: "learning", importance: "high")
      entries.size.should eq(1)
      entries[0].content.should eq("L1")
    end
  end

  describe ".query_tier1" do
    before_each do
      GalaxyLedger::Database.upsert_session("s1")
      # Tier 1 entries
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "guideline", content: "G1", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "guideline", content: "G2", importance: "medium"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "implementation_plan", content: "IP1", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "decision", content: "D1 high", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "decision", content: "D2 medium", importance: "medium"))
      # Non-tier1 entries
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "L1", importance: "medium"))
      # Extraction markers should NOT appear in tier1 results
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "extraction_marker", content: "/home/user/agent-guidelines/ruby-style.md", importance: "medium", source_file: "/home/user/agent-guidelines/ruby-style.md"))
    end

    it "returns guidelines for the session" do
      result = GalaxyLedger::Database.query_tier1("s1")
      result.guidelines.size.should eq(2)
    end

    it "returns implementation plans for the session" do
      result = GalaxyLedger::Database.query_tier1("s1")
      result.implementation_plans.size.should eq(1)
    end

    it "excludes extraction_marker entries from guidelines" do
      result = GalaxyLedger::Database.query_tier1("s1")
      all_types = result.guidelines.map(&.entry_type) + result.implementation_plans.map(&.entry_type) + result.high_importance_decisions.map(&.entry_type)
      all_types.should_not contain("extraction_marker")
    end

    it "returns only high-importance decisions" do
      result = GalaxyLedger::Database.query_tier1("s1")
      result.high_importance_decisions.size.should eq(1)
      result.high_importance_decisions[0].importance.should eq("high")
    end

    it "respects decision limit" do
      # Add more high-importance decisions
      5.times do |i|
        GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "decision", content: "Extra D#{i}", importance: "high"))
      end

      result = GalaxyLedger::Database.query_tier1("s1", decision_limit: 3)
      result.high_importance_decisions.size.should eq(3)
    end

    it "returns total count" do
      result = GalaxyLedger::Database.query_tier1("s1")
      result.total_count.should eq(4) # 2 guidelines + 1 impl_plan + 1 high decision
    end

    it "returns empty results for empty session_id" do
      result = GalaxyLedger::Database.query_tier1("")
      result.total_count.should eq(0)
    end
  end

  describe ".query_tier2" do
    before_each do
      GalaxyLedger::Database.upsert_session("s1")
      # Tier 2 entries
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "L1", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "L2", importance: "medium"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "decision", content: "D1 medium", importance: "medium"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "decision", content: "D2 high", importance: "high"))
    end

    it "returns learnings for the session" do
      result = GalaxyLedger::Database.query_tier2("s1")
      result.learnings.size.should eq(2)
    end

    it "returns only medium-importance decisions" do
      result = GalaxyLedger::Database.query_tier2("s1")
      result.medium_decisions.size.should eq(1)
      result.medium_decisions[0].importance.should eq("medium")
    end

    it "respects limits" do
      # Add more learnings
      5.times do |i|
        GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "Extra L#{i}", importance: "medium"))
      end

      result = GalaxyLedger::Database.query_tier2("s1", learnings_limit: 3)
      result.learnings.size.should eq(3)
    end

    it "returns total count" do
      result = GalaxyLedger::Database.query_tier2("s1")
      result.total_count.should eq(3) # 2 learnings + 1 medium decision
    end
  end

  describe ".query_for_restoration" do
    before_each do
      GalaxyLedger::Database.upsert_session("s1")
      # Mix of tier 1 and tier 2 entries
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "guideline", content: "G1", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "implementation_plan", content: "IP1", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "decision", content: "D1 high", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "decision", content: "D2 medium", importance: "medium"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Entry.new(entry_type: "learning", content: "L1", importance: "medium"))
    end

    it "returns both tier1 and tier2 results" do
      result = GalaxyLedger::Database.query_for_restoration("s1")

      result.tier1.guidelines.size.should eq(1)
      result.tier1.implementation_plans.size.should eq(1)
      result.tier1.high_importance_decisions.size.should eq(1)

      result.tier2.learnings.size.should eq(1)
      result.tier2.medium_decisions.size.should eq(1)
    end

    it "returns combined total count" do
      result = GalaxyLedger::Database.query_for_restoration("s1")
      result.total_count.should eq(5)
    end

    it "respects all limits" do
      result = GalaxyLedger::Database.query_for_restoration(
        "s1",
        tier1_decision_limit: 0,
        tier2_learnings_limit: 0,
        tier2_decisions_limit: 0
      )
      result.tier1.high_importance_decisions.size.should eq(0)
      result.tier2.learnings.size.should eq(0)
      result.tier2.medium_decisions.size.should eq(0)
    end
  end

  # ============================================================
  # Internal Entry Type Exclusion Tests
  # ============================================================

  describe "INTERNAL_ENTRY_TYPES exclusion" do
    # Seed a session with a mix of real entries and internal extraction_marker entries.
    # All public-facing queries should exclude the markers implicitly.
    before_each do
      GalaxyLedger::Database.upsert_session("s-excl")
      GalaxyLedger::Database.insert("s-excl", GalaxyLedger::Entry.new(entry_type: "guideline", content: "Use double-quotes for strings", importance: "high", source_file: "/home/user/agent-guidelines/ruby-style.md"))
      GalaxyLedger::Database.insert("s-excl", GalaxyLedger::Entry.new(entry_type: "learning", content: "JWT tokens expire after 15 min", importance: "medium"))
      GalaxyLedger::Database.insert("s-excl", GalaxyLedger::Entry.new(entry_type: "extraction_marker", content: "/home/user/agent-guidelines/ruby-style.md", importance: "medium", source_file: "/home/user/agent-guidelines/ruby-style.md"))
    end

    it "count excludes extraction_marker entries" do
      GalaxyLedger::Database.count.should eq(2)
    end

    it "count_by_session excludes extraction_marker entries" do
      GalaxyLedger::Database.count_by_session("s-excl").should eq(2)
    end

    it "query_by_session excludes extraction_marker entries" do
      entries = GalaxyLedger::Database.query_by_session("s-excl")
      entries.size.should eq(2)
      entries.none? { |e| e.entry_type == "extraction_marker" }.should be_true
    end

    it "query_by_type returns extraction_marker entries when explicitly requested" do
      entries = GalaxyLedger::Database.query_by_type("s-excl", "extraction_marker")
      entries.size.should eq(1)
      entries.first.entry_type.should eq("extraction_marker")
    end

    it "query_by_importance excludes extraction_marker entries" do
      entries = GalaxyLedger::Database.query_by_importance("s-excl", "medium")
      entries.size.should eq(1)
      entries[0].entry_type.should eq("learning")
    end

    it "search excludes extraction_marker entries" do
      # The marker content is a file path containing "ruby-style" which is also in the guideline
      entries = GalaxyLedger::Database.search("ruby")
      entries.none? { |e| e.entry_type == "extraction_marker" }.should be_true
    end

    it "search_in_session excludes extraction_marker entries" do
      entries = GalaxyLedger::Database.search_in_session("s-excl", "ruby")
      entries.none? { |e| e.entry_type == "extraction_marker" }.should be_true
    end

    it "query_recent_filtered excludes extraction_marker entries" do
      entries = GalaxyLedger::Database.query_recent_filtered(100, session_identifier: "s-excl")
      entries.size.should eq(2)
      entries.none? { |e| e.entry_type == "extraction_marker" }.should be_true
    end

    it "session_stats excludes extraction_marker entries from counts" do
      stats = GalaxyLedger::Database.session_stats
      stat = stats.find { |s| s.session_identifier == "s-excl" }
      stat.should_not be_nil
      stat.not_nil!.entry_count.should eq(2)
    end
  end

  # ============================================================
  # Enhanced Schema Tests
  # ============================================================

  describe "Enhanced Schema" do
    describe ".insert with enhanced fields" do
      it "stores category, keywords, applies_when, source_file" do
        entry = GalaxyLedger::Entry.new(
          entry_type: "guideline",
          content: "Always use double-quotes for strings",
          importance: "medium",
          category: "ruby-style",
          keywords: ["ruby", "strings", "quotes"],
          applies_when: "Writing Ruby code",
          source_file: "ruby-style.md"
        )

        GalaxyLedger::Database.upsert_session("s1")
        GalaxyLedger::Database.insert("s1", entry).should be_true

        entries = GalaxyLedger::Database.query_by_session("s1")
        entries.size.should eq(1)
        entries[0].category.should eq("ruby-style")
        entries[0].keywords.should eq("[\"ruby\",\"strings\",\"quotes\"]")
        entries[0].keywords_array.should eq(["ruby", "strings", "quotes"])
        entries[0].applies_when.should eq("Writing Ruby code")
        entries[0].source_file.should eq("ruby-style.md")
      end

      it "handles nil enhanced fields" do
        entry = GalaxyLedger::Entry.new(
          entry_type: "learning",
          content: "Test learning",
          importance: "medium"
        )

        GalaxyLedger::Database.upsert_session("s1")
        GalaxyLedger::Database.insert("s1", entry).should be_true

        entries = GalaxyLedger::Database.query_by_session("s1")
        entries.size.should eq(1)
        entries[0].category.should be_nil
        entries[0].keywords.should be_nil
        entries[0].keywords_array.should eq([] of String)
        entries[0].applies_when.should be_nil
        entries[0].source_file.should be_nil
      end
    end

    describe ".search with enhanced FTS" do
      before_each do
        GalaxyLedger::Database.upsert_session("s1")
        # Create entries with enhanced schema fields
        entry1 = GalaxyLedger::Entry.new(
          entry_type: "guideline",
          content: "Always use double-quotes for strings",
          importance: "medium",
          category: "ruby-style",
          keywords: ["ruby", "strings", "quotes", "formatting"],
          applies_when: "Writing Ruby code",
          source_file: "ruby-style.md"
        )
        entry2 = GalaxyLedger::Entry.new(
          entry_type: "guideline",
          content: "Use let! for database records",
          importance: "medium",
          category: "rspec",
          keywords: ["rspec", "testing", "let", "database"],
          applies_when: "Writing RSpec tests",
          source_file: "rspec-style.md"
        )
        GalaxyLedger::Database.insert("s1", entry1)
        GalaxyLedger::Database.insert("s1", entry2)
      end

      it "searches across keywords" do
        # "formatting" is only in keywords, not content
        entries = GalaxyLedger::Database.search("formatting")
        entries.size.should eq(1)
        entries[0].content.should contain("double-quotes")
      end

      it "searches across source_file with prefix match" do
        # FTS5 tokenizes on hyphens, so "rspec-style.md" becomes tokens ["rspec", "style", "md"]
        # Prefix matching "rspec" should find it
        entries = GalaxyLedger::Database.search("rspec")
        # Should find the rspec entry (source_file contains "rspec")
        rspec_entries = entries.select { |e| e.content.includes?("let!") }
        rspec_entries.size.should eq(1)
      end

      it "searches across category with prefix match" do
        # FTS5 tokenizes "ruby-style" as ["ruby", "style"]
        # Search for "ruby" should find it
        entries = GalaxyLedger::Database.search("ruby")
        ruby_entries = entries.select { |e| e.category == "ruby-style" }
        ruby_entries.size.should eq(1)
      end

      it "filters by category" do
        # Search for something in content and filter by category
        all_entries = GalaxyLedger::Database.search("use")
        all_entries.size.should eq(2)

        filtered_entries = GalaxyLedger::Database.search("use", category: "ruby-style")
        filtered_entries.size.should eq(1)
        filtered_entries[0].category.should eq("ruby-style")
      end
    end

    describe ".query_recent_filtered with category" do
      before_each do
        GalaxyLedger::Database.upsert_session("s1")
        entry1 = GalaxyLedger::Entry.new(
          entry_type: "guideline",
          content: "Ruby rule 1",
          importance: "medium",
          category: "ruby-style"
        )
        entry2 = GalaxyLedger::Entry.new(
          entry_type: "guideline",
          content: "RSpec rule 1",
          importance: "medium",
          category: "rspec"
        )
        entry3 = GalaxyLedger::Entry.new(
          entry_type: "guideline",
          content: "Ruby rule 2",
          importance: "high",
          category: "ruby-style"
        )
        GalaxyLedger::Database.insert("s1", entry1)
        GalaxyLedger::Database.insert("s1", entry2)
        GalaxyLedger::Database.insert("s1", entry3)
      end

      it "filters by category alone" do
        entries = GalaxyLedger::Database.query_recent_filtered(100, category: "ruby-style")
        entries.size.should eq(2)
        entries.all? { |e| e.category == "ruby-style" }.should be_true
      end

      it "filters by category and importance" do
        entries = GalaxyLedger::Database.query_recent_filtered(100, category: "ruby-style", importance: "high")
        entries.size.should eq(1)
        entries[0].category.should eq("ruby-style")
        entries[0].importance.should eq("high")
      end

      it "filters by category and type" do
        entries = GalaxyLedger::Database.query_recent_filtered(100, entry_type: "guideline", category: "rspec")
        entries.size.should eq(1)
        entries[0].category.should eq("rspec")
      end
    end

    describe "StoredEntry#to_entry preserves enhanced fields" do
      it "converts with all enhanced fields" do
        entry = GalaxyLedger::Entry.new(
          entry_type: "guideline",
          content: "Test rule",
          importance: "medium",
          category: "test-category",
          keywords: ["key1", "key2"],
          applies_when: "Testing",
          source_file: "test.md"
        )
        GalaxyLedger::Database.upsert_session("s1")
        GalaxyLedger::Database.insert("s1", entry)

        ledger_entry = GalaxyLedger::Database.query_by_session("s1").first
        buffer_entry = ledger_entry.to_entry

        buffer_entry.category.should eq("test-category")
        buffer_entry.keywords_array.should eq(["key1", "key2"])
        buffer_entry.applies_when.should eq("Testing")
        buffer_entry.source_file.should eq("test.md")
      end
    end
  end

  # ============================================================
  # Session Record Operations
  # ============================================================

  describe ".upsert_session" do
    it "creates a new session record and returns the PK" do
      id = GalaxyLedger::Database.upsert_session("sess-upsert-1")

      id.should be > 0_i64
    end

    it "returns the same PK on subsequent calls (idempotent)" do
      id1 = GalaxyLedger::Database.upsert_session("sess-upsert-2")
      id2 = GalaxyLedger::Database.upsert_session("sess-upsert-2")

      id1.should eq(id2)
    end

    it "stores optional cwd, project_dir, git_branch" do
      GalaxyLedger::Database.upsert_session(
        "sess-upsert-3",
        cwd: "/home/user/project1",
        project_dir: "/home/user/project1",
        git_branch: "main",
      )

      session = GalaxyLedger::Database.get_session("sess-upsert-3")
      session.should_not be_nil
      session.not_nil!.cwd.should eq("/home/user/project1")
      session.not_nil!.project_dir.should eq("/home/user/project1")
      session.not_nil!.git_branch.should eq("main")
    end

    it "preserves existing values when upserting with nil fields" do
      GalaxyLedger::Database.upsert_session(
        "sess-upsert-4",
        cwd: "/home/user/project1",
        project_dir: "/home/user/project1",
      )
      # Upsert again with nil cwd — should keep old value
      GalaxyLedger::Database.upsert_session("sess-upsert-4")

      session = GalaxyLedger::Database.get_session("sess-upsert-4")
      session.should_not be_nil
      session.not_nil!.cwd.should eq("/home/user/project1")
    end

    it "returns 0 for empty session_identifier" do
      id = GalaxyLedger::Database.upsert_session("")
      id.should eq(0_i64)
    end
  end

  describe ".update_session_metrics" do
    it "updates metrics from a ContextStatus object" do
      GalaxyLedger::Database.upsert_session("sess-metrics-1")

      status_json = %({"session_id":"sess-metrics-1","timestamp":1000,"model":{"id":"claude-opus-4-6","display_name":"Claude Opus 4.6"},"claude_version":"1.0.20","context":{"percentage":42.5,"tokens_used":50000,"tokens_max":200000},"cost":{"usd":0.15,"lines_added":100,"lines_removed":25}})
      status = GalaxyLedger::ContextStatus.from_json(status_json)

      result = GalaxyLedger::Database.update_session_metrics("sess-metrics-1", status)
      result.should be_true

      session = GalaxyLedger::Database.get_session("sess-metrics-1")
      session.should_not be_nil
      s = session.not_nil!
      s.model_id.should eq("claude-opus-4-6")
      s.model_display_name.should eq("Claude Opus 4.6")
      s.claude_version.should eq("1.0.20")
      s.context_percentage.should eq(42.5)
      s.tokens_used.should eq(50000_i64)
      s.tokens_max.should eq(200000_i64)
      s.cost_usd.should eq(0.15)
      s.lines_added.should eq(100_i64)
      s.lines_removed.should eq(25_i64)
    end

    it "updates cwd, project_dir, and git_branch from ContextStatus" do
      GalaxyLedger::Database.upsert_session("sess-metrics-pd")

      status_json = %({"session_id":"sess-metrics-pd","cwd":"/home/user/project/subdir","git_branch":"kr/feature-01","workspace":{"project_dir":"/home/user/project"},"context":{"percentage":30.0}})
      status = GalaxyLedger::ContextStatus.from_json(status_json)

      result = GalaxyLedger::Database.update_session_metrics("sess-metrics-pd", status)
      result.should be_true

      session = GalaxyLedger::Database.get_session("sess-metrics-pd")
      session.should_not be_nil
      s = session.not_nil!
      s.cwd.should eq("/home/user/project/subdir")
      s.project_dir.should eq("/home/user/project")
      s.git_branch.should eq("kr/feature-01")
      s.context_percentage.should eq(30.0)
    end

    it "preserves existing cwd, project_dir, and git_branch when nil in update" do
      GalaxyLedger::Database.upsert_session("sess-metrics-preserve",
        cwd: "/existing/dir",
        project_dir: "/existing/project",
        git_branch: "main",
      )

      # Update with nil cwd, project_dir, and git_branch — should preserve existing
      status_json = %({"context":{"percentage":55.0}})
      status = GalaxyLedger::ContextStatus.from_json(status_json)

      GalaxyLedger::Database.update_session_metrics("sess-metrics-preserve", status)

      session = GalaxyLedger::Database.get_session("sess-metrics-preserve")
      session.should_not be_nil
      s = session.not_nil!
      s.cwd.should eq("/existing/dir")
      s.project_dir.should eq("/existing/project")
      s.git_branch.should eq("main")
      s.context_percentage.should eq(55.0)
    end

    it "returns false for empty session_identifier" do
      status_json = %({"session_id":"x"})
      status = GalaxyLedger::ContextStatus.from_json(status_json)

      result = GalaxyLedger::Database.update_session_metrics("", status)
      result.should be_false
    end
  end

  describe ".merge_session_context" do
    it "adds a key to the session context JSON" do
      GalaxyLedger::Database.upsert_session("sess-ctx-1")

      result = GalaxyLedger::Database.merge_session_context("sess-ctx-1", "initial_task", "Fix the bug")
      result.should be_true

      session = GalaxyLedger::Database.get_session("sess-ctx-1")
      session.should_not be_nil
      ctx = JSON.parse(session.not_nil!.context)
      ctx["initial_task"].as_s.should eq("Fix the bug")
    end

    it "merges multiple keys into context" do
      GalaxyLedger::Database.upsert_session("sess-ctx-2")

      GalaxyLedger::Database.merge_session_context("sess-ctx-2", "key1", "value1")
      GalaxyLedger::Database.merge_session_context("sess-ctx-2", "key2", "value2")

      session = GalaxyLedger::Database.get_session("sess-ctx-2")
      ctx = JSON.parse(session.not_nil!.context)
      ctx["key1"].as_s.should eq("value1")
      ctx["key2"].as_s.should eq("value2")
    end

    it "overwrites existing key when write_once is false" do
      GalaxyLedger::Database.upsert_session("sess-ctx-3")

      GalaxyLedger::Database.merge_session_context("sess-ctx-3", "key1", "original")
      GalaxyLedger::Database.merge_session_context("sess-ctx-3", "key1", "updated", write_once: false)

      session = GalaxyLedger::Database.get_session("sess-ctx-3")
      ctx = JSON.parse(session.not_nil!.context)
      ctx["key1"].as_s.should eq("updated")
    end

    it "does not overwrite existing key when write_once is true" do
      GalaxyLedger::Database.upsert_session("sess-ctx-4")

      GalaxyLedger::Database.merge_session_context("sess-ctx-4", "key1", "original")
      GalaxyLedger::Database.merge_session_context("sess-ctx-4", "key1", "should-not-appear", write_once: true)

      session = GalaxyLedger::Database.get_session("sess-ctx-4")
      ctx = JSON.parse(session.not_nil!.context)
      ctx["key1"].as_s.should eq("original")
    end

    it "returns false for empty session_identifier" do
      result = GalaxyLedger::Database.merge_session_context("", "key", "value")
      result.should be_false
    end
  end

  describe ".update_session_last_interaction" do
    it "stores JSON string as last_interaction" do
      GalaxyLedger::Database.upsert_session("sess-li-1")

      json = %({"type":"tool_use","tool":"Read","timestamp":1234567890})
      result = GalaxyLedger::Database.update_session_last_interaction("sess-li-1", json)
      result.should be_true

      session = GalaxyLedger::Database.get_session("sess-li-1")
      session.should_not be_nil
      session.not_nil!.last_interaction.should eq(json)
    end

    it "returns false for empty session_identifier" do
      result = GalaxyLedger::Database.update_session_last_interaction("", "{}")
      result.should be_false
    end
  end

  # ============================================================
  # Session File Operations
  # ============================================================

  describe ".upsert_session_file" do
    it "inserts a file read record" do
      GalaxyLedger::Database.upsert_session("sess-file-1")

      result = GalaxyLedger::Database.upsert_session_file("sess-file-1", "/path/to/file.cr", :read)
      result.should be_true

      files = GalaxyLedger::Database.session_files("sess-file-1")
      files.size.should eq(1)
      files[0].file_path.should eq("/path/to/file.cr")
      files[0].is_read.should be_true
      files[0].is_edited.should be_false
      files[0].is_written.should be_false
      files[0].is_searched.should be_false
      files[0].access_count.should eq(1_i64)
    end

    it "inserts a file edit record" do
      GalaxyLedger::Database.upsert_session("sess-file-2")

      result = GalaxyLedger::Database.upsert_session_file("sess-file-2", "/path/to/file.cr", :edit)
      result.should be_true

      files = GalaxyLedger::Database.session_files("sess-file-2")
      files.size.should eq(1)
      files[0].is_edited.should be_true
    end

    it "inserts a file write record" do
      GalaxyLedger::Database.upsert_session("sess-file-3")

      result = GalaxyLedger::Database.upsert_session_file("sess-file-3", "/path/to/file.cr", :write)
      result.should be_true

      files = GalaxyLedger::Database.session_files("sess-file-3")
      files.size.should eq(1)
      files[0].is_written.should be_true
    end

    it "inserts a search record with pattern" do
      GalaxyLedger::Database.upsert_session("sess-file-4")

      result = GalaxyLedger::Database.upsert_session_file("sess-file-4", "/path/to/dir", :search, search_pattern: "TODO")
      result.should be_true

      files = GalaxyLedger::Database.session_files("sess-file-4")
      files.size.should eq(1)
      files[0].is_searched.should be_true
      files[0].search_pattern.should eq("TODO")
    end

    it "deduplicates on (session_identifier, file_path, search_pattern) and increments access_count" do
      GalaxyLedger::Database.upsert_session("sess-file-5")

      GalaxyLedger::Database.upsert_session_file("sess-file-5", "/path/to/file.cr", :read)
      GalaxyLedger::Database.upsert_session_file("sess-file-5", "/path/to/file.cr", :read)

      files = GalaxyLedger::Database.session_files("sess-file-5")
      files.size.should eq(1)
      files[0].access_count.should eq(2_i64)
    end

    it "accumulates operation flags across upserts" do
      GalaxyLedger::Database.upsert_session("sess-file-6")

      GalaxyLedger::Database.upsert_session_file("sess-file-6", "/path/to/file.cr", :read)
      GalaxyLedger::Database.upsert_session_file("sess-file-6", "/path/to/file.cr", :edit)

      files = GalaxyLedger::Database.session_files("sess-file-6")
      files.size.should eq(1)
      files[0].is_read.should be_true
      files[0].is_edited.should be_true
    end

    it "returns false for empty session_identifier" do
      result = GalaxyLedger::Database.upsert_session_file("", "/path/to/file.cr", :read)
      result.should be_false
    end

    it "returns false for empty file_path" do
      GalaxyLedger::Database.upsert_session("sess-file-7")
      result = GalaxyLedger::Database.upsert_session_file("sess-file-7", "", :read)
      result.should be_false
    end
  end

  describe ".get_session" do
    it "returns the session record when found" do
      GalaxyLedger::Database.upsert_session("sess-get-1", cwd: "/home/user/proj1")

      session = GalaxyLedger::Database.get_session("sess-get-1")
      session.should_not be_nil
      session.not_nil!.session_identifier.should eq("sess-get-1")
      session.not_nil!.cwd.should eq("/home/user/proj1")
    end

    it "returns nil when session does not exist" do
      session = GalaxyLedger::Database.get_session("non-existent-session")
      session.should be_nil
    end

    it "returns nil for empty session_identifier" do
      session = GalaxyLedger::Database.get_session("")
      session.should be_nil
    end
  end

  describe ".list_sessions" do
    it "returns all sessions" do
      GalaxyLedger::Database.upsert_session("sess-list-1")
      GalaxyLedger::Database.upsert_session("sess-list-2")
      GalaxyLedger::Database.upsert_session("sess-list-3")

      sessions = GalaxyLedger::Database.list_sessions
      sessions.size.should eq(3)
      identifiers = sessions.map(&.session_identifier)
      identifiers.should contain("sess-list-1")
      identifiers.should contain("sess-list-2")
      identifiers.should contain("sess-list-3")
    end

    it "respects limit parameter" do
      5.times do |i|
        GalaxyLedger::Database.upsert_session("sess-limit-#{i}")
      end

      sessions = GalaxyLedger::Database.list_sessions(limit: 3)
      sessions.size.should eq(3)
    end

    it "returns empty array when no sessions exist" do
      GalaxyLedger::Database.ensure_database_exists
      sessions = GalaxyLedger::Database.list_sessions
      sessions.should be_empty
    end
  end

  describe ".session_files" do
    it "returns file records for a session" do
      GalaxyLedger::Database.upsert_session("sess-files-1")
      GalaxyLedger::Database.upsert_session_file("sess-files-1", "/path/to/file1.cr", :read)
      GalaxyLedger::Database.upsert_session_file("sess-files-1", "/path/to/file2.cr", :edit)

      files = GalaxyLedger::Database.session_files("sess-files-1")
      files.size.should eq(2)
      file_paths = files.map(&.file_path)
      file_paths.should contain("/path/to/file1.cr")
      file_paths.should contain("/path/to/file2.cr")
    end

    it "returns empty array for empty session_identifier" do
      files = GalaxyLedger::Database.session_files("")
      files.should be_empty
    end

    it "returns empty array when no files tracked" do
      GalaxyLedger::Database.upsert_session("sess-files-2")
      files = GalaxyLedger::Database.session_files("sess-files-2")
      files.should be_empty
    end
  end

  describe ".delete_session cascade" do
    it "cascade deletes session_files along with entries" do
      GalaxyLedger::Database.upsert_session("sess-cascade-1")
      GalaxyLedger::Database.insert("sess-cascade-1", GalaxyLedger::Entry.new(entry_type: "learning", content: "L1"))
      GalaxyLedger::Database.upsert_session_file("sess-cascade-1", "/path/to/file.cr", :read)

      # Verify data exists before delete
      GalaxyLedger::Database.count_by_session("sess-cascade-1").should eq(1)
      GalaxyLedger::Database.session_files("sess-cascade-1").size.should eq(1)

      deleted = GalaxyLedger::Database.delete_session("sess-cascade-1")
      deleted.should eq(1)

      # Verify cascade: entries gone
      GalaxyLedger::Database.count_by_session("sess-cascade-1").should eq(0)
      # Verify cascade: files gone
      GalaxyLedger::Database.session_files("sess-cascade-1").should be_empty
      # Verify cascade: session record gone
      GalaxyLedger::Database.get_session("sess-cascade-1").should be_nil
    end
  end
end
