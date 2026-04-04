require "../spec_helper"

describe GalaxyAgents::Database do
  before_each do
    db_path = GalaxyAgents::Database.database_path
    File.delete(db_path) if File.exists?(db_path)
  end

  describe ".vacuum_database" do
    it "returns before and after sizes" do
      GalaxyAgents::Database.start_agent(
        1_i64, "a1", "Explore",
      )

      result = GalaxyAgents::Database.vacuum_database
      result[:before].should be > 0
      result[:after].should be > 0
    end
  end

  describe ".backup" do
    it "creates a backup file" do
      backup_dir = Path.new(Dir.tempdir) /
                   "galaxy-agents-backup-test-#{
  Random.rand(100000)
}"
      begin
        GalaxyAgents::Database.start_agent(
          1_i64, "a1", "Explore",
        )

        result = GalaxyAgents::Database.backup(
          backup_dir, 1_i64,
        )
        result.should_not be_nil

        backup_path = result.not_nil!
        File.exists?(backup_path).should be_true
        File.size(backup_path).should be > 0
      ensure
        FileUtils.rm_rf(backup_dir.to_s)
      end
    end

    it "overwrites when called twice with same session" do
      backup_dir = Path.new(Dir.tempdir) /
                   "galaxy-agents-backup-test-#{
  Random.rand(100000)
}"
      begin
        GalaxyAgents::Database.start_agent(
          1_i64, "a1", "Explore",
        )

        r1 = GalaxyAgents::Database.backup(
          backup_dir, 1_i64,
        )
        r1.should_not be_nil
        backup_path = r1.not_nil!
        File.exists?(backup_path).should be_true
        size1 = File.size(backup_path)

        r2 = GalaxyAgents::Database.backup(
          backup_dir, 1_i64,
        )
        r2.should_not be_nil
        r2.not_nil!.to_s.should eq(
          backup_path.to_s,
        )
        File.exists?(backup_path).should be_true
        File.size(backup_path).should be > 0
      ensure
        FileUtils.rm_rf(backup_dir.to_s)
      end
    end
  end

  describe ".prune_backups" do
    it "removes directories older than retention" do
      backup_dir = Path.new(Dir.tempdir) /
                   "galaxy-agents-prune-test-#{
  Random.rand(100000)
}"
      begin
        Dir.mkdir_p(backup_dir)

        old_date = (Time.local - 10.days)
          .to_s("%Y-%m-%d")
        old_dir = backup_dir / old_date
        Dir.mkdir_p(old_dir)
        File.write(
          old_dir / "agents_1.db", "fake backup",
        )

        today = Time.local.to_s("%Y-%m-%d")
        today_dir = backup_dir / today
        Dir.mkdir_p(today_dir)
        File.write(
          today_dir / "agents_1.db", "fake backup",
        )

        pruned = GalaxyAgents::Database.prune_backups(
          backup_dir, 3,
        )
        pruned.should eq(1)

        Dir.exists?(old_dir).should be_false
        Dir.exists?(today_dir).should be_true
      ensure
        FileUtils.rm_rf(backup_dir.to_s)
      end
    end

    it "returns 0 when nothing to prune" do
      backup_dir = Path.new(Dir.tempdir) /
                   "galaxy-agents-prune-empty-#{
  Random.rand(100000)
}"
      begin
        Dir.mkdir_p(backup_dir)
        pruned = GalaxyAgents::Database.prune_backups(
          backup_dir, 3,
        )
        pruned.should eq(0)
      ensure
        FileUtils.rm_rf(backup_dir.to_s)
      end
    end

    it "returns 0 for nonexistent directory" do
      pruned = GalaxyAgents::Database.prune_backups(
        Path.new(
          "/tmp/nonexistent-prune-dir-#{
  Random.rand(100000)
}",
        ),
        3,
      )
      pruned.should eq(0)
    end

    it "ignores non-date-named directories" do
      backup_dir = Path.new(Dir.tempdir) /
                   "galaxy-agents-prune-nondate-#{
  Random.rand(100000)
}"
      begin
        Dir.mkdir_p(backup_dir)
        Dir.mkdir_p(backup_dir / "not-a-date")
        Dir.mkdir_p(backup_dir / "random-dir")

        pruned = GalaxyAgents::Database.prune_backups(
          backup_dir, 0,
        )
        pruned.should eq(0)
      ensure
        FileUtils.rm_rf(backup_dir.to_s)
      end
    end
  end
end
