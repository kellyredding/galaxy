require "../spec_helper"

# Seed a session with entries, files, daily usage, and artifact.
# Sets updated_at to the given timestamp. Returns the session ID.
private def seed_prune_session(identifier : String, updated_at : String) : Int64
  session_id = GalaxyLedger::Database.create_session(identifier)

  # Add entries
  entry = GalaxyLedger::Entry.new(
    entry_type: "constraint",
    content: "Prune test constraint for #{identifier}",
    importance: "medium",
    source: "assistant",
    created_at: Time.utc.to_s("%Y-%m-%dT%H:%M:%S"),
  )
  GalaxyLedger::Database.insert(session_id, entry)

  learning = GalaxyLedger::Entry.new(
    entry_type: "learning",
    content: "Prune test learning for #{identifier}",
    importance: "medium",
    source: "assistant",
    created_at: Time.utc.to_s("%Y-%m-%dT%H:%M:%S"),
  )
  GalaxyLedger::Database.insert(session_id, learning)

  # File access record
  GalaxyLedger::Database.upsert_session_file(session_id, "/tmp/test-#{identifier}.cr", :read)

  # Daily usage
  GalaxyLedger::Database.open do |db|
    db.exec(
      "INSERT INTO ledger_session_daily_usages (ledger_session_id, date, baseline_cost_usd, current_cost_usd, cumulative_cost_usd, baseline_tokens, current_tokens, cumulative_tokens, oneshot_cost_usd, oneshot_tokens) VALUES (?, '2026-02-18', 0.0, 1.0, 1.0, 0, 5000, 5000, 0.0, 0)",
      session_id,
    )
  end

  # Artifact
  GalaxyLedger::Database.open do |db|
    db.exec(
      "INSERT INTO ledger_artifacts (ledger_session_id, number, title, artifact_type, mime_type, original_filename, stored_path, source_path, file_size, content_hash) VALUES (?, 1, 'Test artifact', 'document', 'text/csv', 'test.csv', '/tmp/stored/test.csv', '/tmp/source/test.csv', 1024, 'abc123')",
      session_id,
    )
  end

  # Set the desired updated_at
  GalaxyLedger::Database.open do |db|
    db.exec("UPDATE ledger_sessions SET updated_at = ? WHERE id = ?", updated_at, session_id)
  end

  session_id
end

describe "CLI prune commands", tags: "integration" do
  describe "prune --help" do
    it "shows help text" do
      result = run_binary(["prune", "-h"])

      result[:status].should eq(0)
      result[:output].should contain("galaxy-ledger prune")
      result[:output].should contain("--summary")
      result[:output].should contain("--older-than")
      result[:output].should contain("--apply")
    end
  end

  describe "prune (no flags)" do
    it "shows help when no flags given" do
      result = run_binary(["prune"])

      result[:status].should eq(0)
      result[:output].should contain("galaxy-ledger prune")
    end
  end

  describe "prune --summary" do
    it "shows the summary table with seeded data" do
      old_date = (Time.utc - 100.days).to_s("%Y-%m-%d %H:%M:%S")
      seed_prune_session("summary-old", old_date)

      recent_date = (Time.utc - 1.day).to_s("%Y-%m-%d %H:%M:%S")
      seed_prune_session("summary-recent", recent_date)

      result = run_binary(["prune", "--summary"])

      result[:status].should eq(0)
      result[:output].should contain("Prunable session data")
      result[:output].should contain("Period")
      result[:output].should contain("Sessions")
      result[:output].should contain("Entries")
      result[:output].should contain("Files")
      result[:output].should contain("Database size:")
      result[:output].should contain("Preserved per session:")
      result[:output].should contain("artifacts")
    end

    it "skips periods with zero counts" do
      # Only seed a session 100 days old — periods like 6m/1y/2y/5y should be empty
      old_date = (Time.utc - 100.days).to_s("%Y-%m-%d %H:%M:%S")
      seed_prune_session("summary-skip-zeros", old_date)

      result = run_binary(["prune", "--summary"])

      result[:status].should eq(0)
      # 3m should appear (100 > 90 days)
      result[:output].should contain("Older than 3m")
      # 6m should NOT appear (100 < 180 days)
      result[:output].should_not contain("Older than 6m")
    end
  end

  describe "prune --older-than (preview)" do
    it "shows preview without modifying data" do
      old_date = (Time.utc - 60.days).to_s("%Y-%m-%d %H:%M:%S")
      old_id = seed_prune_session("preview-test", old_date)

      result = run_binary(["prune", "--older-than", "1m"])

      result[:status].should eq(0)
      result[:output].should contain("Would prune:")
      result[:output].should contain("Entries:")
      result[:output].should contain("Files:")
      result[:output].should contain("Preserved:")
      result[:output].should contain("Session records:")
      result[:output].should contain("Artifacts:")
      result[:output].should contain("Run with --apply to execute.")

      # Data should NOT have been modified
      remaining = GalaxyLedger::Database.query_by_session(old_id, 100)
      remaining.size.should eq(2)
    end

    it "shows nothing-to-prune when no old sessions" do
      recent_date = (Time.utc - 1.day).to_s("%Y-%m-%d %H:%M:%S")
      seed_prune_session("preview-nothing", recent_date)

      result = run_binary(["prune", "--older-than", "1m"])

      result[:status].should eq(0)
      result[:output].should contain("Nothing to prune")
    end
  end

  describe "prune --older-than --apply" do
    it "deletes entries and files and reports results" do
      old_date = (Time.utc - 60.days).to_s("%Y-%m-%d %H:%M:%S")
      old_id = seed_prune_session("apply-test", old_date)

      result = run_binary(["prune", "--older-than", "1m", "--apply"])

      result[:status].should eq(0)
      result[:output].should contain("Pruned session data older than 1m")
      result[:output].should contain("Entries deleted:")
      result[:output].should contain("Files deleted:")
      result[:output].should contain("Database:")
      result[:output].should contain("→")
      result[:output].should contain("preserved")

      # Entries and files should be gone
      remaining = GalaxyLedger::Database.query_by_session(old_id, 100)
      remaining.size.should eq(0)
    end

    it "preserves sessions, usages, and artifacts" do
      old_date = (Time.utc - 60.days).to_s("%Y-%m-%d %H:%M:%S")
      old_id = seed_prune_session("apply-preserve", old_date)

      run_binary(["prune", "--older-than", "1m", "--apply"])

      # Session record preserved
      session = GalaxyLedger::Database.get_session_by_id(old_id)
      session.should_not be_nil

      # Artifact preserved
      artifact_count = GalaxyLedger::Database.session_artifact_count(old_id)
      artifact_count.should eq(1)

      # Daily usage preserved
      usage_count = 0
      GalaxyLedger::Database.open do |db|
        usage_count = db.scalar(
          "SELECT COUNT(*) FROM ledger_session_daily_usages WHERE ledger_session_id = ?",
          old_id,
        ).as(Int64).to_i
      end
      usage_count.should eq(1)
    end

    it "does not touch recent sessions" do
      old_date = (Time.utc - 60.days).to_s("%Y-%m-%d %H:%M:%S")
      seed_prune_session("apply-old", old_date)

      recent_date = (Time.utc - 1.day).to_s("%Y-%m-%d %H:%M:%S")
      recent_id = seed_prune_session("apply-recent", recent_date)

      run_binary(["prune", "--older-than", "1m", "--apply"])

      # Recent session should be untouched
      remaining = GalaxyLedger::Database.query_by_session(recent_id, 100)
      remaining.size.should eq(2)
    end
  end

  describe "prune --older-than (invalid)" do
    it "shows error for invalid duration" do
      result = run_binary(["prune", "--older-than", "invalid"])

      result[:status].should eq(1)
      result[:error].should contain("Invalid duration")
      result[:error].should contain("Valid durations:")
    end
  end
end
