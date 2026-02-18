require "../spec_helper"

describe GalaxyLedger::Config do
  describe ".default" do
    it "creates a config with default values" do
      config = GalaxyLedger::Config.default

      config.version.should eq(GalaxyLedger::VERSION)
      config.thresholds.warning.should eq(70)
      config.thresholds.critical.should eq(85)
      config.warnings.at_warning_threshold.should eq(true)
      config.warnings.at_critical_threshold.should eq(true)
      config.extraction.on_stop.should eq(true)
      config.extraction.on_guideline_read.should eq(true)
      config.storage.postgres_enabled.should eq(false)
      config.storage.postgres_host_port.should eq(5433)
      config.storage.embeddings_enabled.should eq(false)
      config.storage.openai_api_key_env_var.should eq("GALAXY_OPENAI_API_KEY")
      config.restoration.max_essential_tokens.should eq(2000)
      config.restoration.tier1_limits.high_importance_decisions.should eq(10)
      config.restoration.tier2_limits.learnings.should eq(5)
      config.restoration.tier2_limits.medium_importance_decisions.should eq(5)
      config.snapshots.inline_char_cap.should eq(15000)
      config.snapshots.max_per_session.should eq(10)
      config.snapshots.editor.should eq("")
      config.backups.enabled.should eq(true)
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")
    end
  end

  describe ".load" do
    it "creates default config when file doesn't exist" do
      # Clean up any existing config
      FileUtils.rm_rf(GalaxyLedger::CONFIG_DIR.to_s)

      config = GalaxyLedger::Config.load
      config.thresholds.warning.should eq(70)

      # Should have created the file
      File.exists?(GalaxyLedger::CONFIG_FILE).should eq(true)
    end

    it "migrates config missing snapshots.editor field" do
      # Write a v0.2.0 config without the editor field
      Dir.mkdir_p(GalaxyLedger::CONFIG_DIR)
      File.write(GalaxyLedger::CONFIG_FILE, {
        "_schema_version" => "0.2.0",
        "version"         => "0.2.0",
        "thresholds"      => {"warning" => 70, "critical" => 85},
        "warnings"        => {"at_warning_threshold" => true, "at_critical_threshold" => true},
        "extraction"      => {"on_stop" => true, "on_guideline_read" => true},
        "storage"         => {
          "postgres_enabled"       => false,
          "postgres_host_port"     => 5433,
          "embeddings_enabled"     => false,
          "openai_api_key_env_var" => "GALAXY_OPENAI_API_KEY",
        },
        "restoration" => {
          "max_essential_tokens" => 2000,
          "tier1_limits"         => {"high_importance_decisions" => 10},
          "tier2_limits"         => {"learnings" => 5, "medium_importance_decisions" => 5},
        },
        "snapshots" => {
          "inline_char_cap" => 15000,
          "max_per_session" => 10,
        },
      }.to_json)

      config = GalaxyLedger::Config.load
      config.snapshots.editor.should eq("")
      config.snapshots.inline_char_cap.should eq(15000)
      config.snapshots.max_per_session.should eq(10)
    end
  end

  describe "#set and #get" do
    it "sets and gets threshold values" do
      config = GalaxyLedger::Config.default
      config.set("thresholds.warning", "75")
      config.get("thresholds.warning").should eq("75")
    end

    it "sets and gets warnings values" do
      config = GalaxyLedger::Config.default
      config.set("warnings.at_warning_threshold", "false")
      config.get("warnings.at_warning_threshold").should eq("false")
    end

    it "sets and gets extraction values" do
      config = GalaxyLedger::Config.default
      config.set("extraction.on_stop", "false")
      config.get("extraction.on_stop").should eq("false")
    end

    it "sets and gets storage values" do
      config = GalaxyLedger::Config.default
      config.set("storage.postgres_enabled", "true")
      config.get("storage.postgres_enabled").should eq("true")

      config.set("storage.postgres_host_port", "5434")
      config.get("storage.postgres_host_port").should eq("5434")

      config.set("storage.openai_api_key_env_var", "MY_KEY")
      config.get("storage.openai_api_key_env_var").should eq("MY_KEY")
    end

    it "sets and gets restoration values" do
      config = GalaxyLedger::Config.default
      config.set("restoration.max_essential_tokens", "3000")
      config.get("restoration.max_essential_tokens").should eq("3000")
    end

    it "sets and gets tier1_limits values" do
      config = GalaxyLedger::Config.default
      config.set("restoration.tier1_limits.high_importance_decisions", "15")
      config.get("restoration.tier1_limits.high_importance_decisions").should eq("15")
    end

    it "sets and gets tier2_limits values" do
      config = GalaxyLedger::Config.default
      config.set("restoration.tier2_limits.learnings", "10")
      config.get("restoration.tier2_limits.learnings").should eq("10")

      config.set("restoration.tier2_limits.medium_importance_decisions", "8")
      config.get("restoration.tier2_limits.medium_importance_decisions").should eq("8")
    end

    it "sets and gets snapshots values" do
      config = GalaxyLedger::Config.default
      config.get("snapshots.inline_char_cap").should eq("15000")
      config.get("snapshots.max_per_session").should eq("10")
      config.get("snapshots.editor").should eq("")

      config.set("snapshots.inline_char_cap", "20000")
      config.get("snapshots.inline_char_cap").should eq("20000")

      config.set("snapshots.max_per_session", "5")
      config.get("snapshots.max_per_session").should eq("5")

      config.set("snapshots.editor", "subl")
      config.get("snapshots.editor").should eq("subl")
    end

    it "validates snapshots values are positive integers" do
      config = GalaxyLedger::Config.default
      expect_raises(Exception, /must be integer/) do
        config.set("snapshots.inline_char_cap", "abc")
      end
    end

    it "validates snapshots values are positive" do
      config = GalaxyLedger::Config.default
      expect_raises(Exception, /must be positive/) do
        config.set("snapshots.max_per_session", "0")
      end
    end

    it "validates threshold range" do
      config = GalaxyLedger::Config.default
      expect_raises(Exception, /between 0 and 100/) do
        config.set("thresholds.warning", "150")
      end
    end

    it "sets and gets backups values" do
      config = GalaxyLedger::Config.default
      config.get("backups.enabled").should eq("true")
      config.get("backups.retention_days").should eq("3")
      config.get("backups.path").should eq("")

      config.set("backups.enabled", "false")
      config.get("backups.enabled").should eq("false")

      config.set("backups.retention_days", "7")
      config.get("backups.retention_days").should eq("7")

      config.set("backups.path", "/custom/backup/path")
      config.get("backups.path").should eq("/custom/backup/path")
    end

    it "validates backups.retention_days must be >= 1" do
      config = GalaxyLedger::Config.default
      expect_raises(Exception, />= 1/) do
        config.set("backups.retention_days", "0")
      end
    end

    it "validates backups.retention_days must be integer" do
      config = GalaxyLedger::Config.default
      expect_raises(Exception, /must be integer/) do
        config.set("backups.retention_days", "abc")
      end
    end

    it "raises for unknown keys" do
      config = GalaxyLedger::Config.default
      expect_raises(Exception, /Unknown setting/) do
        config.set("nonexistent", "value")
      end
    end
  end

  describe "#effective_backup_path" do
    it "returns default when path is empty" do
      config = GalaxyLedger::Config.default
      config.effective_backup_path.should eq(GalaxyLedger::DATA_DIR / "backups")
    end

    it "returns custom path when set" do
      config = GalaxyLedger::Config.default
      config.set("backups.path", "/custom/backup/path")
      config.effective_backup_path.should eq(Path.new("/custom/backup/path"))
    end
  end

  describe "#to_pretty_json" do
    it "produces valid JSON" do
      config = GalaxyLedger::Config.default
      json = config.to_pretty_json

      # Should be valid JSON that can be parsed back
      parsed = GalaxyLedger::Config.from_json(json)
      parsed.thresholds.warning.should eq(70)
    end
  end

  describe "config migration for backups" do
    it "migrates config missing backups section" do
      # Write a v0.3.0 config without the backups section
      Dir.mkdir_p(GalaxyLedger::CONFIG_DIR)
      File.write(GalaxyLedger::CONFIG_FILE, {
        "_schema_version" => "0.3.0",
        "version"         => "0.3.0",
        "thresholds"      => {"warning" => 70, "critical" => 85},
        "warnings"        => {"at_warning_threshold" => true, "at_critical_threshold" => true},
        "extraction"      => {"on_stop" => true, "on_guideline_read" => true},
        "storage"         => {
          "postgres_enabled"       => false,
          "postgres_host_port"     => 5433,
          "embeddings_enabled"     => false,
          "openai_api_key_env_var" => "GALAXY_OPENAI_API_KEY",
        },
        "restoration" => {
          "max_essential_tokens" => 2000,
          "tier1_limits"         => {"high_importance_decisions" => 10},
          "tier2_limits"         => {"learnings" => 5, "medium_importance_decisions" => 5},
        },
        "snapshots" => {
          "inline_char_cap" => 15000,
          "max_per_session" => 10,
          "editor"          => "",
        },
      }.to_json)

      config = GalaxyLedger::Config.load
      config.backups.enabled.should eq(true)
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")
    end
  end
end
