require "./spec_helper"

describe GalaxyFiles::SkillsManager do
  before_each do
    skills_dir = SPEC_GALAXY_DIR / "files" / "skills"
    FileUtils.rm_rf(skills_dir.to_s) if Dir.exists?(skills_dir)

    symlink = SPEC_CLAUDE_CONFIG_DIR / "skills" / "galaxy:files"
    File.delete(symlink) if File.symlink?(symlink)
  end

  describe ".install" do
    it "writes the skill and links it where Claude Code finds skills" do
      GalaxyFiles::SkillsManager.install.should be_true

      source_file = SPEC_GALAXY_DIR / "files" / "skills" / "galaxy:files" / "SKILL.md"
      File.read(source_file).should contain("name: galaxy:files")
      File.symlink?(SPEC_CLAUDE_CONFIG_DIR / "skills" / "galaxy:files").should be_true
    end

    it "is idempotent" do
      GalaxyFiles::SkillsManager.install
      GalaxyFiles::SkillsManager.install.should be_true
    end
  end

  describe ".uninstall" do
    it "removes the skill and its link" do
      GalaxyFiles::SkillsManager.install
      GalaxyFiles::SkillsManager.uninstall.should be_true

      Dir.exists?(SPEC_GALAXY_DIR / "files" / "skills" / "galaxy:files").should be_false
      File.symlink?(SPEC_CLAUDE_CONFIG_DIR / "skills" / "galaxy:files").should be_false
    end
  end

  describe ".status" do
    it "reports the skill installed after install" do
      GalaxyFiles::SkillsManager.status.installed.should be_false

      GalaxyFiles::SkillsManager.install
      status = GalaxyFiles::SkillsManager.status
      status.installed.should be_true
      status.skills.map(&.name).should eq(["galaxy:files"])
    end
  end
end
