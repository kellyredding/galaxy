require "./spec_helper"

describe GalaxyLedger::InstallManager do
  # Tests use SPEC_CLAUDE_CONFIG_DIR and SPEC_GALAXY_DIR via env vars
  # set in spec_helper.cr. All paths resolve under the temp test directory.

  # Clean up artifacts before each test
  before_each do
    # Clean settings.json for hooks
    File.write(GalaxyLedger::SETTINGS_FILE, "{}")

    # Clean skills directories
    skills_dir = GalaxyLedger::SKILLS_DIR
    claude_skills_dir = GalaxyLedger::CLAUDE_SKILLS_DIR
    FileUtils.rm_rf(skills_dir.to_s) if Dir.exists?(skills_dir)
    FileUtils.rm_rf(claude_skills_dir.to_s) if Dir.exists?(claude_skills_dir)
  end

  describe ".install" do
    it "installs both hooks and skills" do
      result = GalaxyLedger::InstallManager.install
      result.success?.should be_true
      result.hooks_ok.should be_true
      result.skills_ok.should be_true
    end

    it "hooks are present in settings.json after install" do
      GalaxyLedger::InstallManager.install

      status = GalaxyLedger::HooksManager.status
      status.installed.should be_true
    end

    it "skills are present on disk after install" do
      GalaxyLedger::InstallManager.install

      status = GalaxyLedger::SkillsManager.status
      status.installed.should be_true
    end
  end

  describe ".uninstall" do
    it "removes both hooks and skills" do
      GalaxyLedger::InstallManager.install

      result = GalaxyLedger::InstallManager.uninstall
      result.success?.should be_true
      result.hooks_ok.should be_true
      result.skills_ok.should be_true
    end

    it "hooks are gone after uninstall" do
      GalaxyLedger::InstallManager.install
      GalaxyLedger::InstallManager.uninstall

      status = GalaxyLedger::HooksManager.status
      status.installed.should be_false
    end

    it "skills are gone after uninstall" do
      GalaxyLedger::InstallManager.install
      GalaxyLedger::InstallManager.uninstall

      status = GalaxyLedger::SkillsManager.status
      status.installed.should be_false
    end
  end

  describe ".status" do
    it "reports not installed when nothing installed" do
      status = GalaxyLedger::InstallManager.status
      status.installed?.should be_false
    end

    it "reports fully installed after install" do
      GalaxyLedger::InstallManager.install

      status = GalaxyLedger::InstallManager.status
      status.installed?.should be_true
      status.hooks.installed.should be_true
      status.skills.installed.should be_true
    end

    it "reports not fully installed when only hooks installed" do
      GalaxyLedger::HooksManager.install

      status = GalaxyLedger::InstallManager.status
      status.installed?.should be_false
      status.hooks.installed.should be_true
      status.skills.installed.should be_false
    end

    it "reports not fully installed when only skills installed" do
      GalaxyLedger::SkillsManager.install

      status = GalaxyLedger::InstallManager.status
      status.installed?.should be_false
      status.hooks.installed.should be_false
      status.skills.installed.should be_true
    end
  end
end
