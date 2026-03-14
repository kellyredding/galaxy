require "../spec_helper"

# Seed a session with entries, files, a daily usage, a snapshot, and an artifact.
# Sets updated_at to the given timestamp. Returns the session ID.
private def seed_prune_db_session(identifier : String, updated_at : String) : Int64
  session_id = GalaxyLedger::Database.create_session(identifier)

  # Add entries
  entry = GalaxyLedger::Entry.new(
    entry_type: "decision",
    content: "Test decision for #{identifier}",
    importance: "medium",
    source: "assistant",
    created_at: Time.utc.to_s("%Y-%m-%dT%H:%M:%S"),
  )
  GalaxyLedger::Database.insert(session_id, entry)

  learning = GalaxyLedger::Entry.new(
    entry_type: "learning",
    content: "Test learning for #{identifier}",
    importance: "medium",
    source: "assistant",
    created_at: Time.utc.to_s("%Y-%m-%dT%H:%M:%S"),
  )
  GalaxyLedger::Database.insert(session_id, learning)

  # Add a file access record
  GalaxyLedger::Database.upsert_session_file(session_id, "/tmp/test-#{identifier}.cr", :read)

  # Add a snapshot
  GalaxyLedger::Database.save_snapshot(session_id, "Snapshot for #{identifier}", "snapshot content", 1)

  # Add a daily usage record via direct SQL
  GalaxyLedger::Database.open do |db|
    db.exec(
      <<-SQL,
        INSERT INTO ledger_session_daily_usages (
          ledger_session_id, date,
          baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
          baseline_tokens, current_tokens, cumulative_tokens,
          oneshot_cost_usd, oneshot_tokens
        ) VALUES (?, '2026-02-18', 0.0, 1.50, 1.50, 0, 10000, 10000, 0.0, 0)
      SQL
      session_id,
    )
  end

  # Add an artifact record via direct SQL
  GalaxyLedger::Database.open do |db|
    db.exec(
      <<-SQL,
        INSERT INTO ledger_artifacts (
          ledger_session_id, number, title, artifact_type, mime_type,
          original_filename, stored_path, source_path, file_size,
          content_hash
        ) VALUES (?, 1, 'Test artifact', 'document', 'text/csv',
          'test.csv', '/tmp/stored/test.csv', '/tmp/source/test.csv',
          1024, 'abc123')
      SQL
      session_id,
    )
  end

  # Set the session's updated_at to the desired timestamp
  GalaxyLedger::Database.open do |db|
    db.exec(
      "UPDATE ledger_sessions SET updated_at = ? WHERE id = ?",
      updated_at, session_id,
    )
  end

  session_id
end

describe GalaxyLedger::Database do
  describe ".count_prunable_summary" do
    it "returns counts for all standard periods" do
      # Seed an old session (100 days ago)
      old_date = (Time.utc - 100.days).to_s("%Y-%m-%d %H:%M:%S")
      seed_prune_db_session("old-session", old_date)

      # Seed a recent session (1 day ago)
      recent_date = (Time.utc - 1.day).to_s("%Y-%m-%d %H:%M:%S")
      seed_prune_db_session("recent-session", recent_date)

      summary = GalaxyLedger::Database.count_prunable_summary

      # Should have all 9 standard periods
      summary.size.should eq(9)
      summary.has_key?("1w").should be_true
      summary.has_key?("3m").should be_true
      summary.has_key?("5y").should be_true

      # Old session (100 days) should appear in 3m (90 days) but not 6m (180 days)
      summary["3m"].sessions.should eq(1)
      summary["3m"].entries.should eq(2)
      summary["3m"].files.should eq(1)

      summary["6m"].sessions.should eq(0)
      summary["6m"].entries.should eq(0)

      # 1w should include the old session (100 days > 7 days) but not the recent one (1 day < 7 days)
      summary["1w"].sessions.should eq(1)
    end

    it "returns zero counts when no sessions exist" do
      summary = GalaxyLedger::Database.count_prunable_summary

      summary.each_value do |counts|
        counts.sessions.should eq(0)
        counts.entries.should eq(0)
        counts.files.should eq(0)
      end
    end
  end

  describe ".count_prunable_data" do
    it "returns accurate counts for a specific cutoff" do
      old_date = (Time.utc - 60.days).to_s("%Y-%m-%d %H:%M:%S")
      seed_prune_db_session("old-1", old_date)
      seed_prune_db_session("old-2", old_date)

      recent_date = (Time.utc - 1.day).to_s("%Y-%m-%d %H:%M:%S")
      seed_prune_db_session("recent-1", recent_date)

      cutoff = (Time.utc - 30.days).to_s("%Y-%m-%d %H:%M:%S")
      counts = GalaxyLedger::Database.count_prunable_data(cutoff)

      counts.sessions.should eq(2)
      counts.entries.should eq(4) # 2 entries per session × 2 sessions
      counts.files.should eq(2)   # 1 file per session × 2 sessions

      # Preserved data counts
      counts.daily_usages.should eq(2)
      counts.snapshots.should eq(2)
      counts.artifacts.should eq(2)
    end
  end

  describe ".prune_session_data" do
    it "deletes entries and files for old sessions" do
      old_date = (Time.utc - 60.days).to_s("%Y-%m-%d %H:%M:%S")
      old_id = seed_prune_db_session("prune-old", old_date)

      cutoff = (Time.utc - 30.days).to_s("%Y-%m-%d %H:%M:%S")
      result = GalaxyLedger::Database.prune_session_data(cutoff)

      result[:entries].should eq(2)
      result[:files].should eq(1)

      # Verify entries are gone
      remaining = GalaxyLedger::Database.query_by_session(old_id, 100)
      remaining.size.should eq(0)
    end

    it "preserves session records for pruned sessions" do
      old_date = (Time.utc - 60.days).to_s("%Y-%m-%d %H:%M:%S")
      old_id = seed_prune_db_session("prune-preserve-session", old_date)

      cutoff = (Time.utc - 30.days).to_s("%Y-%m-%d %H:%M:%S")
      GalaxyLedger::Database.prune_session_data(cutoff)

      # Session record should still exist
      session = GalaxyLedger::Database.get_session_by_id(old_id)
      session.should_not be_nil
    end

    it "preserves daily usages for pruned sessions" do
      old_date = (Time.utc - 60.days).to_s("%Y-%m-%d %H:%M:%S")
      old_id = seed_prune_db_session("prune-preserve-usages", old_date)

      cutoff = (Time.utc - 30.days).to_s("%Y-%m-%d %H:%M:%S")
      GalaxyLedger::Database.prune_session_data(cutoff)

      # Daily usage should still exist
      count = 0
      GalaxyLedger::Database.open do |db|
        count = db.scalar(
          "SELECT COUNT(*) FROM ledger_session_daily_usages WHERE ledger_session_id = ?",
          old_id,
        ).as(Int64).to_i
      end
      count.should eq(1)
    end

    it "preserves snapshots for pruned sessions" do
      old_date = (Time.utc - 60.days).to_s("%Y-%m-%d %H:%M:%S")
      old_id = seed_prune_db_session("prune-preserve-snapshots", old_date)

      cutoff = (Time.utc - 30.days).to_s("%Y-%m-%d %H:%M:%S")
      GalaxyLedger::Database.prune_session_data(cutoff)

      snapshots = GalaxyLedger::Database.list_snapshots(old_id)
      snapshots.size.should eq(1)
    end

    it "preserves artifacts for pruned sessions" do
      old_date = (Time.utc - 60.days).to_s("%Y-%m-%d %H:%M:%S")
      old_id = seed_prune_db_session("prune-preserve-artifacts", old_date)

      cutoff = (Time.utc - 30.days).to_s("%Y-%m-%d %H:%M:%S")
      GalaxyLedger::Database.prune_session_data(cutoff)

      artifact_count = GalaxyLedger::Database.session_artifact_count(old_id)
      artifact_count.should eq(1)
    end

    it "does not touch sessions newer than cutoff" do
      old_date = (Time.utc - 60.days).to_s("%Y-%m-%d %H:%M:%S")
      seed_prune_db_session("prune-old-untouched", old_date)

      recent_date = (Time.utc - 1.day).to_s("%Y-%m-%d %H:%M:%S")
      recent_id = seed_prune_db_session("prune-recent-safe", recent_date)

      cutoff = (Time.utc - 30.days).to_s("%Y-%m-%d %H:%M:%S")
      GalaxyLedger::Database.prune_session_data(cutoff)

      # Recent session entries should be untouched
      remaining = GalaxyLedger::Database.query_by_session(recent_id, 100)
      remaining.size.should eq(2)
    end
  end

  describe ".vacuum_database" do
    it "returns valid before and after sizes" do
      # Seed some data so the DB has content
      seed_prune_db_session("vacuum-test", Time.utc.to_s("%Y-%m-%d %H:%M:%S"))

      result = GalaxyLedger::Database.vacuum_database
      result[:before].should be > 0
      result[:after].should be > 0
    end
  end

  describe ".database_file_size" do
    it "returns a positive size for existing database" do
      # Ensure DB exists by creating a session
      GalaxyLedger::Database.create_session("size-test")
      size = GalaxyLedger::Database.database_file_size
      size.should be > 0
    end
  end

  describe ".active_session_count" do
    it "detects recently updated sessions" do
      # Create a session (will have updated_at = now)
      GalaxyLedger::Database.create_session("active-test")

      count = GalaxyLedger::Database.active_session_count
      count.should be >= 1
    end

    it "does not count old sessions" do
      old_date = (Time.utc - 1.day).to_s("%Y-%m-%d %H:%M:%S")
      session_id = GalaxyLedger::Database.create_session("inactive-test")
      GalaxyLedger::Database.open do |db|
        db.exec(
          "UPDATE ledger_sessions SET updated_at = ? WHERE id = ?",
          old_date, session_id,
        )
      end

      count = GalaxyLedger::Database.active_session_count
      count.should eq(0)
    end
  end
end
