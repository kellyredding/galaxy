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
      config.buffer.flush_threshold.should eq(50)
      config.buffer.flush_interval_seconds.should eq(300)
      config.restoration.max_essential_tokens.should eq(2000)
      config.restoration.tier1_limits.high_importance_decisions.should eq(10)
      config.restoration.tier2_limits.learnings.should eq(5)
      config.restoration.tier2_limits.file_edits.should eq(10)
      config.restoration.tier2_limits.medium_importance_decisions.should eq(5)
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

    it "sets and gets buffer values" do
      config = GalaxyLedger::Config.default
      config.set("buffer.flush_threshold", "100")
      config.get("buffer.flush_threshold").should eq("100")

      config.set("buffer.flush_interval_seconds", "600")
      config.get("buffer.flush_interval_seconds").should eq("600")
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

      config.set("restoration.tier2_limits.file_edits", "20")
      config.get("restoration.tier2_limits.file_edits").should eq("20")

      config.set("restoration.tier2_limits.medium_importance_decisions", "8")
      config.get("restoration.tier2_limits.medium_importance_decisions").should eq("8")
    end

    it "validates threshold range" do
      config = GalaxyLedger::Config.default
      expect_raises(Exception, /between 0 and 100/) do
        config.set("thresholds.warning", "150")
      end
    end

    it "validates positive buffer values" do
      config = GalaxyLedger::Config.default
      expect_raises(Exception, /must be positive/) do
        config.set("buffer.flush_threshold", "0")
      end
    end

    it "raises for unknown keys" do
      config = GalaxyLedger::Config.default
      expect_raises(Exception, /Unknown setting/) do
        config.set("nonexistent", "value")
      end
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
end
