require "./spec_helper"

describe GalaxyTimeline::SharedBackupConfig do
  describe ".load" do
    it "loads from shared Galaxy config file" do
      shared_config = {
        "_schema_version" => "0.0.1",
        "backups"         => {
          "enabled"        => true,
          "retention_days" => 7,
          "path"           => "/custom/path",
        },
      }.to_json
      File.write(SPEC_GALAXY_DIR / "config.json", shared_config)

      config = GalaxyTimeline::SharedBackupConfig.load

      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(7)
      config.backups.path.should eq("/custom/path")
    end

    it "returns defaults when config file does not exist" do
      File.delete(SPEC_GALAXY_DIR / "config.json") if File.exists?(SPEC_GALAXY_DIR / "config.json")

      config = GalaxyTimeline::SharedBackupConfig.load

      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")
    end

    it "returns defaults when config file contains malformed JSON" do
      File.write(SPEC_GALAXY_DIR / "config.json", "not valid json {{{")

      config = GalaxyTimeline::SharedBackupConfig.load

      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")
    end

    it "returns defaults for missing backups section" do
      shared_config = {
        "_schema_version" => "0.0.1",
      }.to_json
      File.write(SPEC_GALAXY_DIR / "config.json", shared_config)

      config = GalaxyTimeline::SharedBackupConfig.load

      config.backups.enabled.should be_true
      config.backups.retention_days.should eq(3)
      config.backups.path.should eq("")
    end
  end

  describe "#effective_backup_path" do
    it "returns default path when backup path is empty" do
      config = GalaxyTimeline::SharedBackupConfig.new

      path = config.effective_backup_path
      path.should eq(GalaxyTimeline::GALAXY_DIR / "data" / "backups")
    end

    it "returns custom path when backup path is set" do
      config = GalaxyTimeline::SharedBackupConfig.new
      config.backups.path = "/custom/backup/path"

      config.effective_backup_path.to_s.should eq("/custom/backup/path")
    end
  end
end
