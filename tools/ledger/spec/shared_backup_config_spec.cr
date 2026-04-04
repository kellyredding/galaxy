require "./spec_helper"

describe GalaxyLedger::SharedBackupConfig do
  describe ".load" do
    it "loads from shared Galaxy config" do
      shared_config = {
        "_schema_version" => "0.0.1",
        "backups"         => {
          "enabled"        => true,
          "retention_days" => 5,
          "path"           => "/custom/path",
        },
      }
      File.write(
        SPEC_GALAXY_DIR / "config.json",
        shared_config.to_json,
      )

      config = GalaxyLedger::SharedBackupConfig.load
      config.backups.enabled.should eq(true)
      config.backups.retention_days.should eq(5)
      config.backups.path.should eq("/custom/path")
    end

    it "returns defaults when file is missing" do
      File.delete(SPEC_GALAXY_DIR / "config.json") if File.exists?(SPEC_GALAXY_DIR / "config.json")

      config = GalaxyLedger::SharedBackupConfig.load
      config.backups.enabled.should eq(true)
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")
    end

    it "returns defaults for malformed JSON" do
      File.write(
        SPEC_GALAXY_DIR / "config.json",
        "not valid json {{{",
      )

      config = GalaxyLedger::SharedBackupConfig.load
      config.backups.enabled.should eq(true)
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")
    end

    it "returns defaults for JSON missing backups section" do
      File.write(
        SPEC_GALAXY_DIR / "config.json",
        {"_schema_version" => "0.0.1"}.to_json,
      )

      config = GalaxyLedger::SharedBackupConfig.load
      config.backups.enabled.should eq(true)
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")
    end
  end

  describe "#effective_backup_path" do
    it "returns default when path is empty" do
      config = GalaxyLedger::SharedBackupConfig.new
      config.effective_backup_path.should eq(
        GalaxyLedger::GALAXY_DIR / "data" / "backups",
      )
    end

    it "returns custom path when set" do
      backups = GalaxyLedger::SharedBackupConfig::BackupsSection.new(
        path: "/custom/backup/path",
      )
      config = GalaxyLedger::SharedBackupConfig.new(backups: backups)
      config.effective_backup_path.should eq(
        Path.new("/custom/backup/path"),
      )
    end
  end
end
