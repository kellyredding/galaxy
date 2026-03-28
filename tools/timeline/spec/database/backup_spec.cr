require "../spec_helper"

describe GalaxyTimeline::Database do
  describe ".vacuum_database" do
    it "returns before and after sizes" do
      # Ensure DB exists with some data
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
      )

      result = GalaxyTimeline::Database.vacuum_database
      result[:before].should be > 0
      result[:after].should be > 0
    end
  end

  describe ".backup" do
    it "creates a backup file" do
      backup_dir = Path.new(Dir.tempdir) / "galaxy-timeline-backup-test-#{Random.rand(100000)}"
      begin
        # Ensure DB exists with data
        GalaxyTimeline::Database.record_event(
          1_i64,
          event_type: "session:started",
          source: "galaxy-ledger/hooks/on_startup",
        )

        result = GalaxyTimeline::Database.backup(backup_dir, 1_i64)
        result.should_not be_nil

        backup_path = result.not_nil!
        File.exists?(backup_path).should be_true
        File.size(backup_path).should be > 0
      ensure
        FileUtils.rm_rf(backup_dir.to_s)
      end
    end

    it "is idempotent — returns existing path if already backed up" do
      backup_dir = Path.new(Dir.tempdir) / "galaxy-timeline-backup-test-#{Random.rand(100000)}"
      begin
        GalaxyTimeline::Database.record_event(
          1_i64,
          event_type: "session:started",
          source: "galaxy-ledger/hooks/on_startup",
        )

        r1 = GalaxyTimeline::Database.backup(backup_dir, 1_i64)
        r2 = GalaxyTimeline::Database.backup(backup_dir, 1_i64)

        r1.should_not be_nil
        r2.should_not be_nil
        r1.not_nil!.to_s.should eq(r2.not_nil!.to_s)
      ensure
        FileUtils.rm_rf(backup_dir.to_s)
      end
    end
  end

  describe ".prune_backups" do
    it "removes directories older than retention days" do
      backup_dir = Path.new(Dir.tempdir) / "galaxy-timeline-prune-test-#{Random.rand(100000)}"
      begin
        Dir.mkdir_p(backup_dir)

        # Create old directory (10 days ago)
        old_date = (Time.local - 10.days).to_s("%Y-%m-%d")
        old_dir = backup_dir / old_date
        Dir.mkdir_p(old_dir)
        File.write(old_dir / "timeline_1.db", "fake backup")

        # Create recent directory (today)
        today = Time.local.to_s("%Y-%m-%d")
        today_dir = backup_dir / today
        Dir.mkdir_p(today_dir)
        File.write(today_dir / "timeline_1.db", "fake backup")

        pruned = GalaxyTimeline::Database.prune_backups(backup_dir, 3)
        pruned.should eq(1)

        # Old dir should be gone, today should remain
        Dir.exists?(old_dir).should be_false
        Dir.exists?(today_dir).should be_true
      ensure
        FileUtils.rm_rf(backup_dir.to_s)
      end
    end

    it "returns 0 when nothing to prune" do
      backup_dir = Path.new(Dir.tempdir) / "galaxy-timeline-prune-empty-#{Random.rand(100000)}"
      begin
        Dir.mkdir_p(backup_dir)

        pruned = GalaxyTimeline::Database.prune_backups(backup_dir, 3)
        pruned.should eq(0)
      ensure
        FileUtils.rm_rf(backup_dir.to_s)
      end
    end

    it "returns 0 for nonexistent directory" do
      pruned = GalaxyTimeline::Database.prune_backups(
        Path.new("/tmp/nonexistent-prune-dir-#{Random.rand(100000)}"),
        3,
      )
      pruned.should eq(0)
    end

    it "ignores non-date-named directories" do
      backup_dir = Path.new(Dir.tempdir) / "galaxy-timeline-prune-nondate-#{Random.rand(100000)}"
      begin
        Dir.mkdir_p(backup_dir)
        Dir.mkdir_p(backup_dir / "not-a-date")
        Dir.mkdir_p(backup_dir / "random-dir")

        pruned = GalaxyTimeline::Database.prune_backups(backup_dir, 0)
        pruned.should eq(0)
      ensure
        FileUtils.rm_rf(backup_dir.to_s)
      end
    end
  end
end
