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

        indexes.should contain("idx_session")
        indexes.should contain("idx_session_type")
        indexes.should contain("idx_source")
        indexes.should contain("idx_created")
        indexes.should contain("idx_importance")
        indexes.should contain("idx_content_dedup")
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
      entry = GalaxyLedger::Buffer::Entry.new(
        entry_type: "learning",
        content: "Test learning content",
        importance: "medium",
        source: "assistant"
      )

      result = GalaxyLedger::Database.insert("test-session", entry)
      result.should be_true

      GalaxyLedger::Database.count.should eq(1)
    end

    it "returns false for empty session_id" do
      entry = GalaxyLedger::Buffer::Entry.new(
        entry_type: "learning",
        content: "Test content"
      )

      result = GalaxyLedger::Database.insert("", entry)
      result.should be_false
    end

    it "returns false for invalid entry" do
      entry = GalaxyLedger::Buffer::Entry.new(
        entry_type: "invalid_type",
        content: "Test content"
      )

      result = GalaxyLedger::Database.insert("test-session", entry)
      result.should be_false
    end

    it "prevents duplicate entries with same content_hash" do
      entry = GalaxyLedger::Buffer::Entry.new(
        entry_type: "learning",
        content: "Duplicate test content",
        importance: "medium"
      )

      result1 = GalaxyLedger::Database.insert("test-session", entry)
      result2 = GalaxyLedger::Database.insert("test-session", entry)

      result1.should be_true
      result2.should be_false
      GalaxyLedger::Database.count.should eq(1)
    end

    it "allows same content in different sessions" do
      entry = GalaxyLedger::Buffer::Entry.new(
        entry_type: "learning",
        content: "Same content different session"
      )

      result1 = GalaxyLedger::Database.insert("session-1", entry)
      result2 = GalaxyLedger::Database.insert("session-2", entry)

      result1.should be_true
      result2.should be_true
      GalaxyLedger::Database.count.should eq(2)
    end

    it "stores metadata as JSON" do
      metadata = JSON.parse(%({"source_file": "test.rb", "line": 42}))
      entry = GalaxyLedger::Buffer::Entry.new(
        entry_type: "learning",
        content: "Test with metadata",
        metadata: metadata
      )

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
        GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "Learning 1"),
        GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "Decision 1"),
        GalaxyLedger::Buffer::Entry.new(entry_type: "discovery", content: "Discovery 1"),
      ]

      count = GalaxyLedger::Database.insert_many("test-session", entries)
      count.should eq(3)
      GalaxyLedger::Database.count.should eq(3)
    end

    it "skips invalid entries" do
      entries = [
        GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "Valid"),
        GalaxyLedger::Buffer::Entry.new(entry_type: "invalid", content: "Invalid"),
        GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "Valid 2"),
      ]

      count = GalaxyLedger::Database.insert_many("test-session", entries)
      count.should eq(2)
    end

    it "skips duplicates" do
      entries = [
        GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "Same content"),
        GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "Same content"),
        GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "Different content"),
      ]

      count = GalaxyLedger::Database.insert_many("test-session", entries)
      count.should eq(2)
    end

    it "returns 0 for empty session_id" do
      entries = [GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "Test")]
      count = GalaxyLedger::Database.insert_many("", entries)
      count.should eq(0)
    end

    it "returns 0 for empty entries array" do
      count = GalaxyLedger::Database.insert_many("test-session", [] of GalaxyLedger::Buffer::Entry)
      count.should eq(0)
    end
  end

  describe ".delete_session" do
    it "deletes all entries for a session" do
      entries = [
        GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L1"),
        GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "D1"),
      ]
      GalaxyLedger::Database.insert_many("session-to-delete", entries)
      GalaxyLedger::Database.insert("other-session", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "Keep"))

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
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L1"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "D1"))
      GalaxyLedger::Database.insert("s2", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L2"))

      GalaxyLedger::Database.count.should eq(3)
    end

    it "returns 0 for empty database" do
      GalaxyLedger::Database.ensure_database_exists
      GalaxyLedger::Database.count.should eq(0)
    end
  end

  describe ".count_by_session" do
    it "returns count for specific session" do
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L1"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "D1"))
      GalaxyLedger::Database.insert("s2", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L2"))

      GalaxyLedger::Database.count_by_session("s1").should eq(2)
      GalaxyLedger::Database.count_by_session("s2").should eq(1)
    end

    it "returns 0 for empty session_id" do
      GalaxyLedger::Database.count_by_session("").should eq(0)
    end
  end

  describe ".query_by_session" do
    it "returns entries for a session ordered by created_at DESC" do
      # Insert with different timestamps
      entry1 = GalaxyLedger::Buffer::Entry.new(
        entry_type: "learning",
        content: "First",
        created_at: "2026-01-01T10:00:00Z"
      )
      entry2 = GalaxyLedger::Buffer::Entry.new(
        entry_type: "decision",
        content: "Second",
        created_at: "2026-01-01T11:00:00Z"
      )
      GalaxyLedger::Database.insert("test-session", entry1)
      GalaxyLedger::Database.insert("test-session", entry2)

      entries = GalaxyLedger::Database.query_by_session("test-session")

      entries.size.should eq(2)
      entries[0].content.should eq("Second")  # Most recent first
      entries[1].content.should eq("First")
    end

    it "respects limit parameter" do
      5.times do |i|
        entry = GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "Entry #{i}")
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
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L1"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "D1"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L2"))

      entries = GalaxyLedger::Database.query_by_type("s1", "learning")

      entries.size.should eq(2)
      entries.all? { |e| e.entry_type == "learning" }.should be_true
    end
  end

  describe ".query_by_importance" do
    it "returns entries of specific importance" do
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L1", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "D1", importance: "medium"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L2", importance: "high"))

      entries = GalaxyLedger::Database.query_by_importance("s1", "high")

      entries.size.should eq(2)
      entries.all? { |e| e.importance == "high" }.should be_true
    end
  end

  describe ".query_recent" do
    it "returns recent entries across all sessions" do
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L1"))
      GalaxyLedger::Database.insert("s2", GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "D1"))
      GalaxyLedger::Database.insert("s3", GalaxyLedger::Buffer::Entry.new(entry_type: "discovery", content: "Disc1"))

      entries = GalaxyLedger::Database.query_recent
      entries.size.should eq(3)
    end

    it "respects limit parameter" do
      5.times do |i|
        entry = GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "Entry #{i}")
        GalaxyLedger::Database.insert("session-#{i}", entry)
      end

      entries = GalaxyLedger::Database.query_recent(limit: 2)
      entries.size.should eq(2)
    end
  end

  describe ".search" do
    it "finds entries matching query" do
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "JWT authentication tokens expire"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "Using Redis for caching"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "Database connection pooling"))

      entries = GalaxyLedger::Database.search("JWT authentication")

      entries.size.should eq(1)
      entries[0].content.should contain("JWT")
    end

    it "returns empty for no matches" do
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "Something else"))

      entries = GalaxyLedger::Database.search("nonexistent term")
      entries.should be_empty
    end

    it "returns empty for empty query" do
      GalaxyLedger::Database.search("").should be_empty
      GalaxyLedger::Database.search("   ").should be_empty
    end

    it "searches across all sessions" do
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "JWT in session 1"))
      GalaxyLedger::Database.insert("s2", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "JWT in session 2"))

      entries = GalaxyLedger::Database.search("JWT")
      entries.size.should eq(2)
    end
  end

  describe ".search_in_session" do
    it "searches within a specific session" do
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "JWT in session 1"))
      GalaxyLedger::Database.insert("s2", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "JWT in session 2"))

      entries = GalaxyLedger::Database.search_in_session("s1", "JWT")

      entries.size.should eq(1)
      entries[0].session_id.should eq("s1")
    end

    it "returns empty for empty session_id" do
      GalaxyLedger::Database.search_in_session("", "query").should be_empty
    end
  end

  describe ".session_stats" do
    it "returns stats for all sessions" do
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L1"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "D1"))
      GalaxyLedger::Database.insert("s2", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L2"))

      stats = GalaxyLedger::Database.session_stats

      stats.size.should eq(2)
      s1_stat = stats.find { |s| s.session_id == "s1" }
      s1_stat.should_not be_nil
      s1_stat.not_nil!.entry_count.should eq(2)
    end
  end

  describe GalaxyLedger::Database::LedgerEntry do
    describe "#to_buffer_entry" do
      it "converts to Buffer::Entry" do
        # First insert an entry
        original = GalaxyLedger::Buffer::Entry.new(
          entry_type: "learning",
          content: "Test content",
          importance: "high",
          source: "assistant"
        )
        GalaxyLedger::Database.insert("test-session", original)

        # Query it back
        entries = GalaxyLedger::Database.query_by_session("test-session")
        ledger_entry = entries[0]

        # Convert back to buffer entry
        buffer_entry = ledger_entry.to_buffer_entry

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
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "guideline", content: "Use trailing commas on multiline structures"))

      # "trail" should match "trailing" with prefix matching
      entries = GalaxyLedger::Database.search("trail")
      entries.size.should eq(1)
      entries[0].content.should contain("trailing")
    end

    it "respects prefix_match: false for exact matching" do
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "guideline", content: "Use trailing commas"))

      # "trail" should NOT match "trailing" with exact matching
      entries = GalaxyLedger::Database.search("trail", prefix_match: false)
      entries.should be_empty
    end
  end

  describe ".search with filters" do
    before_each do
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "JWT tokens expire", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "JWT storage in Redis", importance: "medium"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "guideline", content: "JWT best practices", importance: "high"))
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
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L1", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "D1", importance: "medium"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L2", importance: "low"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "guideline", content: "G1", importance: "high"))
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
      # Tier 1 entries
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "guideline", content: "G1", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "guideline", content: "G2", importance: "medium"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "implementation_plan", content: "IP1", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "D1 high", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "D2 medium", importance: "medium"))
      # Non-tier1 entries
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L1", importance: "medium"))
    end

    it "returns guidelines for the session" do
      result = GalaxyLedger::Database.query_tier1("s1")
      result.guidelines.size.should eq(2)
    end

    it "returns implementation plans for the session" do
      result = GalaxyLedger::Database.query_tier1("s1")
      result.implementation_plans.size.should eq(1)
    end

    it "returns only high-importance decisions" do
      result = GalaxyLedger::Database.query_tier1("s1")
      result.high_importance_decisions.size.should eq(1)
      result.high_importance_decisions[0].importance.should eq("high")
    end

    it "respects decision limit" do
      # Add more high-importance decisions
      5.times do |i|
        GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "Extra D#{i}", importance: "high"))
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
      # Tier 2 entries
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L1", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L2", importance: "medium"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "file_edit", content: "FE1", importance: "medium"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "D1 medium", importance: "medium"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "D2 high", importance: "high"))
    end

    it "returns learnings for the session" do
      result = GalaxyLedger::Database.query_tier2("s1")
      result.learnings.size.should eq(2)
    end

    it "returns file edits for the session" do
      result = GalaxyLedger::Database.query_tier2("s1")
      result.file_edits.size.should eq(1)
    end

    it "returns only medium-importance decisions" do
      result = GalaxyLedger::Database.query_tier2("s1")
      result.medium_decisions.size.should eq(1)
      result.medium_decisions[0].importance.should eq("medium")
    end

    it "respects limits" do
      # Add more learnings
      5.times do |i|
        GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "Extra L#{i}", importance: "medium"))
      end

      result = GalaxyLedger::Database.query_tier2("s1", learnings_limit: 3)
      result.learnings.size.should eq(3)
    end

    it "returns total count" do
      result = GalaxyLedger::Database.query_tier2("s1")
      result.total_count.should eq(4) # 2 learnings + 1 file_edit + 1 medium decision
    end
  end

  describe ".query_for_restoration" do
    before_each do
      # Mix of tier 1 and tier 2 entries
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "guideline", content: "G1", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "implementation_plan", content: "IP1", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "D1 high", importance: "high"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "decision", content: "D2 medium", importance: "medium"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "learning", content: "L1", importance: "medium"))
      GalaxyLedger::Database.insert("s1", GalaxyLedger::Buffer::Entry.new(entry_type: "file_edit", content: "FE1", importance: "medium"))
    end

    it "returns both tier1 and tier2 results" do
      result = GalaxyLedger::Database.query_for_restoration("s1")

      result.tier1.guidelines.size.should eq(1)
      result.tier1.implementation_plans.size.should eq(1)
      result.tier1.high_importance_decisions.size.should eq(1)

      result.tier2.learnings.size.should eq(1)
      result.tier2.file_edits.size.should eq(1)
      result.tier2.medium_decisions.size.should eq(1)
    end

    it "returns combined total count" do
      result = GalaxyLedger::Database.query_for_restoration("s1")
      result.total_count.should eq(6)
    end

    it "respects all limits" do
      result = GalaxyLedger::Database.query_for_restoration(
        "s1",
        tier1_decision_limit: 0,
        tier2_learnings_limit: 0,
        tier2_file_edits_limit: 0,
        tier2_decisions_limit: 0
      )
      result.tier1.high_importance_decisions.size.should eq(0)
      result.tier2.learnings.size.should eq(0)
      result.tier2.file_edits.size.should eq(0)
      result.tier2.medium_decisions.size.should eq(0)
    end
  end
end
