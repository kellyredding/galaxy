require "../spec_helper"

describe GalaxyArtifacts::Database do
  # Clean database before each test
  before_each do
    db_path = GalaxyArtifacts::Database.database_path
    File.delete(db_path) if File.exists?(db_path)
  end

  describe ".vacuum_database" do
    it "returns before and after sizes" do
      # Ensure DB exists with some data
      GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "Vacuum test", artifact_type: "text", mime_type: "text/plain",
        original_filename: "a.txt", stored_path: "", source_path: "/tmp/a.txt",
        file_size: 10_i64, content_hash: "h1",
      )

      result = GalaxyArtifacts::Database.vacuum_database
      result[:before].should be > 0
      result[:after].should be > 0
    end
  end

  describe ".backup" do
    it "creates a backup file" do
      backup_dir = Path.new(Dir.tempdir) / "galaxy-artifacts-backup-test-#{Random.rand(100000)}"
      begin
        # Ensure DB exists with data
        GalaxyArtifacts::Database.save_artifact(
          1_i64, title: "Backup test", artifact_type: "text", mime_type: "text/plain",
          original_filename: "a.txt", stored_path: "", source_path: "/tmp/a.txt",
          file_size: 10_i64, content_hash: "h1",
        )

        result = GalaxyArtifacts::Database.backup(backup_dir, 1_i64)
        result.should_not be_nil

        backup_path = result.not_nil!
        File.exists?(backup_path).should be_true
        File.size(backup_path).should be > 0
      ensure
        FileUtils.rm_rf(backup_dir.to_s)
      end
    end

    it "overwrites existing backup when called twice with the same session ID" do
      backup_dir = Path.new(Dir.tempdir) / "galaxy-artifacts-backup-test-#{Random.rand(100000)}"
      begin
        GalaxyArtifacts::Database.save_artifact(
          1_i64, title: "Overwrite test", artifact_type: "text", mime_type: "text/plain",
          original_filename: "a.txt", stored_path: "", source_path: "/tmp/a.txt",
          file_size: 10_i64, content_hash: "h1",
        )

        r1 = GalaxyArtifacts::Database.backup(backup_dir, 1_i64)
        r1.should_not be_nil
        first_mtime = File.info(r1.not_nil!).modification_time

        # Add more data so the backup content changes
        GalaxyArtifacts::Database.save_artifact(
          1_i64, title: "Extra row", artifact_type: "text", mime_type: "text/plain",
          original_filename: "b.txt", stored_path: "", source_path: "/tmp/b.txt",
          file_size: 20_i64, content_hash: "h2",
        )

        # Small delay to ensure mtime differs
        sleep 50.milliseconds

        r2 = GalaxyArtifacts::Database.backup(backup_dir, 1_i64)
        r2.should_not be_nil
        r2.not_nil!.to_s.should eq(r1.not_nil!.to_s)

        second_mtime = File.info(r2.not_nil!).modification_time
        second_mtime.should be > first_mtime
      ensure
        FileUtils.rm_rf(backup_dir.to_s)
      end
    end
  end

  describe ".prune_backups" do
    it "removes directories older than retention days" do
      backup_dir = Path.new(Dir.tempdir) / "galaxy-artifacts-prune-test-#{Random.rand(100000)}"
      begin
        Dir.mkdir_p(backup_dir)

        # Create old directory (10 days ago)
        old_date = (Time.local - 10.days).to_s("%Y-%m-%d")
        old_dir = backup_dir / old_date
        Dir.mkdir_p(old_dir)
        File.write(old_dir / "artifacts_1.db", "fake backup")

        # Create recent directory (today)
        today = Time.local.to_s("%Y-%m-%d")
        today_dir = backup_dir / today
        Dir.mkdir_p(today_dir)
        File.write(today_dir / "artifacts_1.db", "fake backup")

        pruned = GalaxyArtifacts::Database.prune_backups(backup_dir, 3)
        pruned.should eq(1)

        # Old dir should be gone, today should remain
        Dir.exists?(old_dir).should be_false
        Dir.exists?(today_dir).should be_true
      ensure
        FileUtils.rm_rf(backup_dir.to_s)
      end
    end

    it "returns 0 when nothing to prune" do
      backup_dir = Path.new(Dir.tempdir) / "galaxy-artifacts-prune-empty-#{Random.rand(100000)}"
      begin
        Dir.mkdir_p(backup_dir)

        pruned = GalaxyArtifacts::Database.prune_backups(backup_dir, 3)
        pruned.should eq(0)
      ensure
        FileUtils.rm_rf(backup_dir.to_s)
      end
    end

    it "returns 0 for nonexistent directory" do
      pruned = GalaxyArtifacts::Database.prune_backups(
        Path.new("/tmp/nonexistent-prune-dir-#{Random.rand(100000)}"),
        3,
      )
      pruned.should eq(0)
    end

    it "ignores non-date-named directories" do
      backup_dir = Path.new(Dir.tempdir) / "galaxy-artifacts-prune-nondate-#{Random.rand(100000)}"
      begin
        Dir.mkdir_p(backup_dir)
        Dir.mkdir_p(backup_dir / "not-a-date")
        Dir.mkdir_p(backup_dir / "random-dir")

        pruned = GalaxyArtifacts::Database.prune_backups(backup_dir, 0)
        pruned.should eq(0)
      ensure
        FileUtils.rm_rf(backup_dir.to_s)
      end
    end
  end
end
