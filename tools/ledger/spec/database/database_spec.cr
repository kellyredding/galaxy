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
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "constraint", content: "Use trailing commas on multiline structures"))

      # "trail" should match "trailing" with prefix matching
      entries = GalaxyLedger::Database.search("trail")
      entries.size.should eq(1)
      entries[0].content.should contain("trailing")
    end

    it "respects prefix_match: false for exact matching" do
      ledger_session_id = GalaxyLedger::Database.create_session("s1")
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "constraint", content: "Use trailing commas"))

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
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "constraint", content: "JWT best practices", importance: "high"))
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
      entries = GalaxyLedger::Database.search("JWT", entry_type: "constraint", importance: "high")
      entries.size.should eq(1)
      entries[0].entry_type.should eq("constraint")
      entries[0].importance.should eq("high")
    end
  end

  describe ".query_recent_filtered" do
    before_each do
      ledger_session_id = GalaxyLedger::Database.create_session("s1")
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "L1", importance: "high"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "decision", content: "D1", importance: "medium"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "L2", importance: "low"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "constraint", content: "G1", importance: "high"))
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
      # Tier 1 entries: high-importance decisions only
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "decision", content: "D1 high", importance: "high"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "decision", content: "D2 medium", importance: "medium"))
      # Non-tier1 entries
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "L1", importance: "medium"))
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
      result.total_count.should eq(1) # 1 high decision
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
      # Tier 1 and tier 2 entries (guideline/implementation_plan entry types
      # are no longer created, but decisions and learnings still are)
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "decision", content: "D1 high", importance: "high"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "decision", content: "D2 medium", importance: "medium"))
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "L1", importance: "medium"))
    end

    it "returns both tier1 and tier2 results" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s1").not_nil!
      result = GalaxyLedger::Database.query_for_restoration(ledger_session_id)

      result.tier1.high_importance_decisions.size.should eq(1)

      result.tier2.learnings.size.should eq(1)
      result.tier2.medium_decisions.size.should eq(1)
    end

    it "returns combined total count" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s1").not_nil!
      result = GalaxyLedger::Database.query_for_restoration(ledger_session_id)
      result.total_count.should eq(3)
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
    # Seed a session with a mix of real entries and internal (legacy) entries.
    # Internal types (extraction_marker, guideline, implementation_plan) can no
    # longer be created through Entry.new (validation rejects them), but they
    # may exist in older databases. Insert them via raw SQL to simulate this.
    # All public-facing queries should exclude internal types implicitly.
    before_each do
      ledger_session_id = GalaxyLedger::Database.create_session("s-excl")
      # Insert legacy internal entries directly via SQL (bypasses Entry validation)
      GalaxyLedger::Database.open do |db|
        hash_gl = Digest::SHA256.hexdigest("guideline:Use double-quotes for strings")
        db.exec(
          "INSERT INTO ledger_entries (ledger_session_id, entry_type, content, importance, source_file, content_hash) VALUES (?, ?, ?, ?, ?, ?)",
          ledger_session_id, "guideline", "Use double-quotes for strings", "high",
          "/home/user/agent-guidelines/ruby-style.md", hash_gl,
        )
        hash_ip = Digest::SHA256.hexdigest("implementation_plan:Plan context")
        db.exec(
          "INSERT INTO ledger_entries (ledger_session_id, entry_type, content, importance, source_file, content_hash) VALUES (?, ?, ?, ?, ?, ?)",
          ledger_session_id, "implementation_plan", "Plan context", "high",
          "/home/user/implementation-plans/feature.md", hash_ip,
        )
        hash_em = Digest::SHA256.hexdigest("extraction_marker:/home/user/agent-guidelines/ruby-style.md")
        db.exec(
          "INSERT INTO ledger_entries (ledger_session_id, entry_type, content, importance, source_file, content_hash) VALUES (?, ?, ?, ?, ?, ?)",
          ledger_session_id, "extraction_marker", "/home/user/agent-guidelines/ruby-style.md", "medium",
          "/home/user/agent-guidelines/ruby-style.md", hash_em,
        )
      end
      # This is the only public entry
      GalaxyLedger::Database.insert(ledger_session_id, GalaxyLedger::Entry.new(entry_type: "learning", content: "JWT tokens expire after 15 min", importance: "medium"))
    end

    it "count excludes all internal entry types" do
      GalaxyLedger::Database.count.should eq(1)
    end

    it "count_by_session excludes all internal entry types" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s-excl").not_nil!
      GalaxyLedger::Database.count_by_session(ledger_session_id).should eq(1)
    end

    it "query_by_session excludes all internal entry types" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s-excl").not_nil!
      entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
      entries.size.should eq(1)
      entries.none? { |e| GalaxyLedger::Database::INTERNAL_ENTRY_TYPES.includes?(e.entry_type) }.should be_true
    end

    it "query_by_type returns internal entries when explicitly requested" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s-excl").not_nil!

      markers = GalaxyLedger::Database.query_by_type(ledger_session_id, "extraction_marker")
      markers.size.should eq(1)

      guidelines = GalaxyLedger::Database.query_by_type(ledger_session_id, "guideline")
      guidelines.size.should eq(1)

      plans = GalaxyLedger::Database.query_by_type(ledger_session_id, "implementation_plan")
      plans.size.should eq(1)
    end

    it "query_by_importance excludes all internal entry types" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s-excl").not_nil!
      entries = GalaxyLedger::Database.query_by_importance(ledger_session_id, "medium")
      entries.size.should eq(1)
      entries[0].entry_type.should eq("learning")
    end

    it "search excludes all internal entry types" do
      entries = GalaxyLedger::Database.search("ruby")
      entries.none? { |e| GalaxyLedger::Database::INTERNAL_ENTRY_TYPES.includes?(e.entry_type) }.should be_true
    end

    it "search_in_session excludes all internal entry types" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s-excl").not_nil!
      entries = GalaxyLedger::Database.search_in_session(ledger_session_id, "ruby")
      entries.none? { |e| GalaxyLedger::Database::INTERNAL_ENTRY_TYPES.includes?(e.entry_type) }.should be_true
    end

    it "query_recent_filtered excludes all internal entry types" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s-excl").not_nil!
      entries = GalaxyLedger::Database.query_recent_filtered(100, ledger_session_id: ledger_session_id)
      entries.size.should eq(1)
      entries.none? { |e| GalaxyLedger::Database::INTERNAL_ENTRY_TYPES.includes?(e.entry_type) }.should be_true
    end

    it "session_stats excludes all internal entry types from counts" do
      ledger_session_id = GalaxyLedger::Database.resolve_session_identifier("s-excl").not_nil!
      stats = GalaxyLedger::Database.session_stats
      stat = stats.find { |s| s.ledger_session_id == ledger_session_id }
      stat.should_not be_nil
      stat.not_nil!.entry_count.should eq(1)
    end
  end

  # ============================================================
  # Enhanced Schema Tests
  # ============================================================

  describe "Enhanced Schema" do
    describe ".insert with enhanced fields" do
      it "stores category, keywords, applies_when, source_file" do
        entry = GalaxyLedger::Entry.new(
          entry_type: "constraint",
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
          entry_type: "constraint",
          content: "Always use double-quotes for strings",
          importance: "medium",
          category: "ruby-style",
          keywords: ["ruby", "strings", "quotes", "formatting"],
          applies_when: "Writing Ruby code",
          source_file: "ruby-style.md"
        )
        entry2 = GalaxyLedger::Entry.new(
          entry_type: "constraint",
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
          entry_type: "constraint",
          content: "Ruby rule 1",
          importance: "medium",
          category: "ruby-style"
        )
        entry2 = GalaxyLedger::Entry.new(
          entry_type: "constraint",
          content: "RSpec rule 1",
          importance: "medium",
          category: "rspec"
        )
        entry3 = GalaxyLedger::Entry.new(
          entry_type: "constraint",
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
        entries = GalaxyLedger::Database.query_recent_filtered(100, entry_type: "constraint", category: "rspec")
        entries.size.should eq(1)
        entries[0].category.should eq("rspec")
      end
    end

    describe "StoredEntry#to_entry preserves enhanced fields" do
      it "converts with all enhanced fields" do
        entry = GalaxyLedger::Entry.new(
          entry_type: "constraint",
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
      status_json = %({"session_id":"spec-proc","context":{"percentage":55.0}})
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
      status_json = %({"session_id":"spec-proc","cwd":"/home/user/projects/my-app","context":{"percentage":10.0}})
      status = GalaxyLedger::ContextStatus.from_json(status_json)

      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

      session = GalaxyLedger::Database.get_session("sess-metrics-prev-cwd")
      session.should_not be_nil
      s = session.not_nil!
      # cwd should be the new value
      s.cwd.should eq("/home/user/projects/my-app")
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
      status1 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","cwd":"/dir/b","context":{"percentage":20.0}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status1)

      s1 = GalaxyLedger::Database.get_session("sess-metrics-prev-chain").not_nil!
      JSON.parse(s1.context)["previous_cwd"].as_s.should eq("/dir/a")

      # Second update: /dir/b → /dir/c
      status2 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","cwd":"/dir/c","context":{"percentage":30.0}}))
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
      status1 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","cwd":"/dir/new","context":{"percentage":20.0}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status1)

      s1 = GalaxyLedger::Database.get_session("sess-metrics-same-cwd").not_nil!
      JSON.parse(s1.context)["previous_cwd"].as_s.should eq("/dir/original")

      # Second update: same cwd /dir/new — previous_cwd should stay /dir/original
      status2 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","cwd":"/dir/new","context":{"percentage":30.0}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status2)

      s2 = GalaxyLedger::Database.get_session("sess-metrics-same-cwd").not_nil!
      s2.cwd.should eq("/dir/new")
      JSON.parse(s2.context)["previous_cwd"].as_s.should eq("/dir/original")
    end

    it "does not overwrite context JSON when cwd is null" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-metrics-no-cwd")

      # No cwd in the status update — context should remain untouched
      status_json = %({"session_id":"spec-proc","context":{"percentage":50.0}})
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

      status = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","cwd":"/home/user/my-app","context":{"percentage":10.0}}))
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
        cwd: "/home/user/projects/my-app",
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
      status = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","cwd":"/dir/new","context":{"percentage":10.0}}))
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
      status = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","cwd":"/dir/project-root","context":{"percentage":5.0}}))
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

  describe ".update_suggested_name" do
    it "writes suggested name to DB when provided" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-name-write")

      result = GalaxyLedger::Database.update_suggested_name(ledger_session_id, "Checkout Upsells Theming")
      result.should be_true

      session = GalaxyLedger::Database.get_session("sess-name-write")
      session.should_not be_nil
      session.not_nil!.suggested_name.should eq("Checkout Upsells Theming")
    end

    it "overwrites existing name with new value" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-name-overwrite")

      GalaxyLedger::Database.update_suggested_name(ledger_session_id, "Original Name")
      GalaxyLedger::Database.update_suggested_name(ledger_session_id, "Updated Name")

      session = GalaxyLedger::Database.get_session("sess-name-overwrite")
      session.should_not be_nil
      session.not_nil!.suggested_name.should eq("Updated Name")
    end

    it "returns false for nil name" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-name-nil")

      result = GalaxyLedger::Database.update_suggested_name(ledger_session_id, nil)
      result.should be_false
    end

    it "returns false for invalid session ID (0)" do
      result = GalaxyLedger::Database.update_suggested_name(0_i64, "Some Name")
      result.should be_false
    end

    it "returns false for negative session ID" do
      result = GalaxyLedger::Database.update_suggested_name(-1_i64, "Some Name")
      result.should be_false
    end
  end

  describe ".update_suggested_name_data" do
    it "writes state data to DB" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-name-data-write")

      data = %({"attempts":1,"quality":3,"finalized":false,"status":"awaiting_improvement"})
      result = GalaxyLedger::Database.update_suggested_name_data(ledger_session_id, data)
      result.should be_true

      session = GalaxyLedger::Database.get_session("sess-name-data-write")
      session.should_not be_nil
      session.not_nil!.suggested_name_data.should eq(data)
    end

    it "returns false for invalid session ID (0)" do
      result = GalaxyLedger::Database.update_suggested_name_data(0_i64, "{}")
      result.should be_false
    end
  end

  describe ".update_suggested_name_with_data" do
    it "writes both name and state data atomically" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-name-both")

      data = %({"attempts":1,"quality":4,"finalized":true,"status":"finalized_quality_met"})
      result = GalaxyLedger::Database.update_suggested_name_with_data(ledger_session_id, "Event System Design", data)
      result.should be_true

      session = GalaxyLedger::Database.get_session("sess-name-both")
      session.should_not be_nil
      session.not_nil!.suggested_name.should eq("Event System Design")
      session.not_nil!.suggested_name_data.should eq(data)
    end

    it "allows nil name (clears suggested name while updating data)" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-name-nil-both")

      GalaxyLedger::Database.update_suggested_name(ledger_session_id, "Old Name")
      data = %({"attempts":1,"quality":0,"finalized":false,"status":"code_detected"})
      result = GalaxyLedger::Database.update_suggested_name_with_data(ledger_session_id, nil, data)
      result.should be_true

      session = GalaxyLedger::Database.get_session("sess-name-nil-both")
      session.should_not be_nil
      session.not_nil!.suggested_name.should be_nil
      session.not_nil!.suggested_name_data.should eq(data)
    end

    it "returns false for invalid session ID (0)" do
      result = GalaxyLedger::Database.update_suggested_name_with_data(0_i64, "Name", "{}")
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

    it "preserves keys written by stamp_stop_cwd" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-ctx-coexist")

      # stamp_stop_cwd writes last_stop_cwd via its own json_set
      GalaxyLedger::Database.stamp_stop_cwd(ledger_session_id, "/home/user/galaxy")

      # merge_session_context writes a different key via json_set
      GalaxyLedger::Database.merge_session_context(ledger_session_id, "injected_context", "some data")

      session = GalaxyLedger::Database.get_session("sess-ctx-coexist").not_nil!
      ctx = JSON.parse(session.context)
      ctx["last_stop_cwd"].as_s.should eq("/home/user/galaxy")
      ctx["injected_context"].as_s.should eq("some data")
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
      session.not_nil!.suggested_name.should be_nil
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

      status = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":5000},"cost":{"usd":0.50}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

      today = GalaxyLedger::LedgerTime.today_str
      daily = GalaxyLedger::Database.spend_daily(today, today)
      daily.size.should eq(1)
      daily[0].cost.should eq(0.50)
      daily[0].tokens.should eq(5000_i64)
    end

    it "updates cumulative values on same-day updates" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-daily-2")

      # First update
      status1 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":5000},"cost":{"usd":0.50}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status1)

      # Second update — cost and tokens increase
      status2 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":12000},"cost":{"usd":1.20}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status2)

      today = GalaxyLedger::LedgerTime.today_str
      daily = GalaxyLedger::Database.spend_daily(today, today)
      daily.size.should eq(1)
      # Cost: 0.50 + (1.20 - 0.50) = 1.20 via dynamic diffing
      daily[0].cost.should eq(1.20)
      # Tokens: 5000 + (12000 - 5000) = 12000 via incremental diffs
      daily[0].tokens.should eq(12000_i64)
    end

    it "handles compaction correctly — tokens drop, cumulative preserved" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-daily-compact")

      # Update 1: tokens=5000
      status1 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":5000},"cost":{"usd":0.50}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status1)

      # Update 2: tokens=12000
      status2 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":12000},"cost":{"usd":1.00}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status2)

      # Update 3: tokens=3000 (COMPACTION — tokens dropped)
      status3 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":3000},"cost":{"usd":1.50}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status3)

      # Update 4: tokens=9000
      status4 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":9000},"cost":{"usd":2.00}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status4)

      today = GalaxyLedger::LedgerTime.today_str
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

      status1 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":5000},"cost":{"usd":1.00}}))
      status2 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":3000},"cost":{"usd":0.75}}))

      GalaxyLedger::Database.update_session_metrics(lid1, status1)
      GalaxyLedger::Database.update_session_metrics(lid2, status2)

      today = GalaxyLedger::LedgerTime.today_str
      summary = GalaxyLedger::Database.spend_summary(today, today)
      summary.total_cost.should eq(1.75)
      summary.total_tokens.should eq(8000_i64)
      summary.active_sessions.should eq(2)
      summary.active_days.should eq(1)
    end

    it "handles nil cost and token values gracefully" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-daily-nil")

      # Both nil — should skip recording
      status = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"percentage":42.0}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

      today = GalaxyLedger::LedgerTime.today_str
      daily = GalaxyLedger::Database.spend_daily(today, today)
      daily.size.should eq(0)
    end

    it "handles nil tokens with non-nil cost" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-daily-partial")

      status = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","cost":{"usd":0.50}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

      today = GalaxyLedger::LedgerTime.today_str
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
              ledger_session_id, date, process_key,
              baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
              baseline_tokens, current_tokens, cumulative_tokens
            ) VALUES (?, ?, 'spec-proc', ?, ?, ?, ?, ?, ?)
          SQL
          lid, "2025-02-01", 0.0, 6.0, 6.0, 0_i64, 100_i64, 100_i64,
        )
        db.exec(
          <<-SQL,
            INSERT INTO ledger_session_daily_usages (
              ledger_session_id, date, process_key,
              baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
              baseline_tokens, current_tokens, cumulative_tokens
            ) VALUES (?, ?, 'spec-proc', ?, ?, ?, ?, ?, ?)
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

      status = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":5000},"cost":{"usd":1.00}}))
      GalaxyLedger::Database.update_session_metrics(lid, status)

      today = GalaxyLedger::LedgerTime.today_str
      GalaxyLedger::Database.spend_daily(today, today).size.should eq(1)

      GalaxyLedger::Database.delete_session("sess-daily-cascade")

      GalaxyLedger::Database.spend_daily(today, today).size.should eq(0)
    end

    it "handles multiple cost resets in one day — accumulates all segments" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-daily-multi-reset")

      # Tick 1: cost=0.50
      s1 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":5000},"cost":{"usd":0.50}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, s1)

      # Tick 2: cost=1.00 (normal increase)
      s2 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":12000},"cost":{"usd":1.00}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, s2)

      # Tick 3: cost=0.30 (first reset)
      s3 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":3000},"cost":{"usd":0.30}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, s3)

      # Tick 4: cost=0.80 (first reset process accumulates)
      s4 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":9000},"cost":{"usd":0.80}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, s4)

      # Tick 5: cost=0.20 (second reset)
      s5 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":2000},"cost":{"usd":0.20}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, s5)

      # Tick 6: cost=0.60 (second reset process accumulates)
      s6 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":7000},"cost":{"usd":0.60}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, s6)

      today = GalaxyLedger::LedgerTime.today_str
      daily = GalaxyLedger::Database.spend_daily(today, today)
      daily.size.should eq(1)
      # Cost: 1.00(segment1) + 0.80(segment2) + 0.60(segment3) = 2.40
      daily[0].cost.should eq(2.40)
      # Tokens: 5000 + 7000 + 0(compact) + 6000 + 0(compact) + 5000 = 23000
      daily[0].tokens.should eq(23000_i64)
    end

    it "handles cost compaction correctly — cost drops mid-day, cumulative preserved" do
      ledger_session_id = GalaxyLedger::Database.create_session("sess-daily-cost-compact")

      # Update 1: cost=0.50
      status1 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":5000},"cost":{"usd":0.50}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status1)

      # Update 2: cost=1.00 (normal increase)
      status2 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":12000},"cost":{"usd":1.00}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status2)

      # Update 3: cost=0.30 (RESET — session resumed with new process)
      status3 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":3000},"cost":{"usd":0.30}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status3)

      # Update 4: cost=0.80 (new process accumulates)
      status4 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":9000},"cost":{"usd":0.80}}))
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status4)

      today = GalaxyLedger::LedgerTime.today_str
      daily = GalaxyLedger::Database.spend_daily(today, today)
      daily.size.should eq(1)
      # Cost: 1.00 (before reset) + 0.80 (after reset) = 1.80
      daily[0].cost.should eq(1.80)
      # Tokens: 5000 + 7000 + 0(compaction) + 6000 = 18000
      daily[0].tokens.should eq(18000_i64)
    end

    it "handles cross-day cost reset — session resumed on new day with lower cost" do
      lid = GalaxyLedger::Database.create_session("sess-daily-crossday-reset")
      today = GalaxyLedger::LedgerTime.today_str
      yesterday = (GalaxyLedger::LedgerTime.now - 1.day).to_s("%Y-%m-%d")

      # Simulate Day 1: session ran with cost=2.50, tokens=10000
      GalaxyLedger::Database.open do |db|
        db.exec(
          <<-SQL,
            INSERT INTO ledger_session_daily_usages (
              ledger_session_id, date, process_key,
              baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
              baseline_tokens, current_tokens, cumulative_tokens
            ) VALUES (?, ?, 'spec-proc', 0.0, 2.50, 2.50, 10000, 10000, 10000)
          SQL
          lid, yesterday,
        )
      end

      # Day 2: session resumed — cost counter reset, reports 0.75
      status = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":3000},"cost":{"usd":0.75}}))
      GalaxyLedger::Database.update_session_metrics(lid, status)

      # Verify Day 2 record has non-negative cumulative
      daily = GalaxyLedger::Database.spend_daily(today, today)
      daily.size.should eq(1)
      daily[0].cost.should eq(0.75)
      # Tokens: 3000 < 10000 (previous day) → token compaction resets diff to 0
      daily[0].tokens.should eq(0_i64)

      # Verify Day 1 record is unchanged
      daily_prev = GalaxyLedger::Database.spend_daily(yesterday, yesterday)
      daily_prev.size.should eq(1)
      daily_prev[0].cost.should eq(2.50)
    end

    it "handles cross-day cost reset to zero — session resumed with no activity" do
      lid = GalaxyLedger::Database.create_session("sess-daily-crossday-zero")
      today = GalaxyLedger::LedgerTime.today_str
      yesterday = (GalaxyLedger::LedgerTime.now - 1.day).to_s("%Y-%m-%d")

      # Simulate Day 1: session ran with cost=1.00
      GalaxyLedger::Database.open do |db|
        db.exec(
          <<-SQL,
            INSERT INTO ledger_session_daily_usages (
              ledger_session_id, date, process_key,
              baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
              baseline_tokens, current_tokens, cumulative_tokens
            ) VALUES (?, ?, 'spec-proc', 0.0, 1.00, 1.00, 5000, 5000, 5000)
          SQL
          lid, yesterday,
        )
      end

      # Day 2: session resumed, statusline reports cost=0 (no activity yet)
      status = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":0},"cost":{"usd":0.0}}))
      GalaxyLedger::Database.update_session_metrics(lid, status)

      # Verify Day 2 record has zero cumulative, not negative
      daily = GalaxyLedger::Database.spend_daily(today, today)
      daily.size.should eq(1)
      daily[0].cost.should eq(0.0)
      daily[0].tokens.should eq(0_i64)
    end

    it "handles cross-day cost reset with multiple Day 2 ticks" do
      lid = GalaxyLedger::Database.create_session("sess-daily-crossday-multi")
      today = GalaxyLedger::LedgerTime.today_str
      yesterday = (GalaxyLedger::LedgerTime.now - 1.day).to_s("%Y-%m-%d")

      # Day 1: session ran with cost=2.50, tokens=10000
      GalaxyLedger::Database.open do |db|
        db.exec(
          <<-SQL,
            INSERT INTO ledger_session_daily_usages (
              ledger_session_id, date, process_key,
              baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
              baseline_tokens, current_tokens, cumulative_tokens
            ) VALUES (?, ?, 'spec-proc', 2.50, 2.50, 2.50, 10000, 10000, 10000)
          SQL
          lid, yesterday,
        )
      end

      # Day 2, tick 1: reset detected (cost=0.75 < prev day's 2.50)
      s1 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":3000},"cost":{"usd":0.75}}))
      GalaxyLedger::Database.update_session_metrics(lid, s1)

      # Day 2, tick 2: normal increase within new process
      s2 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":8000},"cost":{"usd":1.50}}))
      GalaxyLedger::Database.update_session_metrics(lid, s2)

      # Day 2, tick 3: another reset mid-day (second process)
      s3 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":2000},"cost":{"usd":0.40}}))
      GalaxyLedger::Database.update_session_metrics(lid, s3)

      # Day 2, tick 4: second process accumulates
      s4 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":6000},"cost":{"usd":0.90}}))
      GalaxyLedger::Database.update_session_metrics(lid, s4)

      daily = GalaxyLedger::Database.spend_daily(today, today)
      daily.size.should eq(1)
      # Cost: 0.75(initial) + 0.75(increase) + 0.40(reset) + 0.50(increase) = 2.40
      daily[0].cost.should eq(2.40)
      # Tokens: 0(cross-day reset) + 5000 + 0(compaction) + 4000 = 9000
      daily[0].tokens.should eq(9000_i64)

      # Day 1 unchanged
      daily_prev = GalaxyLedger::Database.spend_daily(yesterday, yesterday)
      daily_prev[0].cost.should eq(2.50)
    end

    it "handles cross-day normal continuation — cost increases monotonically" do
      lid = GalaxyLedger::Database.create_session("sess-daily-crossday-normal")
      today = GalaxyLedger::LedgerTime.today_str
      yesterday = (GalaxyLedger::LedgerTime.now - 1.day).to_s("%Y-%m-%d")

      # Simulate Day 1: session ran with cost=3.00, tokens=15000
      GalaxyLedger::Database.open do |db|
        db.exec(
          <<-SQL,
            INSERT INTO ledger_session_daily_usages (
              ledger_session_id, date, process_key,
              baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
              baseline_tokens, current_tokens, cumulative_tokens
            ) VALUES (?, ?, 'spec-proc', 0.0, 3.00, 3.00, 15000, 15000, 15000)
          SQL
          lid, yesterday,
        )
      end

      # Day 2: same process continues — cost is cumulative (5.00 > 3.00)
      status = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":25000},"cost":{"usd":5.00}}))
      GalaxyLedger::Database.update_session_metrics(lid, status)

      # Verify Day 2: cumulative = 5.00 - 3.00 = 2.00 (normal diff)
      daily = GalaxyLedger::Database.spend_daily(today, today)
      daily.size.should eq(1)
      daily[0].cost.should eq(2.00)
      daily[0].tokens.should eq(10000_i64)

      # Verify Day 1 unchanged
      daily_prev = GalaxyLedger::Database.spend_daily(yesterday, yesterday)
      daily_prev[0].cost.should eq(3.00)
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

  # ============================================================
  # One-Shot Usage Recording
  # ============================================================

  describe ".record_oneshot_usage" do
    it "creates a daily record when none exists" do
      lid = GalaxyLedger::Database.create_session("sess-oneshot-create")
      result = GalaxyLedger::Database.record_oneshot_usage(lid, 0.15, 5000_i64)
      result.should be_true

      today = GalaxyLedger::LedgerTime.today_str
      GalaxyLedger::Database.open do |db|
        row = db.query_one?(
          <<-SQL,
            SELECT baseline_cost_usd, cumulative_cost_usd, oneshot_cost_usd,
                   cumulative_tokens, oneshot_tokens
            FROM ledger_session_daily_usages
            WHERE ledger_session_id = ? AND date = ?
          SQL
          lid, today,
        ) do |rs|
          {
            baseline_cost:   rs.read(Float64),
            cumulative_cost: rs.read(Float64),
            oneshot_cost:    rs.read(Float64),
            cumulative_tok:  rs.read(Int64),
            oneshot_tok:     rs.read(Int64),
          }
        end

        row.should_not be_nil
        row = row.not_nil!
        row[:baseline_cost].should eq(0.0)
        row[:cumulative_cost].should eq(0.0)
        row[:oneshot_cost].should eq(0.15)
        row[:cumulative_tok].should eq(0_i64)
        row[:oneshot_tok].should eq(5000_i64)
      end
    end

    it "increments on repeated calls" do
      lid = GalaxyLedger::Database.create_session("sess-oneshot-incr")
      GalaxyLedger::Database.record_oneshot_usage(lid, 0.10, 3000_i64)
      GalaxyLedger::Database.record_oneshot_usage(lid, 0.05, 2000_i64)

      today = GalaxyLedger::LedgerTime.today_str
      GalaxyLedger::Database.open do |db|
        row = db.query_one?(
          "SELECT oneshot_cost_usd, oneshot_tokens FROM ledger_session_daily_usages WHERE ledger_session_id = ? AND date = ?",
          lid, today,
        ) do |rs|
          {cost: rs.read(Float64), tokens: rs.read(Int64)}
        end
        row.should_not be_nil
        row = row.not_nil!
        row[:cost].should be_close(0.15, 0.001)
        row[:tokens].should eq(5000_i64)
      end
    end

    it "oneshot columns are independent of status line columns" do
      lid = GalaxyLedger::Database.create_session("sess-oneshot-indep")

      # Status line tick first
      status = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":5000},"cost":{"usd":0.50}}))
      GalaxyLedger::Database.update_session_metrics(lid, status)

      # Then one-shot
      GalaxyLedger::Database.record_oneshot_usage(lid, 0.10, 3000_i64)

      today = GalaxyLedger::LedgerTime.today_str
      GalaxyLedger::Database.open do |db|
        # One-shots own the 'oneshot' partition and status line ticks own
        # their process's partition, so the day's totals are the sum
        # across both — which is exactly how the spend queries read them.
        row = db.query_one?(
          <<-SQL,
            SELECT SUM(cumulative_cost_usd), SUM(cumulative_tokens),
                   SUM(oneshot_cost_usd), SUM(oneshot_tokens), COUNT(*)
            FROM ledger_session_daily_usages
            WHERE ledger_session_id = ? AND date = ?
          SQL
          lid, today,
        ) do |rs|
          {
            cumulative_cost: rs.read(Float64),
            cumulative_tok:  rs.read(Int64),
            oneshot_cost:    rs.read(Float64),
            oneshot_tok:     rs.read(Int64),
            rows:            rs.read(Int64),
          }
        end
        row.should_not be_nil
        row = row.not_nil!
        row[:cumulative_cost].should eq(0.50)
        row[:cumulative_tok].should eq(5000_i64)
        row[:oneshot_cost].should eq(0.10)
        row[:oneshot_tok].should eq(3000_i64)
        # Separate partitions: one for the status line process, one for one-shots
        row[:rows].should eq(2_i64)
      end
    end

    it "status line updates don't stomp oneshot columns" do
      lid = GalaxyLedger::Database.create_session("sess-oneshot-nostomp")

      # One-shot first
      GalaxyLedger::Database.record_oneshot_usage(lid, 0.10, 3000_i64)

      # Then status line tick
      status = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":10000},"cost":{"usd":0.50}}))
      GalaxyLedger::Database.update_session_metrics(lid, status)

      today = GalaxyLedger::LedgerTime.today_str
      GalaxyLedger::Database.open do |db|
        row = db.query_one?(
          "SELECT SUM(oneshot_cost_usd), SUM(oneshot_tokens) FROM ledger_session_daily_usages WHERE ledger_session_id = ? AND date = ?",
          lid, today,
        ) do |rs|
          {cost: rs.read(Float64), tokens: rs.read(Int64)}
        end
        row.should_not be_nil
        row = row.not_nil!
        row[:cost].should eq(0.10)
        row[:tokens].should eq(3000_i64)
      end
    end

    it "interleaved updates: realistic scenario" do
      lid = GalaxyLedger::Database.create_session("sess-oneshot-interleave")
      today = GalaxyLedger::LedgerTime.today_str

      # Status tick 1: cost=0.50, tokens=5000
      status1 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":5000},"cost":{"usd":0.50}}))
      GalaxyLedger::Database.update_session_metrics(lid, status1)

      # One-shot 1: cost=0.10, tokens=3000
      GalaxyLedger::Database.record_oneshot_usage(lid, 0.10, 3000_i64)

      # Status tick 2: cost=1.00, tokens=12000
      status2 = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":12000},"cost":{"usd":1.00}}))
      GalaxyLedger::Database.update_session_metrics(lid, status2)

      # One-shot 2: cost=0.05, tokens=1000
      GalaxyLedger::Database.record_oneshot_usage(lid, 0.05, 1000_i64)

      GalaxyLedger::Database.open do |db|
        row = db.query_one?(
          <<-SQL,
            SELECT SUM(cumulative_cost_usd), SUM(cumulative_tokens),
                   SUM(oneshot_cost_usd), SUM(oneshot_tokens)
            FROM ledger_session_daily_usages
            WHERE ledger_session_id = ? AND date = ?
          SQL
          lid, today,
        ) do |rs|
          {
            cumulative_cost: rs.read(Float64),
            cumulative_tok:  rs.read(Int64),
            oneshot_cost:    rs.read(Float64),
            oneshot_tok:     rs.read(Int64),
          }
        end
        row.should_not be_nil
        row = row.not_nil!
        row[:cumulative_cost].should eq(1.00)
        row[:cumulative_tok].should eq(12000_i64)
        row[:oneshot_cost].should be_close(0.15, 0.001)
        row[:oneshot_tok].should eq(4000_i64)
      end
    end

    it "handles zero values without error" do
      lid = GalaxyLedger::Database.create_session("sess-oneshot-zero")
      result = GalaxyLedger::Database.record_oneshot_usage(lid, 0.0, 0_i64)
      result.should be_true
    end

    it "returns false for invalid session ID" do
      result = GalaxyLedger::Database.record_oneshot_usage(0_i64, 0.10, 3000_i64)
      result.should be_false
    end

    it "a oneshot firing first does not dump session lifetime into today" do
      # A multi-day session crosses midnight and the first event on the
      # new day is a one-shot (extraction LLM call from UserPromptSubmit /
      # Stop / name suggestion), landing before any status line tick.
      #
      # The hazard is that the day's first row gets created with a zero
      # baseline, so the next status line tick computes
      # cost_diff = lifetime_cost - 0 and books the session's entire
      # lifetime as today's spend.
      #
      # Partitioning removes the hazard structurally: the one-shot writes
      # its own row, and the status line process seeds its baseline from
      # its own previous-day row, so it still diffs against yesterday's
      # carry-over and books only today's incremental spend.
      lid = GalaxyLedger::Database.create_session("sess-oneshot-crossday-seed")
      today = GalaxyLedger::LedgerTime.today_str
      yesterday = (GalaxyLedger::LedgerTime.now - 1.day).to_s("%Y-%m-%d")

      # Simulate yesterday: session ended with lifetime cost $73.87,
      # context at 497077 tokens.
      GalaxyLedger::Database.open do |db|
        db.exec(
          <<-SQL,
            INSERT INTO ledger_session_daily_usages (
              ledger_session_id, date, process_key,
              baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
              baseline_tokens, current_tokens, cumulative_tokens
            ) VALUES (?, ?, 'spec-proc', 73.87, 73.87, 9.99, 497077, 497077, 18000)
          SQL
          lid, yesterday,
        )
      end

      # Today: one-shot fires first (no status line tick yet).
      GalaxyLedger::Database.record_oneshot_usage(lid, 0.15, 5000_i64)

      # The one-shot lands on its own 'oneshot' partition and carries no
      # status line baseline at all. It cannot influence what the status
      # line process diffs against, which is what makes the seeding this
      # method used to perform unnecessary.
      GalaxyLedger::Database.open do |db|
        row = db.query_one?(
          <<-SQL,
            SELECT process_key, cumulative_cost_usd, oneshot_cost_usd, oneshot_tokens
            FROM ledger_session_daily_usages
            WHERE ledger_session_id = ? AND date = ?
          SQL
          lid, today,
        ) do |rs|
          {
            process_key:     rs.read(String),
            cumulative_cost: rs.read(Float64),
            oneshot_cost:    rs.read(Float64),
            oneshot_tok:     rs.read(Int64),
          }
        end
        row.should_not be_nil
        row = row.not_nil!

        row[:process_key].should eq("oneshot")
        row[:cumulative_cost].should eq(0.0)
        row[:oneshot_cost].should eq(0.15)
        row[:oneshot_tok].should eq(5000_i64)
      end

      # Status line tick: session lifetime cost has grown to $76.98
      # (a $3.11 increment), context now 522077 tokens (+25000).
      status = GalaxyLedger::ContextStatus.from_json(
        %({"session_id":"spec-proc","context":{"tokens_used":522077},"cost":{"usd":76.98}})
      )
      GalaxyLedger::Database.update_session_metrics(lid, status)

      # Today's daily total should reflect just the incremental spend
      # plus the oneshot — NOT the full session lifetime.
      daily = GalaxyLedger::Database.spend_daily(today, today)
      daily.size.should eq(1)
      # cost: $3.11 cumulative + $0.15 oneshot = $3.26
      daily[0].cost.should be_close(3.26, 0.001)
      # tokens: 25000 cumulative + 5000 oneshot = 30000
      daily[0].tokens.should eq(30000_i64)
    end

    it "seeds baseline as 0 when no prior day exists (first-day session)" do
      # When a session has no prior daily_usage row at all, a oneshot
      # that creates the first row should still default baseline to 0,
      # matching the prior (pre-fix) behavior for brand-new sessions.
      lid = GalaxyLedger::Database.create_session("sess-oneshot-firstday-seed")
      today = GalaxyLedger::LedgerTime.today_str

      GalaxyLedger::Database.record_oneshot_usage(lid, 0.15, 5000_i64)

      GalaxyLedger::Database.open do |db|
        row = db.query_one?(
          <<-SQL,
            SELECT baseline_cost_usd, current_cost_usd,
                   baseline_tokens, current_tokens
            FROM ledger_session_daily_usages
            WHERE ledger_session_id = ? AND date = ?
          SQL
          lid, today,
        ) do |rs|
          {
            baseline_cost: rs.read(Float64),
            current_cost:  rs.read(Float64),
            baseline_tok:  rs.read(Int64),
            current_tok:   rs.read(Int64),
          }
        end
        row.should_not be_nil
        row = row.not_nil!
        row[:baseline_cost].should eq(0.0)
        row[:current_cost].should eq(0.0)
        row[:baseline_tok].should eq(0_i64)
        row[:current_tok].should eq(0_i64)
      end
    end
  end

  # ============================================================
  # Spend Aggregation with Oneshot Data
  # ============================================================

  describe "spend aggregation with oneshot data" do
    it "spend_summary includes oneshot costs in totals" do
      lid = GalaxyLedger::Database.create_session("sess-spend-oneshot-1")

      GalaxyLedger::Database.open do |db|
        db.exec(
          <<-SQL,
            INSERT INTO ledger_session_daily_usages (
              ledger_session_id, date,
              baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
              baseline_tokens, current_tokens, cumulative_tokens,
              oneshot_cost_usd, oneshot_tokens
            ) VALUES (?, ?, 0.0, 5.0, 5.0, 0, 100000, 100000, 0.50, 10000)
          SQL
          lid, "2025-03-01",
        )
      end

      summary = GalaxyLedger::Database.spend_summary("2025-03-01", "2025-03-01")
      summary.total_cost.should eq(5.50)
      summary.total_tokens.should eq(110000_i64)
    end

    it "spend_daily includes oneshot costs in daily totals" do
      lid = GalaxyLedger::Database.create_session("sess-spend-oneshot-2")

      GalaxyLedger::Database.open do |db|
        db.exec(
          <<-SQL,
            INSERT INTO ledger_session_daily_usages (
              ledger_session_id, date,
              baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
              baseline_tokens, current_tokens, cumulative_tokens,
              oneshot_cost_usd, oneshot_tokens
            ) VALUES (?, ?, 0.0, 3.0, 3.0, 0, 50000, 50000, 0.25, 5000)
          SQL
          lid, "2025-03-01",
        )
      end

      daily = GalaxyLedger::Database.spend_daily("2025-03-01", "2025-03-01")
      daily.size.should eq(1)
      daily[0].cost.should eq(3.25)
      daily[0].tokens.should eq(55000_i64)
    end

    it "spend_avg_daily includes oneshot costs" do
      lid = GalaxyLedger::Database.create_session("sess-spend-oneshot-3")

      GalaxyLedger::Database.open do |db|
        db.exec(
          <<-SQL,
            INSERT INTO ledger_session_daily_usages (
              ledger_session_id, date,
              baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
              baseline_tokens, current_tokens, cumulative_tokens,
              oneshot_cost_usd, oneshot_tokens
            ) VALUES (?, ?, 0.0, 6.0, 6.0, 0, 100, 100, 1.0, 10)
          SQL
          lid, "2025-03-01",
        )
        db.exec(
          <<-SQL,
            INSERT INTO ledger_session_daily_usages (
              ledger_session_id, date,
              baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
              baseline_tokens, current_tokens, cumulative_tokens,
              oneshot_cost_usd, oneshot_tokens
            ) VALUES (?, ?, 6.0, 10.0, 4.0, 100, 200, 100, 0.50, 5)
          SQL
          lid, "2025-03-02",
        )
      end

      avg = GalaxyLedger::Database.spend_avg_daily("2025-03-01", "2025-03-02")
      # Day 1: 6.0 + 1.0 = 7.0; Day 2: 4.0 + 0.50 = 4.50; Avg: (7.0 + 4.50) / 2 = 5.75
      avg.should eq(5.75)
    end

    it "multiple sessions with mixed oneshot" do
      lid1 = GalaxyLedger::Database.create_session("sess-spend-mix-1")
      lid2 = GalaxyLedger::Database.create_session("sess-spend-mix-2")

      GalaxyLedger::Database.open do |db|
        # Session 1 has oneshot data
        db.exec(
          <<-SQL,
            INSERT INTO ledger_session_daily_usages (
              ledger_session_id, date,
              baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
              baseline_tokens, current_tokens, cumulative_tokens,
              oneshot_cost_usd, oneshot_tokens
            ) VALUES (?, ?, 0.0, 5.0, 5.0, 0, 100000, 100000, 0.50, 10000)
          SQL
          lid1, "2025-03-01",
        )
        # Session 2 has no oneshot data (defaults to 0)
        db.exec(
          <<-SQL,
            INSERT INTO ledger_session_daily_usages (
              ledger_session_id, date, process_key,
              baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
              baseline_tokens, current_tokens, cumulative_tokens
            ) VALUES (?, ?, 'spec-proc', 0.0, 2.0, 2.0, 0, 50000, 50000)
          SQL
          lid2, "2025-03-01",
        )
      end

      summary = GalaxyLedger::Database.spend_summary("2025-03-01", "2025-03-01")
      summary.total_cost.should eq(7.50)     # 5.0 + 0.50 + 2.0
      summary.total_tokens.should eq(160000) # 100000 + 10000 + 50000
    end

    it "cascade delete includes oneshot data" do
      lid = GalaxyLedger::Database.create_session("sess-oneshot-cascade")

      status = GalaxyLedger::ContextStatus.from_json(%({"session_id":"spec-proc","context":{"tokens_used":5000},"cost":{"usd":1.00}}))
      GalaxyLedger::Database.update_session_metrics(lid, status)
      GalaxyLedger::Database.record_oneshot_usage(lid, 0.25, 5000_i64)

      today = GalaxyLedger::LedgerTime.today_str
      GalaxyLedger::Database.spend_daily(today, today).size.should eq(1)

      GalaxyLedger::Database.delete_session("sess-oneshot-cascade")
      GalaxyLedger::Database.spend_daily(today, today).size.should eq(0)
    end
  end

  # ============================================================
  # Migration: 0.3.2
  # ============================================================

  describe "0.3.2 migration" do
    # Migration test creates a partial DB (only the tables needed to test
    # the migration). Clean up by deleting the DB so subsequent tests get
    # a fresh full-schema database instead of the partial one.
    after_each do
      db_path = GalaxyLedger::Database.database_path
      File.delete(db_path) if File.exists?(db_path)
    end

    it "adds oneshot columns to existing table" do
      db_path = GalaxyLedger::Database.database_path
      File.delete(db_path) if File.exists?(db_path)

      # Create a 0.3.1-era database manually (without oneshot columns)
      DB.open("sqlite3://#{db_path}") do |db|
        db.exec("PRAGMA journal_mode=WAL")
        db.exec("PRAGMA foreign_keys=ON")

        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS schema_info (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        SQL
        db.exec("INSERT INTO schema_info (key, value) VALUES ('version', '0.3.1')")

        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS ledger_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT,
            current_session_identifier TEXT,
            current_claude_pid INTEGER,
            started_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now')),
            cwd TEXT, project_dir TEXT, git_branch TEXT,
            model_id TEXT, model_display_name TEXT, claude_version TEXT,
            context_percentage REAL DEFAULT 0.0,
            tokens_used INTEGER DEFAULT 0, tokens_max INTEGER DEFAULT 0,
            cost_usd REAL DEFAULT 0.0,
            lines_added INTEGER DEFAULT 0, lines_removed INTEGER DEFAULT 0,
            context TEXT NOT NULL DEFAULT '{}'
          )
        SQL

        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS ledger_session_daily_usages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ledger_session_id INTEGER NOT NULL,
            date TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            baseline_cost_usd REAL NOT NULL DEFAULT 0.0,
            current_cost_usd REAL NOT NULL DEFAULT 0.0,
            cumulative_cost_usd REAL NOT NULL DEFAULT 0.0,
            baseline_tokens INTEGER NOT NULL DEFAULT 0,
            current_tokens INTEGER NOT NULL DEFAULT 0,
            cumulative_tokens INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY (ledger_session_id) REFERENCES ledger_sessions(id) ON DELETE CASCADE,
            UNIQUE(ledger_session_id, date)
          )
        SQL

        # Insert a pre-migration row
        db.exec("INSERT INTO ledger_sessions (current_session_identifier) VALUES ('migration-test')")
        db.exec(
          "INSERT INTO ledger_session_daily_usages (ledger_session_id, date, baseline_cost_usd, current_cost_usd, cumulative_cost_usd, baseline_tokens, current_tokens, cumulative_tokens) VALUES (1, '2025-03-01', 0.0, 5.0, 5.0, 0, 100, 100)"
        )
      end

      # Open via Database.open which triggers migration
      GalaxyLedger::Database.open do |db|
        # Verify version was updated
        version = GalaxyLedger::Migrations.get_database_version(db)
        version.should eq(GalaxyLedger::VERSION)

        # Verify columns exist via PRAGMA
        columns = [] of String
        db.query("PRAGMA table_info(ledger_session_daily_usages)") do |rs|
          rs.each do
            rs.read(Int64)             # cid
            columns << rs.read(String) # name
            rs.read(String)            # type
            rs.read(Int64)             # notnull
            rs.read(String | Nil)      # dflt_value
            rs.read(Int64)             # pk
          end
        end
        columns.should contain("oneshot_cost_usd")
        columns.should contain("oneshot_tokens")

        # Verify existing data has default values
        row = db.query_one?(
          "SELECT oneshot_cost_usd, oneshot_tokens FROM ledger_session_daily_usages WHERE ledger_session_id = 1",
        ) do |rs|
          {cost: rs.read(Float64), tokens: rs.read(Int64)}
        end
        row.should_not be_nil
        row = row.not_nil!
        row[:cost].should eq(0.0)
        row[:tokens].should eq(0_i64)
      end
    end
  end
end
