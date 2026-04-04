require "./spec_helper"

describe GalaxyAgents::SharedBackupConfig do
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
      File.write(
        SPEC_GALAXY_DIR / "config.json",
        shared_config,
      )

      config = GalaxyAgents::SharedBackupConfig.load

      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(7)
      config.backups.path.should eq("/custom/path")
    end

    it "returns defaults when file is missing" do
      File.delete(SPEC_GALAXY_DIR / "config.json")

      config = GalaxyAgents::SharedBackupConfig.load

      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")
    end

    it "returns defaults for malformed JSON" do
      File.write(
        SPEC_GALAXY_DIR / "config.json",
        "not valid json {{{",
      )

      config = GalaxyAgents::SharedBackupConfig.load

      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")
    end

    it "returns defaults when backups section missing" do
      File.write(
        SPEC_GALAXY_DIR / "config.json",
        {"_schema_version" => "0.0.1"}.to_json,
      )

      config = GalaxyAgents::SharedBackupConfig.load

      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")
    end
  end

  describe "#effective_backup_path" do
    it "returns default path when path is empty" do
      config = GalaxyAgents::SharedBackupConfig.new

      expected = GalaxyAgents::GALAXY_DIR /
                 "data" / "backups"
      config.effective_backup_path.should eq(expected)
    end

    it "returns custom path when set" do
      shared_config = {
        "backups" => {
          "enabled"        => true,
          "retention_days" => 3,
          "path"           => "/custom/backup/dir",
        },
      }.to_json
      File.write(
        SPEC_GALAXY_DIR / "config.json",
        shared_config,
      )

      config = GalaxyAgents::SharedBackupConfig.load

      config.effective_backup_path.should eq(
        Path.new("/custom/backup/dir"),
      )
    end
  end
end
