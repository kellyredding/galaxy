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

        # ledger_session_identifiers indexes
        indexes.should contain("idx_session_ids_session")

        # ledger_session_pids indexes
        indexes.should contain("idx_session_pids_session")

        # ledger_entries indexes
        indexes.should contain("idx_entries_session")
        indexes.should contain("idx_entries_session_type")
        indexes.should contain("idx_entries_source")
        indexes.should contain("idx_entries_created")
        indexes.should contain("idx_entries_importance")
        indexes.should contain("idx_entries_category")
        indexes.should contain("idx_content_dedup")

        # ledger_session_files indexes
        indexes.should contain("idx_files_session")
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

      ledger_session_id = GalaxyLedger::Database.create_session("test-session")
      result = GalaxyLedger::Database.insert(ledger_session_id, entry)
      result.should be_true

      GalaxyLedger::Database.count.should eq(1)
    end

    it "returns false for empty session_id" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Test content"
      )

      result = GalaxyLedger::Database.insert(0_i64, entry)
      result.should be_false
    end

    it "returns false for invalid entry" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "invalid_type",
        content: "Test content"
      )

      ledger_session_id = GalaxyLedger::Database.create_session("test-session")
      result = GalaxyLedger::Database.insert(ledger_session_id, entry)
      result.should be_false
    end

    it "prevents duplicate entries with same content_hash" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Duplicate test content",
        importance: "medium"
      )

      ledger_session_id = GalaxyLedger::Database.create_session("test-session")
      result1 = GalaxyLedger::Database.insert(ledger_session_id, entry)
      result2 = GalaxyLedger::Database.insert(ledger_session_id, entry)

      result1.should be_true
      result2.should be_false
      GalaxyLedger::Database.count.should eq(1)
    end

    it "allows same content in different sessions" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Same content different session"
      )

      lid1 = GalaxyLedger::Database.create_session("session-1")
      lid2 = GalaxyLedger::Database.create_session("session-2")
      result1 = GalaxyLedger::Database.insert(lid1, entry)
      result2 = GalaxyLedger::Database.insert(lid2, entry)

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

      ledger_session_id = GalaxyLedger::Database.create_session("test-session")
      GalaxyLedger::Database.insert(ledger_session_id, entry)

      entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
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

      ledger_session_id = GalaxyLedger::Database.create_session("test-session")
      count = GalaxyLedger::Database.insert_many(ledger_session_id, entries)
      count.should eq(3)
      GalaxyLedger::Database.count.should eq(3)
    end

    it "skips invalid entries" do
      entries = [
        GalaxyLedger::Entry.new(entry_type: "learning", content: "Valid"),
        GalaxyLedger::Entry.new(entry_type: "invalid", content: "Invalid"),
        GalaxyLedger::Entry.new(entry_type: "decision", content: "Valid 2"),
      ]

      ledger_session_id = GalaxyLedger::Database.create_session("test-session")
      count = GalaxyLedger::Database.insert_many(ledger_session_id, entries)
      count.should eq(2)
    end

    it "skips duplicates" do
      entries = [
        GalaxyLedger::Entry.new(entry_type: "learning", content: "Same content"),
        GalaxyLedger::Entry.new(entry_type: "learning", content: "Same content"),
        GalaxyLedger::Entry.new(entry_type: "learning", content: "Different content"),
      ]

      ledger_session_id = GalaxyLedger::Database.create_session("test-session")
      count = GalaxyLedger::Database.insert_many(ledger_session_id, entries)
      count.should eq(2)
    end

    it "returns 0 for empty session_id" do
      entries = [GalaxyLedger::Entry.new(entry_type: "learning", content: "Test")]
      count = GalaxyLedger::Database.insert_many(0_i64, entries)
      count.should eq(0)
    end

    it "returns 0 for empty entries array" do
      count = GalaxyLedger::Database.insert_many(1_i64, [] of GalaxyLedger::Entry)
      count.should eq(0)
    end
  end

  describe ".delete_session" do
    it "deletes all entries for a session" do
      entries = [
        GalaxyLedger::Entry.new(entry_type: "learning", content: "L1"),
        GalaxyLedger::Entry.new(entry_type: "decision", content: "D1"),
      ]
      lid1 = GalaxyLedger::Database.create_session("session-to-delete")
      lid2 = GalaxyLedger::Database.create_session("other-session")
      GalaxyLedger::Database.insert_many(lid1, entries)
      GalaxyLedger::Database.insert(lid2, GalaxyLedger::Entry.new(entry_type: "learning", content: "Keep"))

      deleted = GalaxyLedger::Database.delete_session("session-to-delete")

      deleted.should eq(2)
      GalaxyLedger::Database.count.should eq(1)
      GalaxyLedger::Database.count_by_session(lid1).should eq(0)
      GalaxyLedger::Database.count_by_session(lid2).should eq(1)
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
      lid1 = GalaxyLedger::Database.create_session("s1")
      lid2 = GalaxyLedger::Database.create_session("s2")
      GalaxyLedger::Database.insert(lid1, GalaxyLedger::Entry.new(entry_type: "learning", content: "L1"))
      GalaxyLedger::Database.insert(lid1, GalaxyLedger::Entry.new(entry_type: "decision", content: "D1"))
      GalaxyLedger::Database.insert(lid2, GalaxyLedger::Entry.new(entry_type: "learning", content: "L2"))

      GalaxyLedger::Database.count.should eq(3)
    end

    it "returns 0 for empty database" do
      GalaxyLedger::Database.ensure_database_exists
      GalaxyLedger::Database.count.should eq(0)
    end
  end

  describe ".count_by_session" do
    it "returns count for specific session" do
      lid1 = GalaxyLedger::Database.create_session("s1")
      lid2 = GalaxyLedger::Database.create_session("s2")
      GalaxyLedger::Database.insert(lid1, GalaxyLedger::Entry.new(entry_type: "learning", content: "L1"))
      GalaxyLedger::Database.insert(lid1, GalaxyLedger::Entry.new(entry_type: "decision", content: "D1"))
      GalaxyLedger::Database.insert(lid2, GalaxyLedger::Entry.new(entry_type: "learning", content: "L2"))

      GalaxyLedger::Database.count_by_session(lid1).should eq(2)
      GalaxyLedger::Database.count_by_session(lid2).should eq(1)
    end

    it "returns 0 for empty session_id" do
      GalaxyLedger::Database.count_by_session(0_i64).should eq(0)
    end
  end

  describe ".has_extracted_source_file?" do
    it "returns true when extraction_marker entries exist for the session" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      ledger_session_id = GalaxyLedger::Database.create_session("sess-dedup")
      GalaxyLedger::Database.insert(ledger_session_id, entry)

      GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md").should be_true
    end

    it "returns false when no source_file entries exist for the session" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-empty")
      GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md").should be_false
    end

    it "does not match entries from other sessions" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      lid_other = GalaxyLedger::Database.create_session("sess-other")
      GalaxyLedger::Database.insert(lid_other, entry)

      lid_mine = GalaxyLedger::Database.create_session("sess-mine")
      GalaxyLedger::Database.has_extracted_source_file?(lid_mine, "/home/user/agent-guidelines/ruby-style.md").should be_false
    end

    it "does not match non-marker entry types" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "guideline",
        content: "Always use double-quotes",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      ledger_session_id = GalaxyLedger::Database.create_session("sess-filetype")
      GalaxyLedger::Database.insert(ledger_session_id, entry)

      GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md").should be_false
    end

    it "does not match learning entry types" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      ledger_session_id = GalaxyLedger::Database.create_session("sess-filetype2")
      GalaxyLedger::Database.insert(ledger_session_id, entry)

      GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md").should be_false
    end

    it "distinguishes files with the same basename at different paths" do
      marker1 = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/projects/kajabi/agent-guidelines/dev-setup.md",
        source_file: "/projects/kajabi/agent-guidelines/dev-setup.md",
      )
      ledger_session_id = GalaxyLedger::Database.create_session("sess-collision")
      GalaxyLedger::Database.insert(ledger_session_id, marker1)

      # Same basename, different full path — should NOT match
      GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/projects/other/agent-guidelines/dev-setup.md").should be_false
      # Original full path — should match
      GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/projects/kajabi/agent-guidelines/dev-setup.md").should be_true
    end

    it "returns false for empty inputs" do
      GalaxyLedger::Database.has_extracted_source_file?(0_i64, "/home/user/agent-guidelines/ruby-style.md").should be_false
      ledger_session_id = GalaxyLedger::Database.create_session("sess")
      GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "").should be_false
    end
  end

  describe ".mark_entries_stale" do
    it "marks entries with matching source_file as stale" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      ledger_session_id = GalaxyLedger::Database.create_session("sess-stale")
      GalaxyLedger::Database.insert(ledger_session_id, entry)

      count = GalaxyLedger::Database.mark_entries_stale(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md")
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
      ledger_session_id = GalaxyLedger::Database.create_session("sess-stale2")
      GalaxyLedger::Database.insert(ledger_session_id, marker)
      GalaxyLedger::Database.insert(ledger_session_id, extracted)

      count = GalaxyLedger::Database.mark_entries_stale(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md")
      count.should eq(2)
    end

    it "does not mark entries from other sessions" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      lid_other = GalaxyLedger::Database.create_session("sess-other")
      GalaxyLedger::Database.insert(lid_other, entry)

      lid_mine = GalaxyLedger::Database.create_session("sess-mine")
      count = GalaxyLedger::Database.mark_entries_stale(lid_mine, "/home/user/agent-guidelines/ruby-style.md")
      count.should eq(0)
    end

    it "does not mark entries with different source_file" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/rspec-style.md",
        source_file: "/home/user/agent-guidelines/rspec-style.md",
      )
      ledger_session_id = GalaxyLedger::Database.create_session("sess-stale3")
      GalaxyLedger::Database.insert(ledger_session_id, entry)

      count = GalaxyLedger::Database.mark_entries_stale(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md")
      count.should eq(0)
    end

    it "does not cross-mark files with same basename at different paths" do
      marker = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/projects/kajabi/agent-guidelines/dev-setup.md",
        source_file: "/projects/kajabi/agent-guidelines/dev-setup.md",
      )
      ledger_session_id = GalaxyLedger::Database.create_session("sess-stale-collision")
      GalaxyLedger::Database.insert(ledger_session_id, marker)

      # Marking stale with different full path (same basename) should not match
      count = GalaxyLedger::Database.mark_entries_stale(ledger_session_id, "/projects/other/agent-guidelines/dev-setup.md")
      count.should eq(0)
    end

    it "returns 0 for empty inputs" do
      GalaxyLedger::Database.mark_entries_stale(0_i64, "/home/user/agent-guidelines/ruby-style.md").should eq(0)
      ledger_session_id = GalaxyLedger::Database.create_session("sess")
      GalaxyLedger::Database.mark_entries_stale(ledger_session_id, "").should eq(0)
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
      ledger_session_id = GalaxyLedger::Database.create_session("sess-stale-q")
      GalaxyLedger::Database.insert(ledger_session_id, marker)

      # Mark it stale
      GalaxyLedger::Database.mark_entries_stale(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md")

      results = GalaxyLedger::Database.stale_entries(ledger_session_id)
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
      ledger_session_id = GalaxyLedger::Database.create_session("sess-stale-ip")
      GalaxyLedger::Database.insert(ledger_session_id, marker)
      GalaxyLedger::Database.mark_entries_stale(ledger_session_id, "/home/user/implementation-plans/feature.md")

      results = GalaxyLedger::Database.stale_entries(ledger_session_id)
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
      ledger_session_id = GalaxyLedger::Database.create_session("sess-stale-ex")
      GalaxyLedger::Database.insert(ledger_session_id, marker)
      GalaxyLedger::Database.insert(ledger_session_id, extracted)
      GalaxyLedger::Database.mark_entries_stale(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md")

      results = GalaxyLedger::Database.stale_entries(ledger_session_id)
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
      ledger_session_id = GalaxyLedger::Database.create_session("sess-stale-nomd")
      GalaxyLedger::Database.insert(ledger_session_id, marker)
      GalaxyLedger::Database.mark_entries_stale(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md")

      results = GalaxyLedger::Database.stale_entries(ledger_session_id)
      results.size.should eq(1)
      results[0][:entry_type].should eq("guideline")
    end

    it "returns empty when nothing is stale" do
      marker = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      ledger_session_id = GalaxyLedger::Database.create_session("sess-fresh")
      GalaxyLedger::Database.insert(ledger_session_id, marker)

      # Not marked stale
      results = GalaxyLedger::Database.stale_entries(ledger_session_id)
      results.should be_empty
    end

    it "returns empty for empty session_id" do
      GalaxyLedger::Database.stale_entries(0_i64).should be_empty
    end

    it "does not return entries from other sessions" do
      marker = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
        metadata: JSON.parse({"extraction_type" => "guideline"}.to_json),
      )
      lid_other = GalaxyLedger::Database.create_session("sess-other-stale")
      GalaxyLedger::Database.insert(lid_other, marker)
      GalaxyLedger::Database.mark_entries_stale(lid_other, "/home/user/agent-guidelines/ruby-style.md")

      lid_different = GalaxyLedger::Database.create_session("sess-different")
      results = GalaxyLedger::Database.stale_entries(lid_different)
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
      ledger_session_id = GalaxyLedger::Database.create_session("sess-del")
      GalaxyLedger::Database.insert(ledger_session_id, marker)
      GalaxyLedger::Database.insert(ledger_session_id, extracted)

      deleted = GalaxyLedger::Database.delete_entries_by_source_file(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md")
      deleted.should eq(2)

      # Verify they're gone
      GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md").should be_false
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
      ledger_session_id = GalaxyLedger::Database.create_session("sess-del2")
      GalaxyLedger::Database.insert(ledger_session_id, marker1)
      GalaxyLedger::Database.insert(ledger_session_id, marker2)

      deleted = GalaxyLedger::Database.delete_entries_by_source_file(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md")
      deleted.should eq(1)

      # rspec-style.md marker should still exist
      GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/home/user/agent-guidelines/rspec-style.md").should be_true
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
      ledger_session_id = GalaxyLedger::Database.create_session("sess-del3")
      GalaxyLedger::Database.insert(ledger_session_id, marker)
      GalaxyLedger::Database.insert(ledger_session_id, learning)

      deleted = GalaxyLedger::Database.delete_entries_by_source_file(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md")
      deleted.should eq(1) # Only the extraction_marker

      GalaxyLedger::Database.count_by_session(ledger_session_id).should eq(1) # Learning survives
    end

    it "does not delete entries from other sessions" do
      entry = GalaxyLedger::Entry.new(
        entry_type: "extraction_marker",
        content: "/home/user/agent-guidelines/ruby-style.md",
        source_file: "/home/user/agent-guidelines/ruby-style.md",
      )
      lid_keep = GalaxyLedger::Database.create_session("sess-keep")
      GalaxyLedger::Database.insert(lid_keep, entry)

      lid_other = GalaxyLedger::Database.create_session("sess-other")
      deleted = GalaxyLedger::Database.delete_entries_by_source_file(lid_other, "/home/user/agent-guidelines/ruby-style.md")
      deleted.should eq(0)

      GalaxyLedger::Database.has_extracted_source_file?(lid_keep, "/home/user/agent-guidelines/ruby-style.md").should be_true
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
      ledger_session_id = GalaxyLedger::Database.create_session("sess-del-collision")
      GalaxyLedger::Database.insert(ledger_session_id, marker1)
      GalaxyLedger::Database.insert(ledger_session_id, marker2)

      # Delete one full path should not affect the other
      deleted = GalaxyLedger::Database.delete_entries_by_source_file(ledger_session_id, "/projects/kajabi/agent-guidelines/dev-setup.md")
      deleted.should eq(1)

      # The other path should still exist
      GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/projects/other/agent-guidelines/dev-setup.md").should be_true
    end

    it "returns 0 for empty inputs" do
      GalaxyLedger::Database.delete_entries_by_source_file(0_i64, "/home/user/agent-guidelines/ruby-style.md").should eq(0)
      ledger_session_id = GalaxyLedger::Database.create_session("sess")
      GalaxyLedger::Database.delete_entries_by_source_file(ledger_session_id, "").should eq(0)
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
      ledger_session_id = GalaxyLedger::Database.create_session("test-session")
      GalaxyLedger::Database.insert(ledger_session_id, entry1)
      GalaxyLedger::Database.insert(ledger_session_id, entry2)

      entries = GalaxyLedger::Database.query_by_session(ledger_session_id)

      entries.size.should eq(2)
      entries[0].content.should eq("Second") # Most recent first
      entries[1].content.should eq("First")
    end

    it "respects limit parameter" do
      ledger_session_id = GalaxyLedger::Database.create_session("test-session")
      5.times do |i|
        entry = GalaxyLedger::Entry.new(entry_type: "learning", content: "Entry #{i}")
        GalaxyLedger::Database.insert(ledger_session_id, entry)
      end

      entries = GalaxyLedger::Database.query_by_session(ledger_session_id, limit: 3)
      entries.size.should eq(3)
    end

    it "returns empty array for empty session_id" do
      GalaxyLedger::Database.query_by_session(0_i64).should be_empty
    end
  end

  describe ".query_by_type" do
    it "returns entries of specific type" do
      ledger_session_id = GalaxyLedger::Database.create_session("s1")
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "L1"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "decision", content: "D1"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "L2"))

      entries = GalaxyLedger::Database.query_by_type(ledger_session_id, "learning")

      entries.size.should eq(2)
      entries.all? { |e| e.entry_type == "learning" }.should be_true
    end
  end

  describe ".query_by_importance" do
    it "returns entries of specific importance" do
      ledger_session_id = GalaxyLedger::Database.create_session("s1")
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "L1", importance: "high"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "decision", content: "D1", importance: "medium"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "L2", importance: "high"))

      entries = GalaxyLedger::Database.query_by_importance(ledger_session_id, "high")

      entries.size.should eq(2)
      entries.all? { |e| e.importance == "high" }.should be_true
    end
  end

  describe ".search" do
    it "finds entries matching query" do
      ledger_session_id = GalaxyLedger::Database.create_session("s1")
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "JWT authentication tokens expire"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "decision", content: "Using Redis for caching"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "Database connection pooling"))

      entries = GalaxyLedger::Database.search("JWT authentication")

      entries.size.should eq(1)
      entries[0].content.should contain("JWT")
    end

    it "returns empty for no matches" do
      ledger_session_id = GalaxyLedger::Database.create_session("s1")
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "Something else"))

      entries = GalaxyLedger::Database.search("nonexistent term")
      entries.should be_empty
    end

    it "returns empty for empty query" do
      GalaxyLedger::Database.search("").should be_empty
      GalaxyLedger::Database.search("   ").should be_empty
    end

    it "searches across all sessions" do
      lid1 = GalaxyLedger::Database.create_session("s1")
      lid2 = GalaxyLedger::Database.create_session("s2")
      GalaxyLedger::Database.insert(lid1, GalaxyLedger::Entry.new(entry_type: "learning", content: "JWT in session 1"))
      GalaxyLedger::Database.insert(lid2, GalaxyLedger::Entry.new(entry_type: "learning", content: "JWT in session 2"))

      entries = GalaxyLedger::Database.search("JWT")
      entries.size.should eq(2)
    end
  end

  describe ".search_in_session" do
    it "searches within a specific session" do
      lid1 = GalaxyLedger::Database.create_session("s1")
      lid2 = GalaxyLedger::Database.create_session("s2")
      GalaxyLedger::Database.insert(lid1, GalaxyLedger::Entry.new(entry_type: "learning", content: "JWT in session 1"))
      GalaxyLedger::Database.insert(lid2, GalaxyLedger::Entry.new(entry_type: "learning", content: "JWT in session 2"))

      entries = GalaxyLedger::Database.search_in_session(lid1, "JWT")

      entries.size.should eq(1)
      entries[0].ledger_session_id.should eq(lid1)
    end

    it "returns empty for empty session_id" do
      GalaxyLedger::Database.search_in_session(0_i64, "query").should be_empty
    end
  end

  describe ".session_stats" do
    it "returns stats for all sessions" do
      lid1 = GalaxyLedger::Database.create_session("s1")
      lid2 = GalaxyLedger::Database.create_session("s2")
      GalaxyLedger::Database.insert(lid1, GalaxyLedger::Entry.new(entry_type: "learning", content: "L1"))
      GalaxyLedger::Database.insert(lid1, GalaxyLedger::Entry.new(entry_type: "decision", content: "D1"))
      GalaxyLedger::Database.insert(lid2, GalaxyLedger::Entry.new(entry_type: "learning", content: "L2"))

      stats = GalaxyLedger::Database.session_stats

      stats.size.should eq(2)
      s1_stat = stats.find { |s| s.ledger_session_id == lid1 }
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
        ledger_session_id = GalaxyLedger::Database.create_session("test-session")
        GalaxyLedger::Database.insert(ledger_session_id, original)

        # Query it back
        entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
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
      ledger_session_id = GalaxyLedger::Database.create_session("s1")
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "guideline", content: "Use trailing commas on multiline structures"))

      # "trail" should match "trailing" with prefix matching
      entries = GalaxyLedger::Database.search("trail")
      entries.size.should eq(1)
      entries[0].content.should contain("trailing")
    end

    it "respects prefix_match: false for exact matching" do
      ledger_session_id = GalaxyLedger::Database.create_session("s1")
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "guideline", content: "Use trailing commas"))

      # "trail" should NOT match "trailing" with exact matching
      entries = GalaxyLedger::Database.search("trail", prefix_match: false)
      entries.should be_empty
    end
  end

  describe ".search with filters" do
    before_each do
      ledger_session_id = GalaxyLedger::Database.create_session("s1")
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "JWT tokens expire", importance: "high"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "decision", content: "JWT storage in Redis", importance: "medium"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "guideline", content: "JWT best practices", importance: "high"))
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
      ledger_session_id = GalaxyLedger::Database.create_session("s1")
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "L1", importance: "high"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "decision", content: "D1", importance: "medium"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "L2", importance: "low"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "guideline", content: "G1", importance: "high"))
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
      ledger_session_id = GalaxyLedger::Database.create_session("s1")
      # Tier 1 entries
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "guideline", content: "G1", importance: "high"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "guideline", content: "G2", importance: "medium"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "implementation_plan", content: "IP1", importance: "high"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "decision", content: "D1 high", importance: "high"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "decision", content: "D2 medium", importance: "medium"))
      # Non-tier1 entries
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "L1", importance: "medium"))
      # Extraction markers should NOT appear in tier1 results
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "extraction_marker", content: "/home/user/agent-guidelines/ruby-style.md", importance: "medium", source_file: "/home/user/agent-guidelines/ruby-style.md"))
    end

    it "returns guidelines for the session" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s1").not_nil!
      result = GalaxyLedger::Database.query_tier1(ledger_session_id)
      result.guidelines.size.should eq(2)
    end

    it "returns implementation plans for the session" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s1").not_nil!
      result = GalaxyLedger::Database.query_tier1(ledger_session_id)
      result.implementation_plans.size.should eq(1)
    end

    it "excludes extraction_marker entries from guidelines" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s1").not_nil!
      result = GalaxyLedger::Database.query_tier1(ledger_session_id)
      all_types = result.guidelines.map(&.entry_type) + result.implementation_plans.map(&.entry_type) + result.high_importance_decisions.map(&.entry_type)
      all_types.should_not contain("extraction_marker")
    end

    it "returns only high-importance decisions" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s1").not_nil!
      result = GalaxyLedger::Database.query_tier1(ledger_session_id)
      result.high_importance_decisions.size.should eq(1)
      result.high_importance_decisions[0].importance.should eq("high")
    end

    it "respects decision limit" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s1").not_nil!
      # Add more high-importance decisions
      5.times do |i|
        GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "decision", content: "Extra D#{i}", importance: "high"))
      end

      result = GalaxyLedger::Database.query_tier1(ledger_session_id, decision_limit: 3)
      result.high_importance_decisions.size.should eq(3)
    end

    it "returns total count" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s1").not_nil!
      result = GalaxyLedger::Database.query_tier1(ledger_session_id)
      result.total_count.should eq(4) # 2 guidelines + 1 impl_plan + 1 high decision
    end

    it "returns empty results for empty session_id" do
      result = GalaxyLedger::Database.query_tier1(0_i64)
      result.total_count.should eq(0)
    end
  end

  describe ".query_tier2" do
    before_each do
      ledger_session_id = GalaxyLedger::Database.create_session("s1")
      # Tier 2 entries
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "L1", importance: "high"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "L2", importance: "medium"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "decision", content: "D1 medium", importance: "medium"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "decision", content: "D2 high", importance: "high"))
    end

    it "returns learnings for the session" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s1").not_nil!
      result = GalaxyLedger::Database.query_tier2(ledger_session_id)
      result.learnings.size.should eq(2)
    end

    it "returns only medium-importance decisions" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s1").not_nil!
      result = GalaxyLedger::Database.query_tier2(ledger_session_id)
      result.medium_decisions.size.should eq(1)
      result.medium_decisions[0].importance.should eq("medium")
    end

    it "respects limits" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s1").not_nil!
      # Add more learnings
      5.times do |i|
        GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "Extra L#{i}", importance: "medium"))
      end

      result = GalaxyLedger::Database.query_tier2(ledger_session_id, learnings_limit: 3)
      result.learnings.size.should eq(3)
    end

    it "returns total count" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s1").not_nil!
      result = GalaxyLedger::Database.query_tier2(ledger_session_id)
      result.total_count.should eq(3) # 2 learnings + 1 medium decision
    end
  end

  describe ".query_for_restoration" do
    before_each do
      ledger_session_id = GalaxyLedger::Database.create_session("s1")
      # Mix of tier 1 and tier 2 entries
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "guideline", content: "G1", importance: "high"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "implementation_plan", content: "IP1", importance: "high"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "decision", content: "D1 high", importance: "high"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "decision", content: "D2 medium", importance: "medium"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "L1", importance: "medium"))
    end

    it "returns both tier1 and tier2 results" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s1").not_nil!
      result = GalaxyLedger::Database.query_for_restoration(ledger_session_id)

      result.tier1.guidelines.size.should eq(1)
      result.tier1.implementation_plans.size.should eq(1)
      result.tier1.high_importance_decisions.size.should eq(1)

      result.tier2.learnings.size.should eq(1)
      result.tier2.medium_decisions.size.should eq(1)
    end

    it "returns combined total count" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s1").not_nil!
      result = GalaxyLedger::Database.query_for_restoration(ledger_session_id)
      result.total_count.should eq(5)
    end

    it "respects all limits" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s1").not_nil!
      result = GalaxyLedger::Database.query_for_restoration(
        ledger_session_id,
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
      ledger_session_id = GalaxyLedger::Database.create_session("s-excl")
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "guideline", content: "Use double-quotes for strings", importance: "high", source_file: "/home/user/agent-guidelines/ruby-style.md"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "JWT tokens expire after 15 min", importance: "medium"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "extraction_marker", content: "/home/user/agent-guidelines/ruby-style.md", importance: "medium", source_file: "/home/user/agent-guidelines/ruby-style.md"))
    end

    it "count excludes extraction_marker entries" do
      GalaxyLedger::Database.count.should eq(2)
    end

    it "count_by_session excludes extraction_marker entries" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s-excl").not_nil!
      GalaxyLedger::Database.count_by_session(ledger_session_id).should eq(2)
    end

    it "query_by_session excludes extraction_marker entries" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s-excl").not_nil!
      entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
      entries.size.should eq(2)
      entries.none? { |e| e.entry_type == "extraction_marker" }.should be_true
    end

    it "query_by_type returns extraction_marker entries when explicitly requested" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s-excl").not_nil!
      entries = GalaxyLedger::Database.query_by_type(ledger_session_id, "extraction_marker")
      entries.size.should eq(1)
      entries.first.entry_type.should eq("extraction_marker")
    end

    it "query_by_importance excludes extraction_marker entries" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s-excl").not_nil!
      entries = GalaxyLedger::Database.query_by_importance(ledger_session_id, "medium")
      entries.size.should eq(1)
      entries[0].entry_type.should eq("learning")
    end

    it "search excludes extraction_marker entries" do
      # The marker content is a file path containing "ruby-style" which is also in the guideline
      entries = GalaxyLedger::Database.search("ruby")
      entries.none? { |e| e.entry_type == "extraction_marker" }.should be_true
    end

    it "search_in_session excludes extraction_marker entries" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s-excl").not_nil!
      entries = GalaxyLedger::Database.search_in_session(ledger_session_id, "ruby")
      entries.none? { |e| e.entry_type == "extraction_marker" }.should be_true
    end

    it "query_recent_filtered excludes extraction_marker entries" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s-excl").not_nil!
      entries = GalaxyLedger::Database.query_recent_filtered(100, ledger_session_id: ledger_session_id)
      entries.size.should eq(2)
      entries.none? { |e| e.entry_type == "extraction_marker" }.should be_true
    end

    it "session_stats excludes extraction_marker entries from counts" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s-excl").not_nil!
      stats = GalaxyLedger::Database.session_stats
      stat = stats.find { |s| s.ledger_session_id == ledger_session_id }
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

        ledger_session_id = GalaxyLedger::Database.create_session("s1")
        GalaxyLedger::Database.insert(ledger_session_id, entry).should be_true

        entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
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

        ledger_session_id = GalaxyLedger::Database.create_session("s1")
        GalaxyLedger::Database.insert(ledger_session_id, entry).should be_true

        entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
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
        ledger_session_id = GalaxyLedger::Database.create_session("s1")
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
        GalaxyLedger::Database.insert(ledger_session_id, entry1)
        GalaxyLedger::Database.insert(ledger_session_id, entry2)
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
        ledger_session_id = GalaxyLedger::Database.create_session("s1")
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
        GalaxyLedger::Database.insert(ledger_session_id, entry1)
        GalaxyLedger::Database.insert(ledger_session_id, entry2)
        GalaxyLedger::Database.insert(ledger_session_id, entry3)
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
        ledger_session_id = GalaxyLedger::Database.create_session("s1")
        GalaxyLedger::Database.insert(ledger_session_id, entry)

        ledger_entry = GalaxyLedger::Database.query_by_session(ledger_session_id).first
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

  describe ".create_session" do
    it "creates a new session record and returns the PK" do
      id = GalaxyLedger::Database.create_session("sess-create-1")

      id.should be > 0_i64
    end

    it "creates two different sessions for the same identifier" do
      id1 = GalaxyLedger::Database.create_session("sess-create-2")
      id2 = GalaxyLedger::Database.create_session("sess-create-2b")

      id1.should_not eq(id2)
    end

    it "stores optional cwd, project_dir, git_branch" do
      GalaxyLedger::Database.create_session(
        "sess-create-3",
        cwd: "/home/user/project1",
        project_dir: "/home/user/project1",
        git_branch: "main",
      )

      session = GalaxyLedger::Database.get_session("sess-create-3")
      session.should_not be_nil
      session.not_nil!.cwd.should eq("/home/user/project1")
      session.not_nil!.project_dir.should eq("/home/user/project1")
      session.not_nil!.git_branch.should eq("main")
    end

    it "updates existing values via update_session" do
      ledger_session_id = GalaxyLedger::Database.create_session(
        "sess-create-4",
        cwd: "/home/user/project1",
        project_dir: "/home/user/project1",
      )
      # Update with nil cwd — should keep old value via COALESCE
      GalaxyLedger::Database.update_session(ledger_session_id)

      session = GalaxyLedger::Database.get_session("sess-create-4")
      session.should_not be_nil
      session.not_nil!.cwd.should eq("/home/user/project1")
    end

    it "returns 0 for empty session_identifier" do
      id = GalaxyLedger::Database.create_session("")
      id.should eq(0_i64)
    end
  end

  describe ".ensure_session" do
    it "returns existing session PK when identifier is already registered" do
      id1 = GalaxyLedger::Database.create_session("sess-ensure-1")
      id2 = GalaxyLedger::Database.ensure_session("sess-ensure-1")

      id1.should eq(id2)
    end

    it "creates a new session when identifier is not registered" do
      id = GalaxyLedger::Database.ensure_session("sess-ensure-new")
      id.should be > 0_i64
    end

    it "returns 0 for empty session_identifier" do
      id = GalaxyLedger::Database.ensure_session("")
      id.should eq(0_i64)
    end
  end

  describe ".update_session_metrics" do
    it "updates metrics from a ContextStatus object" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-metrics-1")

      status_json = %({"session_id":"sess-metrics-1","timestamp":1000,"model":{"id":"claude-opus-4-6","display_name":"Claude Opus 4.6"},"claude_version":"1.0.20","context":{"percentage":42.5,"tokens_used":50000,"tokens_max":200000},"cost":{"usd":0.15,"lines_added":100,"lines_removed":25}})
      status = GalaxyLedger::ContextStatus.from_json(status_json)

      result = GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)
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
      ledger_session_id = GalaxyLedger::Database.create_session("sess-metrics-pd")

      status_json = %({"session_id":"sess-metrics-pd","cwd":"/home/user/project/subdir","git_branch":"kr/feature-01","workspace":{"project_dir":"/home/user/project"},"context":{"percentage":30.0}})
      status = GalaxyLedger::ContextStatus.from_json(status_json)

      result = GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)
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
      ledger_session_id = GalaxyLedger::Database.create_session("sess-metrics-preserve",
        cwd: "/existing/dir",
        project_dir: "/existing/project",
        git_branch: "main",
      )

      # Update with nil cwd, project_dir, and git_branch — should preserve existing
      status_json = %({"context":{"percentage":55.0}})
      status = GalaxyLedger::ContextStatus.from_json(status_json)

      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

      session = GalaxyLedger::Database.get_session("sess-metrics-preserve")
      session.should_not be_nil
      s = session.not_nil!
      s.cwd.should eq("/existing/dir")
      s.project_dir.should eq("/existing/project")
      s.git_branch.should eq("main")
      s.context_percentage.should eq(55.0)
    end

    it "saves previous_cwd in context JSON before overwriting cwd" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-metrics-prev-cwd",
        cwd: "/home/user/projects/galaxy",
      )

      # Simulate status line pushing a new cwd (e.g., after context reset)
      status_json = %({"cwd":"/home/user/projects/kajabi","context":{"percentage":10.0}})
      status = GalaxyLedger::ContextStatus.from_json(status_json)

      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

      session = GalaxyLedger::Database.get_session("sess-metrics-prev-cwd")
      session.should_not be_nil
      s = session.not_nil!
      # cwd should be the new value
      s.cwd.should eq("/home/user/projects/kajabi")
      # previous_cwd should be the old value, saved in context JSON
      ctx = JSON.parse(s.context)
      ctx["previous_cwd"]?.should_not be_nil
      ctx["previous_cwd"].as_s.should eq("/home/user/projects/galaxy")
    end

    it "preserves previous_cwd across successive cwd updates" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-metrics-prev-chain",
        cwd: "/dir/a",
      )

      # First update: /dir/a → /dir/b
      status1 = GalaxyLedger::ContextStatus.from_json(%({"cwd":"/dir/b","context":{"percentage":20.0}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status1)

      s1 = GalaxyLedger::Database.get_session("sess-metrics-prev-chain").not_nil!
      JSON.parse(s1.context)["previous_cwd"].as_s.should eq("/dir/a")

      # Second update: /dir/b → /dir/c
      status2 = GalaxyLedger::ContextStatus.from_json(%({"cwd":"/dir/c","context":{"percentage":30.0}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status2)

      s2 = GalaxyLedger::Database.get_session("sess-metrics-prev-chain").not_nil!
      s2.cwd.should eq("/dir/c")
      JSON.parse(s2.context)["previous_cwd"].as_s.should eq("/dir/b")
    end

    it "does not overwrite previous_cwd when cwd is unchanged" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-metrics-same-cwd",
        cwd: "/dir/original",
      )

      # First update: /dir/original → /dir/new (previous_cwd = /dir/original)
      status1 = GalaxyLedger::ContextStatus.from_json(%({"cwd":"/dir/new","context":{"percentage":20.0}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status1)

      s1 = GalaxyLedger::Database.get_session("sess-metrics-same-cwd").not_nil!
      JSON.parse(s1.context)["previous_cwd"].as_s.should eq("/dir/original")

      # Second update: same cwd /dir/new — previous_cwd should stay /dir/original
      status2 = GalaxyLedger::ContextStatus.from_json(%({"cwd":"/dir/new","context":{"percentage":30.0}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status2)

      s2 = GalaxyLedger::Database.get_session("sess-metrics-same-cwd").not_nil!
      s2.cwd.should eq("/dir/new")
      JSON.parse(s2.context)["previous_cwd"].as_s.should eq("/dir/original")
    end

    it "does not overwrite context JSON when cwd is null" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-metrics-no-cwd")

      # No cwd in the status update — context should remain untouched
      status_json = %({"context":{"percentage":50.0}})
      status = GalaxyLedger::ContextStatus.from_json(status_json)

      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

      session = GalaxyLedger::Database.get_session("sess-metrics-no-cwd").not_nil!
      ctx = JSON.parse(session.context)
      ctx["previous_cwd"]?.should be_nil
    end

    it "preserves existing context keys when saving previous_cwd" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-metrics-ctx-merge",
        cwd: "/home/user/galaxy",
      )
      # Pre-populate context with an existing key
      GalaxyLedger::Database.merge_session_context(ledger_session_id, "injected_context", "some data")

      status = GalaxyLedger::ContextStatus.from_json(%({"cwd":"/home/user/kajabi","context":{"percentage":10.0}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

      session = GalaxyLedger::Database.get_session("sess-metrics-ctx-merge").not_nil!
      ctx = JSON.parse(session.context)
      ctx["injected_context"].as_s.should eq("some data")
      ctx["previous_cwd"].as_s.should eq("/home/user/galaxy")
    end

    it "returns false for empty session_identifier" do
      status_json = %({"session_id":"x"})
      status = GalaxyLedger::ContextStatus.from_json(status_json)

      result = GalaxyLedger::Database.update_session_metrics(0_i64, status)
      result.should be_false
    end
  end

  describe ".stamp_stop_cwd" do
    it "writes last_stop_cwd into context JSON" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-stop-cwd-basic",
        cwd: "/home/user/projects/kajabi",
      )

      result = GalaxyLedger::Database.stamp_stop_cwd(ledger_session_id, "/home/user/projects/galaxy")
      result.should be_true

      session = GalaxyLedger::Database.get_session("sess-stop-cwd-basic").not_nil!
      ctx = JSON.parse(session.context)
      ctx["last_stop_cwd"]?.should_not be_nil
      ctx["last_stop_cwd"].as_s.should eq("/home/user/projects/galaxy")
    end

    it "overwrites last_stop_cwd on successive calls" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-stop-cwd-overwrite")

      GalaxyLedger::Database.stamp_stop_cwd(ledger_session_id, "/dir/first")
      GalaxyLedger::Database.stamp_stop_cwd(ledger_session_id, "/dir/second")

      session = GalaxyLedger::Database.get_session("sess-stop-cwd-overwrite").not_nil!
      ctx = JSON.parse(session.context)
      ctx["last_stop_cwd"].as_s.should eq("/dir/second")
    end

    it "preserves existing context keys when stamping" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-stop-cwd-preserve")
      GalaxyLedger::Database.merge_session_context(ledger_session_id, "injected_context", "some data")

      GalaxyLedger::Database.stamp_stop_cwd(ledger_session_id, "/home/user/galaxy")

      session = GalaxyLedger::Database.get_session("sess-stop-cwd-preserve").not_nil!
      ctx = JSON.parse(session.context)
      ctx["injected_context"].as_s.should eq("some data")
      ctx["last_stop_cwd"].as_s.should eq("/home/user/galaxy")
    end

    it "coexists with previous_cwd from status line updates" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-stop-cwd-coexist",
        cwd: "/dir/original",
      )

      # Status line changes cwd, setting previous_cwd
      status = GalaxyLedger::ContextStatus.from_json(%({"cwd":"/dir/new","context":{"percentage":10.0}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

      # Stop hook stamps last_stop_cwd
      GalaxyLedger::Database.stamp_stop_cwd(ledger_session_id, "/dir/stop")

      session = GalaxyLedger::Database.get_session("sess-stop-cwd-coexist").not_nil!
      ctx = JSON.parse(session.context)
      ctx["previous_cwd"].as_s.should eq("/dir/original")
      ctx["last_stop_cwd"].as_s.should eq("/dir/stop")
    end

    it "returns false for empty cwd" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-stop-cwd-empty")

      result = GalaxyLedger::Database.stamp_stop_cwd(ledger_session_id, "")
      result.should be_false
    end

    it "returns false for invalid session ID" do
      result = GalaxyLedger::Database.stamp_stop_cwd(0_i64, "/some/dir")
      result.should be_false

      result = GalaxyLedger::Database.stamp_stop_cwd(-1_i64, "/some/dir")
      result.should be_false
    end

    it "is not clobbered by a subsequent status line update" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-stop-cwd-no-clobber",
        cwd: "/dir/working",
      )

      # Stop hook stamps last_stop_cwd
      GalaxyLedger::Database.stamp_stop_cwd(ledger_session_id, "/dir/working")

      # Status line fires after reset with project root cwd
      status = GalaxyLedger::ContextStatus.from_json(%({"cwd":"/dir/project-root","context":{"percentage":5.0}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

      session = GalaxyLedger::Database.get_session("sess-stop-cwd-no-clobber").not_nil!
      ctx = JSON.parse(session.context)
      # last_stop_cwd should survive — status line only touches previous_cwd
      ctx["last_stop_cwd"].as_s.should eq("/dir/working")
      # previous_cwd reflects the pre-reset cwd (correct for its purpose)
      ctx["previous_cwd"].as_s.should eq("/dir/working")
      # live cwd is now the project root (post-reset)
      session.cwd.should eq("/dir/project-root")
    end
  end

  describe ".update_session_title" do
    it "writes title to DB when provided" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-title-write")

      result = GalaxyLedger::Database.update_session_title(ledger_session_id, "Checkout Upsells Theming")
      result.should be_true

      session = GalaxyLedger::Database.get_session("sess-title-write")
      session.should_not be_nil
      session.not_nil!.title.should eq("Checkout Upsells Theming")
    end

    it "overwrites existing title with new value" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-title-overwrite")

      GalaxyLedger::Database.update_session_title(ledger_session_id, "Original Title")
      GalaxyLedger::Database.update_session_title(ledger_session_id, "Updated Title")

      session = GalaxyLedger::Database.get_session("sess-title-overwrite")
      session.should_not be_nil
      session.not_nil!.title.should eq("Updated Title")
    end

    it "returns false for nil title" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-title-nil")

      result = GalaxyLedger::Database.update_session_title(ledger_session_id, nil)
      result.should be_false
    end

    it "returns false for invalid session ID (0)" do
      result = GalaxyLedger::Database.update_session_title(0_i64, "Some Title")
      result.should be_false
    end

    it "returns false for negative session ID" do
      result = GalaxyLedger::Database.update_session_title(-1_i64, "Some Title")
      result.should be_false
    end
  end

  describe ".merge_session_context" do
    it "adds a key to the session context JSON" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-ctx-1")

      result = GalaxyLedger::Database.merge_session_context(ledger_session_id, "initial_task", "Fix the bug")
      result.should be_true

      session = GalaxyLedger::Database.get_session("sess-ctx-1")
      session.should_not be_nil
      ctx = JSON.parse(session.not_nil!.context)
      ctx["initial_task"].as_s.should eq("Fix the bug")
    end

    it "merges multiple keys into context" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-ctx-2")

      GalaxyLedger::Database.merge_session_context(ledger_session_id, "key1", "value1")
      GalaxyLedger::Database.merge_session_context(ledger_session_id, "key2", "value2")

      session = GalaxyLedger::Database.get_session("sess-ctx-2")
      ctx = JSON.parse(session.not_nil!.context)
      ctx["key1"].as_s.should eq("value1")
      ctx["key2"].as_s.should eq("value2")
    end

    it "overwrites existing key when write_once is false" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-ctx-3")

      GalaxyLedger::Database.merge_session_context(ledger_session_id, "key1", "original")
      GalaxyLedger::Database.merge_session_context(ledger_session_id, "key1", "updated", write_once: false)

      session = GalaxyLedger::Database.get_session("sess-ctx-3")
      ctx = JSON.parse(session.not_nil!.context)
      ctx["key1"].as_s.should eq("updated")
    end

    it "does not overwrite existing key when write_once is true" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-ctx-4")

      GalaxyLedger::Database.merge_session_context(ledger_session_id, "key1", "original")
      GalaxyLedger::Database.merge_session_context(ledger_session_id, "key1", "should-not-appear", write_once: true)

      session = GalaxyLedger::Database.get_session("sess-ctx-4")
      ctx = JSON.parse(session.not_nil!.context)
      ctx["key1"].as_s.should eq("original")
    end

    it "returns false for empty session_identifier" do
      result = GalaxyLedger::Database.merge_session_context(0_i64, "key", "value")
      result.should be_false
    end
  end

  describe ".update_session_last_interaction" do
    it "stores JSON string as last_interaction" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-li-1")

      json = %({"type":"tool_use","tool":"Read","timestamp":1234567890})
      result = GalaxyLedger::Database.update_session_last_interaction(ledger_session_id, json)
      result.should be_true

      session = GalaxyLedger::Database.get_session("sess-li-1")
      session.should_not be_nil
      session.not_nil!.last_interaction.should eq(json)
    end

    it "returns false for empty session_identifier" do
      result = GalaxyLedger::Database.update_session_last_interaction(0_i64, "{}")
      result.should be_false
    end
  end

  # ============================================================
  # Session File Operations
  # ============================================================

  describe ".upsert_session_file" do
    it "inserts a file read record" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-file-1")

      result = GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/path/to/file.cr", :read)
      result.should be_true

      files = GalaxyLedger::Database.session_files(ledger_session_id)
      files.size.should eq(1)
      files[0].file_path.should eq("/path/to/file.cr")
      files[0].is_read.should be_true
      files[0].is_edited.should be_false
      files[0].is_written.should be_false
      files[0].is_searched.should be_false
      files[0].access_count.should eq(1_i64)
    end

    it "inserts a file edit record" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-file-2")

      result = GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/path/to/file.cr", :edit)
      result.should be_true

      files = GalaxyLedger::Database.session_files(ledger_session_id)
      files.size.should eq(1)
      files[0].is_edited.should be_true
    end

    it "inserts a file write record" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-file-3")

      result = GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/path/to/file.cr", :write)
      result.should be_true

      files = GalaxyLedger::Database.session_files(ledger_session_id)
      files.size.should eq(1)
      files[0].is_written.should be_true
    end

    it "inserts a search record with pattern" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-file-4")

      result = GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/path/to/dir", :search, search_pattern: "TODO")
      result.should be_true

      files = GalaxyLedger::Database.session_files(ledger_session_id)
      files.size.should eq(1)
      files[0].is_searched.should be_true
      files[0].search_pattern.should eq("TODO")
    end

    it "deduplicates on (ledger_session_id, file_path, search_pattern) and increments access_count" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-file-5")

      GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/path/to/file.cr", :read)
      GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/path/to/file.cr", :read)

      files = GalaxyLedger::Database.session_files(ledger_session_id)
      files.size.should eq(1)
      files[0].access_count.should eq(2_i64)
    end

    it "accumulates operation flags across upserts" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-file-6")

      GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/path/to/file.cr", :read)
      GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/path/to/file.cr", :edit)

      files = GalaxyLedger::Database.session_files(ledger_session_id)
      files.size.should eq(1)
      files[0].is_read.should be_true
      files[0].is_edited.should be_true
    end

    it "returns false for empty session_identifier" do
      result = GalaxyLedger::Database.upsert_session_file(0_i64, "/path/to/file.cr", :read)
      result.should be_false
    end

    it "returns false for empty file_path" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-file-7")
      result = GalaxyLedger::Database.upsert_session_file(ledger_session_id, "", :read)
      result.should be_false
    end
  end

  describe ".get_session" do
    it "returns the session record when found" do
      GalaxyLedger::Database.create_session("sess-get-1", cwd: "/home/user/proj1")

      session = GalaxyLedger::Database.get_session("sess-get-1")
      session.should_not be_nil
      session.not_nil!.current_session_identifier.should eq("sess-get-1")
      session.not_nil!.cwd.should eq("/home/user/proj1")
      session.not_nil!.title.should be_nil
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
      GalaxyLedger::Database.create_session("sess-list-1")
      GalaxyLedger::Database.create_session("sess-list-2")
      GalaxyLedger::Database.create_session("sess-list-3")

      sessions = GalaxyLedger::Database.list_sessions
      sessions.size.should eq(3)
      identifiers = sessions.map(&.current_session_identifier)
      identifiers.should contain("sess-list-1")
      identifiers.should contain("sess-list-2")
      identifiers.should contain("sess-list-3")
    end

    it "respects limit parameter" do
      5.times do |i|
        GalaxyLedger::Database.create_session("sess-limit-#{i}")
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

  describe ".session_identifiers" do
    it "returns all identifiers registered to a session" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-ids-1")
      # create_session registers "sess-ids-1" automatically
      GalaxyLedger::Database.register_session_identifier(ledger_session_id, "extra-id-1")
      GalaxyLedger::Database.register_session_identifier(ledger_session_id, "extra-id-2")

      ids = GalaxyLedger::Database.session_identifiers(ledger_session_id)
      ids.size.should eq(3)
      ids.should contain("sess-ids-1")
      ids.should contain("extra-id-1")
      ids.should contain("extra-id-2")
    end

    it "returns array with just the create_session identifier when no extras registered" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-ids-2")

      ids = GalaxyLedger::Database.session_identifiers(ledger_session_id)
      ids.size.should eq(1)
      ids.should contain("sess-ids-2")
    end

    it "returns empty array for invalid session id" do
      GalaxyLedger::Database.session_identifiers(0_i64).should be_empty
      GalaxyLedger::Database.session_identifiers(-1_i64).should be_empty
    end
  end

  describe ".session_pids" do
    it "returns all PIDs registered to a session" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-pids-1", claude_pid: 12345_i64)
      GalaxyLedger::Database.register_claude_pid(ledger_session_id, 67890_i64)

      pids = GalaxyLedger::Database.session_pids(ledger_session_id)
      pids.size.should eq(2)
      pids.should contain(12345_i64)
      pids.should contain(67890_i64)
    end

    it "returns empty array for session with no PIDs" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-pids-2")

      pids = GalaxyLedger::Database.session_pids(ledger_session_id)
      pids.should be_empty
    end

    it "returns empty array for invalid session id" do
      GalaxyLedger::Database.session_pids(0_i64).should be_empty
      GalaxyLedger::Database.session_pids(-1_i64).should be_empty
    end
  end

  describe ".session_files" do
    it "returns file records for a session" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-files-1")
      GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/path/to/file1.cr", :read)
      GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/path/to/file2.cr", :edit)

      files = GalaxyLedger::Database.session_files(ledger_session_id)
      files.size.should eq(2)
      file_paths = files.map(&.file_path)
      file_paths.should contain("/path/to/file1.cr")
      file_paths.should contain("/path/to/file2.cr")
    end

    it "returns empty array for empty session_identifier" do
      files = GalaxyLedger::Database.session_files(0_i64)
      files.should be_empty
    end

    it "returns empty array when no files tracked" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-files-2")
      files = GalaxyLedger::Database.session_files(ledger_session_id)
      files.should be_empty
    end
  end

  describe ".delete_session cascade" do
    it "cascade deletes session_files along with entries" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-cascade-1")
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "L1"))
      GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/path/to/file.cr", :read)

      # Verify data exists before delete
      GalaxyLedger::Database.count_by_session(ledger_session_id).should eq(1)
      GalaxyLedger::Database.session_files(ledger_session_id).size.should eq(1)

      deleted = GalaxyLedger::Database.delete_session("sess-cascade-1")
      deleted.should eq(1)

      # Verify cascade: entries gone
      GalaxyLedger::Database.count_by_session(ledger_session_id).should eq(0)
      # Verify cascade: files gone
      GalaxyLedger::Database.session_files(ledger_session_id).should be_empty
      # Verify cascade: session record gone
      GalaxyLedger::Database.get_session("sess-cascade-1").should be_nil
    end
  end

  # ============================================================
  # Daily Usage Recording
  # ============================================================

  describe "daily usage recording" do
    it "creates a daily usage record on first metrics update" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-daily-1")

      status = GalaxyLedger::ContextStatus.from_json(%({"context":{"tokens_used":5000},"cost":{"usd":0.50}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

      today = Time.utc.to_s("%Y-%m-%d")
      daily = GalaxyLedger::Database.spend_daily(today, today)
      daily.size.should eq(1)
      daily[0].cost.should eq(0.50)
      daily[0].tokens.should eq(5000_i64)
    end

    it "updates cumulative values on same-day updates" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-daily-2")

      # First update
      status1 = GalaxyLedger::ContextStatus.from_json(%({"context":{"tokens_used":5000},"cost":{"usd":0.50}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status1)

      # Second update — cost and tokens increase
      status2 = GalaxyLedger::ContextStatus.from_json(%({"context":{"tokens_used":12000},"cost":{"usd":1.20}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status2)

      today = Time.utc.to_s("%Y-%m-%d")
      daily = GalaxyLedger::Database.spend_daily(today, today)
      daily.size.should eq(1)
      # Cost: recalculated from baseline (0.0) → 1.20
      daily[0].cost.should eq(1.20)
      # Tokens: cumulative from incremental diffs: 5000 + 7000 = 12000
      daily[0].tokens.should eq(12000_i64)
    end

    it "handles compaction correctly — tokens drop, cumulative preserved" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-daily-compact")

      # Update 1: tokens=5000
      status1 = GalaxyLedger::ContextStatus.from_json(%({"context":{"tokens_used":5000},"cost":{"usd":0.50}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status1)

      # Update 2: tokens=12000
      status2 = GalaxyLedger::ContextStatus.from_json(%({"context":{"tokens_used":12000},"cost":{"usd":1.00}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status2)

      # Update 3: tokens=3000 (COMPACTION — tokens dropped)
      status3 = GalaxyLedger::ContextStatus.from_json(%({"context":{"tokens_used":3000},"cost":{"usd":1.50}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status3)

      # Update 4: tokens=9000
      status4 = GalaxyLedger::ContextStatus.from_json(%({"context":{"tokens_used":9000},"cost":{"usd":2.00}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status4)

      today = Time.utc.to_s("%Y-%m-%d")
      daily = GalaxyLedger::Database.spend_daily(today, today)
      daily.size.should eq(1)
      # Cost: monotonic, just 2.00 - 0.0 = 2.00
      daily[0].cost.should eq(2.00)
      # Tokens: 5000 + 7000 + 0(compaction) + 6000 = 18000
      daily[0].tokens.should eq(18000_i64)
    end

    it "tracks multiple sessions independently on same day" do
      lid1 = GalaxyLedger::Database.create_session("sess-daily-multi-1")
      lid2 = GalaxyLedger::Database.create_session("sess-daily-multi-2")

      status1 = GalaxyLedger::ContextStatus.from_json(%({"context":{"tokens_used":5000},"cost":{"usd":1.00}}))
      status2 = GalaxyLedger::ContextStatus.from_json(%({"context":{"tokens_used":3000},"cost":{"usd":0.75}}))

      GalaxyLedger::Database.update_session_metrics(lid1, status1)
      GalaxyLedger::Database.update_session_metrics(lid2, status2)

      today = Time.utc.to_s("%Y-%m-%d")
      summary = GalaxyLedger::Database.spend_summary(today, today)
      summary.total_cost.should eq(1.75)
      summary.total_tokens.should eq(8000_i64)
      summary.active_sessions.should eq(2)
      summary.active_days.should eq(1)
    end

    it "handles nil cost and token values gracefully" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-daily-nil")

      # Both nil — should skip recording
      status = GalaxyLedger::ContextStatus.from_json(%({"context":{"percentage":42.0}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

      today = Time.utc.to_s("%Y-%m-%d")
      daily = GalaxyLedger::Database.spend_daily(today, today)
      daily.size.should eq(0)
    end

    it "handles nil tokens with non-nil cost" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-daily-partial")

      status = GalaxyLedger::ContextStatus.from_json(%({"cost":{"usd":0.50}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

      today = Time.utc.to_s("%Y-%m-%d")
      daily = GalaxyLedger::Database.spend_daily(today, today)
      daily.size.should eq(1)
      daily[0].cost.should eq(0.50)
      daily[0].tokens.should eq(0_i64)
    end

    it "returns empty results for date range with no data" do
      GalaxyLedger::Database.ensure_database_exists
      summary = GalaxyLedger::Database.spend_summary("2020-01-01", "2020-01-31")
      summary.total_cost.should eq(0.0)
      summary.total_tokens.should eq(0_i64)
      summary.active_days.should eq(0)
      summary.active_sessions.should eq(0)

      daily = GalaxyLedger::Database.spend_daily("2020-01-01", "2020-01-31")
      daily.should be_empty
    end

    it "computes correct avg daily cost" do
      lid = GalaxyLedger::Database.create_session("sess-daily-avg")

      # Simulate two different days by inserting directly
      GalaxyLedger::Database.open do |db|
        db.exec(
          <<-SQL,
            INSERT INTO ledger_session_daily_usages (
              ledger_session_id, date,
              baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
              baseline_tokens, current_tokens, cumulative_tokens
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          lid, "2025-02-01", 0.0, 6.0, 6.0, 0_i64, 100_i64, 100_i64,
        )
        db.exec(
          <<-SQL,
            INSERT INTO ledger_session_daily_usages (
              ledger_session_id, date,
              baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
              baseline_tokens, current_tokens, cumulative_tokens
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          lid, "2025-02-02", 6.0, 10.0, 4.0, 100_i64, 200_i64, 100_i64,
        )
      end

      avg = GalaxyLedger::Database.spend_avg_daily("2025-02-01", "2025-02-02")
      # (6.0 + 4.0) / 2 = 5.0
      avg.should eq(5.0)
    end

    it "cascades daily usage records on session delete" do
      lid = GalaxyLedger::Database.create_session("sess-daily-cascade")

      status = GalaxyLedger::ContextStatus.from_json(%({"context":{"tokens_used":5000},"cost":{"usd":1.00}}))
      GalaxyLedger::Database.update_session_metrics(lid, status)

      today = Time.utc.to_s("%Y-%m-%d")
      GalaxyLedger::Database.spend_daily(today, today).size.should eq(1)

      GalaxyLedger::Database.delete_session("sess-daily-cascade")

      GalaxyLedger::Database.spend_daily(today, today).size.should eq(0)
    end
  end

  # ============================================================
  # Spend Aggregation Queries
  # ============================================================

  describe ".spend_summary" do
    it "aggregates across multiple sessions and days" do
      lid1 = GalaxyLedger::Database.create_session("sess-agg-1")
      lid2 = GalaxyLedger::Database.create_session("sess-agg-2")

      GalaxyLedger::Database.open do |db|
        # Session 1, day 1
        db.exec(
          "INSERT INTO ledger_session_daily_usages (ledger_session_id, date, baseline_cost_usd, current_cost_usd, cumulative_cost_usd, baseline_tokens, current_tokens, cumulative_tokens) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
          lid1, "2025-02-01", 0.0, 5.0, 5.0, 0_i64, 1000_i64, 1000_i64,
        )
        # Session 1, day 2
        db.exec(
          "INSERT INTO ledger_session_daily_usages (ledger_session_id, date, baseline_cost_usd, current_cost_usd, cumulative_cost_usd, baseline_tokens, current_tokens, cumulative_tokens) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
          lid1, "2025-02-02", 5.0, 8.0, 3.0, 1000_i64, 2000_i64, 1000_i64,
        )
        # Session 2, day 1
        db.exec(
          "INSERT INTO ledger_session_daily_usages (ledger_session_id, date, baseline_cost_usd, current_cost_usd, cumulative_cost_usd, baseline_tokens, current_tokens, cumulative_tokens) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
          lid2, "2025-02-01", 0.0, 2.0, 2.0, 0_i64, 500_i64, 500_i64,
        )
      end

      summary = GalaxyLedger::Database.spend_summary("2025-02-01", "2025-02-28")
      summary.total_cost.should eq(10.0)   # 5 + 3 + 2
      summary.total_tokens.should eq(2500) # 1000 + 1000 + 500
      summary.active_days.should eq(2)     # Feb 1 and Feb 2
      summary.active_sessions.should eq(2) # Two sessions
    end
  end

  describe ".spend_daily" do
    it "groups by date and sums across sessions" do
      lid1 = GalaxyLedger::Database.create_session("sess-daily-grp-1")
      lid2 = GalaxyLedger::Database.create_session("sess-daily-grp-2")

      GalaxyLedger::Database.open do |db|
        db.exec(
          "INSERT INTO ledger_session_daily_usages (ledger_session_id, date, baseline_cost_usd, current_cost_usd, cumulative_cost_usd, baseline_tokens, current_tokens, cumulative_tokens) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
          lid1, "2025-02-01", 0.0, 3.0, 3.0, 0_i64, 100_i64, 100_i64,
        )
        db.exec(
          "INSERT INTO ledger_session_daily_usages (ledger_session_id, date, baseline_cost_usd, current_cost_usd, cumulative_cost_usd, baseline_tokens, current_tokens, cumulative_tokens) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
          lid2, "2025-02-01", 0.0, 2.0, 2.0, 0_i64, 50_i64, 50_i64,
        )
      end

      daily = GalaxyLedger::Database.spend_daily("2025-02-01", "2025-02-01")
      daily.size.should eq(1)
      daily[0].date.should eq("2025-02-01")
      daily[0].cost.should eq(5.0)       # 3 + 2
      daily[0].tokens.should eq(150_i64) # 100 + 50
    end
  end
end
