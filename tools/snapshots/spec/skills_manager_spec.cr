require "./spec_helper"

describe GalaxySnapshots::SkillsManager do
  describe ".install" do
    it "installs skills and creates source files" do
      result = GalaxySnapshots::SkillsManager.install
      result.should be_true

      # Verify source file exists
      source_file = GalaxySnapshots::SKILLS_DIR / "galaxy:snapshot" / "SKILL.md"
      File.exists?(source_file).should be_true
      File.read(source_file).should contain("galaxy:snapshot")
    end

    it "creates symlinks in Claude skills directory" do
      GalaxySnapshots::SkillsManager.install

      symlink_path = GalaxySnapshots::CLAUDE_SKILLS_DIR / "galaxy:snapshot"
      File.symlink?(symlink_path).should be_true
    end

    it "is idempotent" do
      GalaxySnapshots::SkillsManager.install
      result = GalaxySnapshots::SkillsManager.install
      result.should be_true

      # Should still work after reinstall
      source_file = GalaxySnapshots::SKILLS_DIR / "galaxy:snapshot" / "SKILL.md"
      File.exists?(source_file).should be_true
    end
  end

  describe ".uninstall" do
    it "removes skills and symlinks" do
      GalaxySnapshots::SkillsManager.install

      result = GalaxySnapshots::SkillsManager.uninstall
      result.should be_true

      # Source directory should be gone
      source_dir = GalaxySnapshots::SKILLS_DIR / "galaxy:snapshot"
      Dir.exists?(source_dir).should be_false

      # Symlink should be gone
      symlink_path = GalaxySnapshots::CLAUDE_SKILLS_DIR / "galaxy:snapshot"
      File.symlink?(symlink_path).should be_false
    end

    it "is safe to call when not installed" do
      result = GalaxySnapshots::SkillsManager.uninstall
      result.should be_true
    end
  end

  describe ".status" do
    it "reports not installed when skills are missing" do
      GalaxySnapshots::SkillsManager.uninstall
      status = GalaxySnapshots::SkillsManager.status
      status.installed.should be_false
    end

    it "reports installed after install" do
      GalaxySnapshots::SkillsManager.install
      status = GalaxySnapshots::SkillsManager.status
      status.installed.should be_true
      status.skills.size.should be > 0
      status.skills[0].name.should eq("galaxy:snapshot")
      status.skills[0].installed.should be_true
    end
  end
end
