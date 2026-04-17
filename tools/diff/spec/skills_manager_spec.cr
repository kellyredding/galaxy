require "./spec_helper"

describe GalaxyDiff::SkillsManager do
  before_each do
    skills_dir = SPEC_GALAXY_DIR / "diff" / "skills"
    FileUtils.rm_rf(skills_dir.to_s) if Dir.exists?(skills_dir)

    claude_skills_dir = SPEC_CLAUDE_CONFIG_DIR / "skills"
    GalaxyDiff::SkillsManager::DIFF_SKILLS.each_key do |name|
      symlink = claude_skills_dir / name
      File.delete(symlink) if File.symlink?(symlink)
    end
  end

  describe ".install" do
    it "creates skill files and symlinks" do
      result = GalaxyDiff::SkillsManager.install
      result.should be_true

      source_file = SPEC_GALAXY_DIR / "diff" / "skills" /
                    "galaxy:diff" / "SKILL.md"
      File.exists?(source_file).should be_true

      symlink = SPEC_CLAUDE_CONFIG_DIR / "skills" /
                "galaxy:diff"
      File.symlink?(symlink).should be_true
    end

    it "is idempotent" do
      GalaxyDiff::SkillsManager.install
      result = GalaxyDiff::SkillsManager.install
      result.should be_true
    end
  end

  describe ".uninstall" do
    it "removes skill files and symlinks" do
      GalaxyDiff::SkillsManager.install
      result = GalaxyDiff::SkillsManager.uninstall
      result.should be_true

      source_dir = SPEC_GALAXY_DIR / "diff" / "skills" /
                   "galaxy:diff"
      Dir.exists?(source_dir).should be_false

      symlink = SPEC_CLAUDE_CONFIG_DIR / "skills" /
                "galaxy:diff"
      File.symlink?(symlink).should be_false
    end
  end

  describe ".status" do
    it "reports not installed when no skills exist" do
      status = GalaxyDiff::SkillsManager.status
      status.installed.should be_false
    end

    it "reports installed after install" do
      GalaxyDiff::SkillsManager.install
      status = GalaxyDiff::SkillsManager.status
      status.installed.should be_true
      status.skills.size.should eq(1)
      status.skills[0].name.should eq("galaxy:diff")
      status.skills[0].installed.should be_true
    end
  end
end
