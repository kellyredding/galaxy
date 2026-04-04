require "./spec_helper"

describe GalaxyArtifacts::SharedBackupConfig do
  describe ".load" do
    it "loads backup settings from shared Galaxy config" do
      shared_config = {
        "_schema_version" => "0.0.1",
        "backups"         => {
          "enabled"        => true,
          "retention_days" => 7,
          "path"           => "/custom/path",
        },
      }.to_json
      File.write(SPEC_GALAXY_DIR / "config.json", shared_config)

      config = GalaxyArtifacts::SharedBackupConfig.load

      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(7)
      config.backups.path.should eq("/custom/path")
    end

    it "returns defaults when config file does not exist" do
      File.delete(SPEC_GALAXY_DIR / "config.json") if File.exists?(SPEC_GALAXY_DIR / "config.json")

      config = GalaxyArtifacts::SharedBackupConfig.load

      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")
    end

    it "returns defaults when config file contains malformed JSON" do
      File.write(SPEC_GALAXY_DIR / "config.json", "not valid json {{{")

      config = GalaxyArtifacts::SharedBackupConfig.load

      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")
    end

    it "returns defaults for missing backups section" do
      File.write(SPEC_GALAXY_DIR / "config.json", %({"_schema_version": "0.0.1"}))

      config = GalaxyArtifacts::SharedBackupConfig.load

      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")
    end
  end

  describe "#effective_backup_path" do
    it "returns default path when backups.path is empty" do
      File.write(SPEC_GALAXY_DIR / "config.json", SPEC_DEFAULT_SHARED_CONFIG)

      config = GalaxyArtifacts::SharedBackupConfig.load

      expected = GalaxyArtifacts::GALAXY_DIR / "data" / "backups"
      config.effective_backup_path.should eq(expected)
    end

    it "returns custom path when backups.path is set" do
      shared_config = {
        "_schema_version" => "0.0.1",
        "backups"         => {
          "enabled"        => true,
          "retention_days" => 3,
          "path"           => "/custom/backup/dir",
        },
      }.to_json
      File.write(SPEC_GALAXY_DIR / "config.json", shared_config)

      config = GalaxyArtifacts::SharedBackupConfig.load

      config.effective_backup_path.should eq(Path.new("/custom/backup/dir"))
    end
  end
end
