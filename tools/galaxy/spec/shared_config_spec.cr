require "./spec_helper"

describe Galaxy::SharedConfig do
  describe ".default" do
    it "returns a config with default values" do
      config = Galaxy::SharedConfig.default
      config.schema_version.should eq(Galaxy::VERSION)
      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")
    end
  end

  describe "#effective_backup_path" do
    it "returns default path when path is empty" do
      config = Galaxy::SharedConfig.default
      expected = Galaxy::GALAXY_DIR / "data" / "backups"
      config.effective_backup_path.should eq(expected)
    end

    it "returns custom path when path is set" do
      config = Galaxy::SharedConfig.default
      config.backups.path = "/custom/backup/dir"
      config.effective_backup_path.should eq(
        Path.new("/custom/backup/dir"),
      )
    end
  end

  describe ".load" do
    it "creates default config when file does not exist" do
      config_file = Galaxy::CONFIG_FILE
      File.delete(config_file) if File.exists?(config_file)

      config = Galaxy::SharedConfig.load

      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")

      # Should have written the file
      File.exists?(config_file).should be_true
    end

    it "loads config from file" do
      config = Galaxy::SharedConfig.default
      config.backups.retention_days = 7
      config.backups.path = "/some/path"
      config.save

      loaded = Galaxy::SharedConfig.load
      loaded.backups.retention_days.should eq(7)
      loaded.backups.path.should eq("/some/path")
    end

    it "falls back to defaults on malformed JSON" do
      File.write(
        Galaxy::CONFIG_FILE,
        "not valid json {{{",
      )

      config = Galaxy::SharedConfig.load
      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(3)
    end
  end

  describe "#save and load round-trip" do
    it "preserves all fields" do
      config = Galaxy::SharedConfig.default
      config.backups.enabled = false
      config.backups.retention_days = 14
      config.backups.path = "/my/backups"
      config.save

      loaded = Galaxy::SharedConfig.load
      loaded.backups.enabled.should be_false
      loaded.backups.retention_days.should eq(14)
      loaded.backups.path.should eq("/my/backups")
      loaded.schema_version.should eq(Galaxy::VERSION)
    end
  end

  describe "#to_pretty_json" do
    it "produces valid JSON" do
      config = Galaxy::SharedConfig.default
      json = config.to_pretty_json
      parsed = JSON.parse(json)
      parsed["_schema_version"].as_s.should eq(
        Galaxy::VERSION,
      )
      parsed["backups"]["enabled"].as_bool.should be_true
      parsed["backups"]["retention_days"].as_i.should eq(3)
      parsed["backups"]["path"].as_s.should eq("")
    end
  end

  describe "#set" do
    it "sets backups.enabled" do
      config = Galaxy::SharedConfig.default
      config.set("backups.enabled", "false")
      config.backups.enabled.should be_false
    end

    it "sets backups.retention_days" do
      config = Galaxy::SharedConfig.default
      config.set("backups.retention_days", "7")
      config.backups.retention_days.should eq(7)
    end

    it "sets backups.path" do
      config = Galaxy::SharedConfig.default
      config.set("backups.path", "/new/path")
      config.backups.path.should eq("/new/path")
    end

    it "raises on unknown top-level key" do
      config = Galaxy::SharedConfig.default
      expect_raises(Exception, "Unknown setting") do
        config.set("nonexistent.key", "value")
      end
    end

    it "raises on unknown backups field" do
      config = Galaxy::SharedConfig.default
      expect_raises(Exception, "Unknown backups field") do
        config.set("backups.nonexistent", "value")
      end
    end

    it "raises on missing backups field" do
      config = Galaxy::SharedConfig.default
      expect_raises(Exception, "Missing backups field") do
        config.set("backups", "value")
      end
    end

    it "raises on invalid boolean for backups.enabled" do
      config = Galaxy::SharedConfig.default
      expect_raises(Exception, "Invalid boolean value") do
        config.set("backups.enabled", "maybe")
      end
    end

    it "raises on non-integer for retention_days" do
      config = Galaxy::SharedConfig.default
      expect_raises(Exception, "must be integer") do
        config.set("backups.retention_days", "abc")
      end
    end

    it "raises on retention_days < 1" do
      config = Galaxy::SharedConfig.default
      expect_raises(Exception, "must be >= 1") do
        config.set("backups.retention_days", "0")
      end
    end

    it "accepts boolean synonyms" do
      config = Galaxy::SharedConfig.default

      config.set("backups.enabled", "yes")
      config.backups.enabled.should be_true

      config.set("backups.enabled", "no")
      config.backups.enabled.should be_false

      config.set("backups.enabled", "1")
      config.backups.enabled.should be_true

      config.set("backups.enabled", "0")
      config.backups.enabled.should be_false
    end
  end

  describe "#get" do
    it "gets backups.enabled" do
      config = Galaxy::SharedConfig.default
      config.get("backups.enabled").should eq("true")
    end

    it "gets backups.retention_days" do
      config = Galaxy::SharedConfig.default
      config.get("backups.retention_days").should eq("3")
    end

    it "gets backups.path" do
      config = Galaxy::SharedConfig.default
      config.get("backups.path").should eq("")
    end

    it "raises on unknown top-level key" do
      config = Galaxy::SharedConfig.default
      expect_raises(Exception, "Unknown setting") do
        config.get("nonexistent.key")
      end
    end

    it "raises on unknown backups field" do
      config = Galaxy::SharedConfig.default
      expect_raises(Exception, "Unknown backups field") do
        config.get("backups.nonexistent")
      end
    end

    it "raises on missing backups field" do
      config = Galaxy::SharedConfig.default
      expect_raises(Exception, "Missing backups field") do
        config.get("backups")
      end
    end
  end
end
