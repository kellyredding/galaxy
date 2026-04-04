require "./spec_helper"

describe GalaxySnapshots::SharedBackupConfig do
  describe ".load" do
    it "loads from shared Galaxy config" do
      shared_config = {
        "_schema_version" => "0.0.1",
        "backups"         => {
          "enabled"        => true,
          "retention_days" => 7,
          "path"           => "/custom/path",
        },
      }.to_json
      File.write(SPEC_GALAXY_DIR / "config.json", shared_config)

      config = GalaxySnapshots::SharedBackupConfig.load

      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(7)
      config.backups.path.should eq("/custom/path")
    end

    it "returns defaults when config file is missing" do
      File.delete(SPEC_GALAXY_DIR / "config.json") if File.exists?(SPEC_GALAXY_DIR / "config.json")

      config = GalaxySnapshots::SharedBackupConfig.load

      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")
    end

    it "returns defaults for malformed JSON" do
      File.write(SPEC_GALAXY_DIR / "config.json", "not valid json{{{")

      config = GalaxySnapshots::SharedBackupConfig.load

      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")
    end

    it "returns defaults when backups section is missing" do
      File.write(SPEC_GALAXY_DIR / "config.json", %({"_schema_version": "0.0.1"}))

      config = GalaxySnapshots::SharedBackupConfig.load

      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")
    end
  end

  describe "#effective_backup_path" do
    it "returns default path when backups.path is empty" do
      config = GalaxySnapshots::SharedBackupConfig.new

      path = config.effective_backup_path
      path.should eq(GalaxySnapshots::GALAXY_DIR / "data" / "backups")
    end

    it "returns custom path when backups.path is set" do
      backups = GalaxySnapshots::SharedBackupConfig::BackupsSection.new(
        path: "/custom/backup/dir",
      )
      config = GalaxySnapshots::SharedBackupConfig.new(backups: backups)

      config.effective_backup_path.should eq(Path.new("/custom/backup/dir"))
    end
  end
end
