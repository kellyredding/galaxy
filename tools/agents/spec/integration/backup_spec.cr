require "../spec_helper"

describe "CLI backup command", tags: "integration" do
  describe "--list" do
    it "shows no backups message" do
      result = run_binary(["backup", "--list"])

      result[:status].should eq(0)
      result[:output].should contain("No backups found")
    end
  end

  describe "create and prune" do
    it "creates a backup when enabled" do
      backup_dir = Path.new(Dir.tempdir) /
                   "galaxy-agents-backup-cli-#{
  Random.rand(100000)
}"
      begin
        config = GalaxyAgents::Config.load
        config.backups.enabled = true
        config.backups.path = backup_dir.to_s
        config.save

        run_binary([
          "start", "--ledger-session-id", "1",
          "--agent-id", "b1",
          "--agent-type", "Explore",
        ])

        result = run_binary([
          "backup", "--session-id", "1",
        ])

        result[:status].should eq(0)
        result[:output].should contain("Backup created")
      ensure
        FileUtils.rm_rf(backup_dir.to_s)
      end
    end

    it "shows disabled message when backups disabled" do
      result = run_binary([
        "backup", "--session-id", "1",
      ])

      result[:status].should eq(0)
      result[:output].should contain(
        "Backups are disabled",
      )
    end
  end

  describe "--prune-only" do
    it "prunes old backup directories" do
      backup_dir = Path.new(Dir.tempdir) /
                   "galaxy-agents-prune-cli-#{
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

        config = GalaxyAgents::Config.load
        config.backups.path = backup_dir.to_s
        config.backups.retention_days = 3
        config.save

        result = run_binary([
          "backup", "--prune-only",
        ])

        result[:status].should eq(0)
        result[:output].should contain(
          "Pruned 1 old backup directory",
        )
      ensure
        FileUtils.rm_rf(backup_dir.to_s)
      end
    end

    it "shows nothing to prune message" do
      backup_dir = Path.new(Dir.tempdir) /
                   "galaxy-agents-prune-empty-cli-#{
  Random.rand(100000)
}"
      begin
        Dir.mkdir_p(backup_dir)

        config = GalaxyAgents::Config.load
        config.backups.path = backup_dir.to_s
        config.save

        result = run_binary([
          "backup", "--prune-only",
        ])

        result[:status].should eq(0)
        result[:output].should contain(
          "No backups to prune",
        )
      ensure
        FileUtils.rm_rf(backup_dir.to_s)
      end
    end
  end

  describe "help" do
    it "shows backup help" do
      result = run_binary(["backup", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("backup")
    end
  end
end
