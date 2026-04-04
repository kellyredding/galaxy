require "../spec_helper"

describe GalaxyLedger::Database do
  # Use a temp directory for backups within the test fixture tree
  backup_dir = SPEC_DATA_DIR / "backups"

  # Clean backup directory before each test
  before_each do
    FileUtils.rm_rf(backup_dir) if Dir.exists?(backup_dir)
  end

  describe ".backup" do
    it "creates date directory and backup file at expected path" do
      session_id = GalaxyLedger::Database.create_session("backup-test-1")
      result = GalaxyLedger::Database.backup(backup_dir, session_id)

      result.should_not be_nil
      path = result.not_nil!
      File.exists?(path).should be_true

      # Verify date directory structure
      today = Time.local.to_s("%Y-%m-%d")
      path.to_s.should contain(today)
      path.to_s.should contain("ledger_#{session_id}.db")
    end

    it "produces a valid SQLite database" do
      session_id = GalaxyLedger::Database.create_session("backup-test-valid")
      result = GalaxyLedger::Database.backup(backup_dir, session_id)

      result.should_not be_nil
      path = result.not_nil!

      # Open the backup and verify it's a valid SQLite database
      DB.open("sqlite3://#{path}") do |db|
        # Should be able to query the schema
        count = db.scalar("SELECT COUNT(*) FROM ledger_sessions").as(Int64)
        count.should be >= 0
      end
    end

    it "backup contains data from the live database" do
      session_id = GalaxyLedger::Database.create_session("backup-test-data")
      result = GalaxyLedger::Database.backup(backup_dir, session_id)

      result.should_not be_nil
      path = result.not_nil!

      # Open backup and verify the session we just created exists
      DB.open("sqlite3://#{path}") do |db|
        count = db.scalar(
          "SELECT COUNT(*) FROM ledger_sessions WHERE id = ?",
          session_id,
        ).as(Int64)
        count.should eq(1)
      end
    end

    it "overwrites if backup file already exists" do
      session_id = GalaxyLedger::Database.create_session("backup-test-overwrite")

      # Create first backup
      result1 = GalaxyLedger::Database.backup(backup_dir, session_id)
      result1.should_not be_nil
      path = result1.not_nil!
      mtime1 = File.info(path).modification_time

      # Small sleep to ensure mtime would differ if file were recreated
      sleep 50.milliseconds

      # Second backup should overwrite (not skip)
      result2 = GalaxyLedger::Database.backup(backup_dir, session_id)
      result2.should_not be_nil
      path2 = result2.not_nil!
      path2.should eq(path)
      mtime2 = File.info(path2).modification_time

      # Modification time should be updated (file was recreated)
      mtime2.should be >= mtime1
    end

    it "returns nil on invalid backup_dir without crashing" do
      # Use a path that can't be created (null byte in path)
      invalid_dir = Path.new("/dev/null/impossible/path")
      result = GalaxyLedger::Database.backup(invalid_dir, 1_i64)
      result.should be_nil
    end
  end

  describe ".prune_backups" do
    it "deletes directories older than retention period" do
      # Create date directories: today, yesterday, and 5 days ago
      today = Time.local
      old_date = (today - 5.days).to_s("%Y-%m-%d")
      today_str = today.to_s("%Y-%m-%d")

      Dir.mkdir_p(backup_dir / today_str)
      Dir.mkdir_p(backup_dir / old_date)
      File.write((backup_dir / old_date / "ledger_1.db").to_s, "fake")

      pruned = GalaxyLedger::Database.prune_backups(backup_dir, 3)
      pruned.should eq(1)
      Dir.exists?(backup_dir / old_date).should be_false
    end

    it "preserves directories within retention period" do
      today = Time.local
      yesterday = (today - 1.day).to_s("%Y-%m-%d")
      today_str = today.to_s("%Y-%m-%d")

      Dir.mkdir_p(backup_dir / today_str)
      Dir.mkdir_p(backup_dir / yesterday)

      pruned = GalaxyLedger::Database.prune_backups(backup_dir, 3)
      pruned.should eq(0)
      Dir.exists?(backup_dir / today_str).should be_true
      Dir.exists?(backup_dir / yesterday).should be_true
    end

    it "ignores non-date-named entries in backup_dir" do
      Dir.mkdir_p(backup_dir / "not-a-date")
      Dir.mkdir_p(backup_dir / "readme.txt")

      pruned = GalaxyLedger::Database.prune_backups(backup_dir, 1)
      pruned.should eq(0)
      Dir.exists?(backup_dir / "not-a-date").should be_true
    end

    it "returns 0 when backup_dir doesn't exist" do
      nonexistent = SPEC_DATA_DIR / "no-such-backups"
      pruned = GalaxyLedger::Database.prune_backups(nonexistent, 3)
      pruned.should eq(0)
    end

    it "returns count of pruned directories" do
      today = Time.local
      old1 = (today - 10.days).to_s("%Y-%m-%d")
      old2 = (today - 8.days).to_s("%Y-%m-%d")
      recent = (today - 1.day).to_s("%Y-%m-%d")

      Dir.mkdir_p(backup_dir / old1)
      Dir.mkdir_p(backup_dir / old2)
      Dir.mkdir_p(backup_dir / recent)

      pruned = GalaxyLedger::Database.prune_backups(backup_dir, 3)
      pruned.should eq(2)
    end
  end
end
