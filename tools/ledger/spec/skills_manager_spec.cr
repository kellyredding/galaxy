require "./spec_helper"

describe GalaxyLedger::SkillsManager do
  # Tests use SPEC_CLAUDE_CONFIG_DIR and SPEC_GALAXY_DIR via env vars
  # set in spec_helper.cr. All paths resolve under the temp test directory.

  # Clean up skills artifacts before each test for isolation
  before_each do
    skills_dir = GalaxyLedger::SKILLS_DIR
    claude_skills_dir = GalaxyLedger::CLAUDE_SKILLS_DIR

    FileUtils.rm_rf(skills_dir.to_s) if Dir.exists?(skills_dir)
    FileUtils.rm_rf(claude_skills_dir.to_s) if Dir.exists?(claude_skills_dir)
  end

  describe ".install" do
    it "writes SKILL.md to the source directory" do
      result = GalaxyLedger::SkillsManager.install
      result.should be_true

      source_file = GalaxyLedger::SKILLS_DIR / "handoff" / "SKILL.md"
      File.exists?(source_file).should be_true

      content = File.read(source_file)
      content.should contain("disable-model-invocation: true")
      content.should contain("name: handoff")
    end

    it "creates symlink in Claude skills directory" do
      GalaxyLedger::SkillsManager.install

      symlink_path = GalaxyLedger::CLAUDE_SKILLS_DIR / "handoff"
      File.symlink?(symlink_path).should be_true

      target = File.readlink(symlink_path.to_s)
      target.should contain("galaxy")
      target.should contain("skills/handoff")
    end

    it "is idempotent (run twice, same result)" do
      GalaxyLedger::SkillsManager.install
      result = GalaxyLedger::SkillsManager.install
      result.should be_true

      # Source file still exists with correct content
      source_file = GalaxyLedger::SKILLS_DIR / "handoff" / "SKILL.md"
      content = File.read(source_file)
      content.should contain("disable-model-invocation: true")

      # Symlink still valid
      symlink_path = GalaxyLedger::CLAUDE_SKILLS_DIR / "handoff"
      File.symlink?(symlink_path).should be_true
    end

    it "skips if target exists and is not a Galaxy symlink" do
      # Create a non-Galaxy file at the symlink path
      Dir.mkdir_p(GalaxyLedger::CLAUDE_SKILLS_DIR / "handoff")
      File.write(GalaxyLedger::CLAUDE_SKILLS_DIR / "handoff" / "SKILL.md", "user content")

      result = GalaxyLedger::SkillsManager.install
      result.should be_true

      # Source was still written (Galaxy's copy)
      source_file = GalaxyLedger::SKILLS_DIR / "handoff" / "SKILL.md"
      File.exists?(source_file).should be_true

      # But the user's directory was NOT replaced with a symlink
      symlink_path = GalaxyLedger::CLAUDE_SKILLS_DIR / "handoff"
      File.symlink?(symlink_path).should be_false

      # User's content preserved
      user_file = GalaxyLedger::CLAUDE_SKILLS_DIR / "handoff" / "SKILL.md"
      File.read(user_file).should eq("user content")
    end

    it "replaces stale Galaxy symlinks" do
      # Create a symlink pointing to a stale galaxy path
      Dir.mkdir_p(GalaxyLedger::CLAUDE_SKILLS_DIR)
      stale_target = GalaxyLedger::SKILLS_DIR.parent / "old-galaxy" / "skills" / "handoff"
      File.symlink(stale_target.to_s, (GalaxyLedger::CLAUDE_SKILLS_DIR / "handoff").to_s)

      result = GalaxyLedger::SkillsManager.install
      result.should be_true

      # Symlink should now point to the correct location
      symlink_path = GalaxyLedger::CLAUDE_SKILLS_DIR / "handoff"
      target = File.readlink(symlink_path.to_s)
      target.should eq((GalaxyLedger::SKILLS_DIR / "handoff").to_s)
    end
  end

  describe ".uninstall" do
    it "removes symlink and source directory" do
      GalaxyLedger::SkillsManager.install

      result = GalaxyLedger::SkillsManager.uninstall
      result.should be_true

      # Source directory removed
      Dir.exists?(GalaxyLedger::SKILLS_DIR / "handoff").should be_false

      # Symlink removed
      File.symlink?(GalaxyLedger::CLAUDE_SKILLS_DIR / "handoff").should be_false
    end

    it "is idempotent (run on already-uninstalled, no error)" do
      result = GalaxyLedger::SkillsManager.uninstall
      result.should be_true
    end

    it "does not remove non-Galaxy symlinks" do
      # Create a non-Galaxy symlink
      Dir.mkdir_p(GalaxyLedger::CLAUDE_SKILLS_DIR)
      Dir.mkdir_p("/tmp/other-handoff-skill")
      File.symlink("/tmp/other-handoff-skill", (GalaxyLedger::CLAUDE_SKILLS_DIR / "handoff").to_s)

      GalaxyLedger::SkillsManager.uninstall

      # Non-Galaxy symlink should still exist
      File.symlink?(GalaxyLedger::CLAUDE_SKILLS_DIR / "handoff").should be_true

      # Clean up
      File.delete(GalaxyLedger::CLAUDE_SKILLS_DIR / "handoff")
      FileUtils.rm_rf("/tmp/other-handoff-skill")
    end
  end

  describe ".status" do
    it "reports not installed when nothing installed" do
      status = GalaxyLedger::SkillsManager.status
      status.installed.should be_false
      status.skills.size.should eq(3)
      status.skills.map(&.name).should contain("handoff")
      status.skills.map(&.name).should contain("spend")
      status.skills.map(&.name).should contain("galaxy:resume")
      status.skills.all?(&.installed).should be_false
    end

    it "reports installed after install" do
      GalaxyLedger::SkillsManager.install

      status = GalaxyLedger::SkillsManager.status
      status.installed.should be_true
      status.skills.first.installed.should be_true
    end

    it "reports not installed when source exists but symlink missing" do
      # Write source only (no symlink)
      source_dir = GalaxyLedger::SKILLS_DIR / "handoff"
      Dir.mkdir_p(source_dir)
      File.write(source_dir / "SKILL.md", "content")

      status = GalaxyLedger::SkillsManager.status
      status.installed.should be_false
      status.skills.first.installed.should be_false
    end

    it "reports not installed when symlink exists but source missing" do
      # Create symlink only (no source)
      Dir.mkdir_p(GalaxyLedger::CLAUDE_SKILLS_DIR)
      source_dir = GalaxyLedger::SKILLS_DIR / "handoff"
      Dir.mkdir_p(source_dir)
      File.symlink(source_dir.to_s, (GalaxyLedger::CLAUDE_SKILLS_DIR / "handoff").to_s)
      # Now remove the source file (but leave dir so symlink target technically exists)
      FileUtils.rm_rf(source_dir.to_s)

      status = GalaxyLedger::SkillsManager.status
      status.installed.should be_false
    end

    it "returns correct paths" do
      status = GalaxyLedger::SkillsManager.status
      skill = status.skills.first

      skill.source_path.should eq(GalaxyLedger::SKILLS_DIR / "handoff")
      skill.symlink_path.should eq(GalaxyLedger::CLAUDE_SKILLS_DIR / "handoff")
    end
  end

  describe "spend skill" do
    it "requires mandatory verbatim CLI output in a code block" do
      content = GalaxyLedger::SkillsManager::SPEND_SKILL
      content.should contain("MANDATORY")
      content.should contain("code block")
      content.should contain("Do NOT summarize")
    end
  end

  describe "galaxy:resume skill" do
    it "writes SKILL.md to the source directory" do
      GalaxyLedger::SkillsManager.install

      source_file = GalaxyLedger::SKILLS_DIR / "galaxy:resume" / "SKILL.md"
      File.exists?(source_file).should be_true

      content = File.read(source_file)
      content.should contain("name: galaxy:resume")
      content.should contain("disable-model-invocation: true")
    end

    it "creates symlink in Claude skills directory" do
      GalaxyLedger::SkillsManager.install

      symlink_path = GalaxyLedger::CLAUDE_SKILLS_DIR / "galaxy:resume"
      File.symlink?(symlink_path).should be_true

      target = File.readlink(symlink_path.to_s)
      target.should contain("galaxy")
      target.should contain("skills/galaxy:resume")
    end

    it "includes CWD restore as Step 1" do
      content = GalaxyLedger::SkillsManager::RESUME_SKILL
      content.should contain("Step 1")
      content.should contain("Restore Working Directory")
      content.should contain("`cd`")
      content.should contain("Working directory")
    end

    it "includes brief check-in as Step 2" do
      content = GalaxyLedger::SkillsManager::RESUME_SKILL
      content.should contain("Step 2")
      content.should contain("Brief Check-In")
      content.should contain("Do NOT re-read guideline files")
    end

    it "is lighter than full handoff" do
      content = GalaxyLedger::SkillsManager::RESUME_SKILL
      content.should contain("lighter than")
      content.should contain("conversation history is intact")
    end
  end

  describe "removed skills" do
    it "does not include ledger:snapshot in LEDGER_SKILLS" do
      GalaxyLedger::SkillsManager::LEDGER_SKILLS.has_key?("ledger:snapshot").should be_false
    end

    it "does not include ledger:prune in LEDGER_SKILLS" do
      GalaxyLedger::SkillsManager::LEDGER_SKILLS.has_key?("ledger:prune").should be_false
    end

    it "does not include ledger:name in LEDGER_SKILLS" do
      GalaxyLedger::SkillsManager::LEDGER_SKILLS.has_key?("ledger:name").should be_false
    end

    it "does not include ledger:artifact in LEDGER_SKILLS" do
      GalaxyLedger::SkillsManager::LEDGER_SKILLS.has_key?("ledger:artifact").should be_false
    end

    it "does not include galaxy:artifact in LEDGER_SKILLS (moved to galaxy-artifacts tool)" do
      GalaxyLedger::SkillsManager::LEDGER_SKILLS.has_key?("galaxy:artifact").should be_false
    end
  end

  describe "old skill cleanup" do
    it "cleans up old skill symlinks on install" do
      # Seed an old skill directory and symlink
      old_source = GalaxyLedger::SKILLS_DIR / "ledger:artifact"
      Dir.mkdir_p(old_source)
      File.write(old_source / "SKILL.md", "old content")
      Dir.mkdir_p(GalaxyLedger::CLAUDE_SKILLS_DIR)
      old_symlink = GalaxyLedger::CLAUDE_SKILLS_DIR / "ledger:artifact"
      File.symlink(old_source.to_s, old_symlink.to_s)

      GalaxyLedger::SkillsManager.install

      # Old name cleaned up
      File.symlink?(old_symlink).should be_false
      Dir.exists?(old_source).should be_false

      # galaxy:artifact now also cleaned up (moved to galaxy-artifacts tool)
      Dir.exists?(GalaxyLedger::SKILLS_DIR / "galaxy:artifact").should be_false
      File.symlink?(GalaxyLedger::CLAUDE_SKILLS_DIR / "galaxy:artifact").should be_false
    end

    it "cleans up old ledger:snapshot on install" do
      old_source = GalaxyLedger::SKILLS_DIR / "ledger:snapshot"
      Dir.mkdir_p(old_source)
      File.write(old_source / "SKILL.md", "old snapshot skill")
      Dir.mkdir_p(GalaxyLedger::CLAUDE_SKILLS_DIR)
      old_symlink = GalaxyLedger::CLAUDE_SKILLS_DIR / "ledger:snapshot"
      File.symlink(old_source.to_s, old_symlink.to_s)

      GalaxyLedger::SkillsManager.install

      File.symlink?(old_symlink).should be_false
      Dir.exists?(old_source).should be_false
    end

    it "cleans up old ledger:prune on install" do
      old_source = GalaxyLedger::SKILLS_DIR / "ledger:prune"
      Dir.mkdir_p(old_source)
      File.write(old_source / "SKILL.md", "old prune skill")
      Dir.mkdir_p(GalaxyLedger::CLAUDE_SKILLS_DIR)
      old_symlink = GalaxyLedger::CLAUDE_SKILLS_DIR / "ledger:prune"
      File.symlink(old_source.to_s, old_symlink.to_s)

      GalaxyLedger::SkillsManager.install

      File.symlink?(old_symlink).should be_false
      Dir.exists?(old_source).should be_false
    end

    it "cleans up old ledger:name on install" do
      old_source = GalaxyLedger::SKILLS_DIR / "ledger:name"
      Dir.mkdir_p(old_source)
      File.write(old_source / "SKILL.md", "old name skill")
      Dir.mkdir_p(GalaxyLedger::CLAUDE_SKILLS_DIR)
      old_symlink = GalaxyLedger::CLAUDE_SKILLS_DIR / "ledger:name"
      File.symlink(old_source.to_s, old_symlink.to_s)

      GalaxyLedger::SkillsManager.install

      File.symlink?(old_symlink).should be_false
      Dir.exists?(old_source).should be_false
    end

    it "cleans up old skills on uninstall" do
      old_source = GalaxyLedger::SKILLS_DIR / "ledger:snapshot"
      Dir.mkdir_p(old_source)
      File.write(old_source / "SKILL.md", "old snapshot skill")
      Dir.mkdir_p(GalaxyLedger::CLAUDE_SKILLS_DIR)
      old_symlink = GalaxyLedger::CLAUDE_SKILLS_DIR / "ledger:snapshot"
      File.symlink(old_source.to_s, old_symlink.to_s)

      GalaxyLedger::SkillsManager.uninstall

      File.symlink?(old_symlink).should be_false
      Dir.exists?(old_source).should be_false
    end
  end
end
