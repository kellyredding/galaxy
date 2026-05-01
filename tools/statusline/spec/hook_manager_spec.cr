require "./spec_helper"

describe GalaxyStatusline::HookManager do
  before_each do
    File.delete(GalaxyStatusline::SETTINGS_FILE) if File.exists?(GalaxyStatusline::SETTINGS_FILE)
  end

  describe ".install" do
    it "creates statusLine block in empty settings.json" do
      File.write(GalaxyStatusline::SETTINGS_FILE, "{}")

      result = GalaxyStatusline::HookManager.install
      result.should be_true

      settings = JSON.parse(File.read(GalaxyStatusline::SETTINGS_FILE))
      sl = settings["statusLine"]
      sl["type"].as_s.should eq("command")
      sl["command"].as_s.should contain("galaxy-statusline")
      sl["padding"].as_i.should eq(0)
    end

    it "preserves other top-level settings" do
      File.write(
        GalaxyStatusline::SETTINGS_FILE,
        {"model" => "claude-sonnet"}.to_json,
      )

      GalaxyStatusline::HookManager.install

      settings = JSON.parse(File.read(GalaxyStatusline::SETTINGS_FILE))
      settings["model"].as_s.should eq("claude-sonnet")
    end

    it "is idempotent" do
      File.write(GalaxyStatusline::SETTINGS_FILE, "{}")
      GalaxyStatusline::HookManager.install
      GalaxyStatusline::HookManager.install

      settings = JSON.parse(File.read(GalaxyStatusline::SETTINGS_FILE))
      settings.as_h.has_key?("statusLine").should be_true
      # Sanity: only one statusLine key (would be impossible to have
      # duplicates in a parsed JSON object, but assert the value type).
      settings["statusLine"].as_h?.should_not be_nil
    end

    it "creates settings file when missing" do
      File.delete(GalaxyStatusline::SETTINGS_FILE) if File.exists?(GalaxyStatusline::SETTINGS_FILE)

      result = GalaxyStatusline::HookManager.install
      result.should be_true
      File.exists?(GalaxyStatusline::SETTINGS_FILE).should be_true
    end

    it "overwrites a third-party statusLine block" do
      # install is the explicit "I want the galaxy hook" action;
      # it overwrites whatever was there. uninstall is the one
      # that refuses to clobber non-galaxy hooks.
      third_party = {
        "statusLine" => {
          "type"    => "command",
          "command" => "/usr/local/bin/some-other-statusline",
          "padding" => 0,
        },
      }
      File.write(GalaxyStatusline::SETTINGS_FILE, third_party.to_json)

      GalaxyStatusline::HookManager.install

      settings = JSON.parse(File.read(GalaxyStatusline::SETTINGS_FILE))
      settings["statusLine"]["command"].as_s.should contain("galaxy-statusline")
    end
  end

  describe ".uninstall" do
    it "removes the statusLine block" do
      File.write(GalaxyStatusline::SETTINGS_FILE, "{}")
      GalaxyStatusline::HookManager.install

      result = GalaxyStatusline::HookManager.uninstall
      result.should be_true

      settings = JSON.parse(File.read(GalaxyStatusline::SETTINGS_FILE))
      settings["statusLine"]?.should be_nil
    end

    it "is a no-op when not installed" do
      File.write(GalaxyStatusline::SETTINGS_FILE, "{}")
      GalaxyStatusline::HookManager.uninstall.should be_true
    end

    it "handles missing settings file" do
      File.delete(GalaxyStatusline::SETTINGS_FILE) if File.exists?(GalaxyStatusline::SETTINGS_FILE)

      GalaxyStatusline::HookManager.uninstall.should be_true
    end

    it "refuses to remove a third-party hook" do
      third_party = {
        "statusLine" => {
          "type"    => "command",
          "command" => "/usr/local/bin/some-other-statusline",
          "padding" => 0,
        },
      }
      File.write(GalaxyStatusline::SETTINGS_FILE, third_party.to_json)

      result = GalaxyStatusline::HookManager.uninstall
      result.should be_false

      settings = JSON.parse(File.read(GalaxyStatusline::SETTINGS_FILE))
      settings["statusLine"]["command"].as_s.should eq(
        "/usr/local/bin/some-other-statusline"
      )
    end

    it "preserves the statusline config file" do
      GalaxyStatusline::Config.default.save
      File.exists?(GalaxyStatusline::CONFIG_FILE).should be_true

      File.write(GalaxyStatusline::SETTINGS_FILE, "{}")
      GalaxyStatusline::HookManager.install
      GalaxyStatusline::HookManager.uninstall

      File.exists?(GalaxyStatusline::CONFIG_FILE).should be_true
    end

    it "preserves other top-level settings" do
      File.write(GalaxyStatusline::SETTINGS_FILE, "{}")
      GalaxyStatusline::HookManager.install

      # Inject another top-level setting alongside the hook
      settings = JSON.parse(File.read(GalaxyStatusline::SETTINGS_FILE)).as_h
      settings["model"] = JSON.parse("\"claude-sonnet\"")
      File.write(GalaxyStatusline::SETTINGS_FILE, settings.to_json)

      GalaxyStatusline::HookManager.uninstall

      settings = JSON.parse(File.read(GalaxyStatusline::SETTINGS_FILE))
      settings["model"].as_s.should eq("claude-sonnet")
      settings["statusLine"]?.should be_nil
    end
  end

  describe ".status" do
    it "reports not installed when settings.json is empty" do
      File.write(GalaxyStatusline::SETTINGS_FILE, "{}")
      status = GalaxyStatusline::HookManager.status
      status.installed.should be_false
      status.command.should be_nil
      status.matches_expected_command.should be_false
    end

    it "reports not installed when settings.json is missing" do
      File.delete(GalaxyStatusline::SETTINGS_FILE) if File.exists?(GalaxyStatusline::SETTINGS_FILE)

      status = GalaxyStatusline::HookManager.status
      status.installed.should be_false
    end

    it "reports installed after install" do
      File.write(GalaxyStatusline::SETTINGS_FILE, "{}")
      GalaxyStatusline::HookManager.install

      status = GalaxyStatusline::HookManager.status
      status.installed.should be_true
      status.matches_expected_command.should be_true
      status.command.not_nil!.should contain("galaxy-statusline")
    end

    it "reports installed but unmatched for third-party command" do
      third_party = {
        "statusLine" => {
          "type"    => "command",
          "command" => "/usr/local/bin/some-other-statusline",
          "padding" => 0,
        },
      }
      File.write(GalaxyStatusline::SETTINGS_FILE, third_party.to_json)

      status = GalaxyStatusline::HookManager.status
      status.installed.should be_true
      status.matches_expected_command.should be_false
    end

    it "reports the configured settings_path and expected_command" do
      File.write(GalaxyStatusline::SETTINGS_FILE, "{}")

      status = GalaxyStatusline::HookManager.status
      status.settings_path.should eq(GalaxyStatusline::SETTINGS_FILE.to_s)
      status.expected_command.should eq(GalaxyStatusline::HOOK_COMMAND)
    end

    it "serializes to JSON for --json output" do
      File.write(GalaxyStatusline::SETTINGS_FILE, "{}")
      GalaxyStatusline::HookManager.install

      json = GalaxyStatusline::HookManager.status.to_pretty_json
      parsed = JSON.parse(json)
      parsed["installed"].as_bool.should be_true
      parsed["matches_expected_command"].as_bool.should be_true
      parsed["expected_command"].as_s.should contain("galaxy-statusline")
      parsed["settings_path"].as_s.should eq(GalaxyStatusline::SETTINGS_FILE.to_s)
    end
  end
end

describe "CLI hook commands" do
  before_each do
    File.delete(GalaxyStatusline::SETTINGS_FILE) if File.exists?(GalaxyStatusline::SETTINGS_FILE)
  end

  describe "hook install" do
    it "installs the hook" do
      result = run_binary(["hook", "install"])
      result[:status].should eq(0)
      result[:output].should contain("installed")
    end

    it "emits JSON with --json" do
      result = run_binary(["hook", "install", "--json"])
      result[:status].should eq(0)
      json = JSON.parse(result[:output])
      json["installed"].as_bool.should be_true
    end
  end

  describe "hook uninstall" do
    it "removes the hook" do
      run_binary(["hook", "install"])
      result = run_binary(["hook", "uninstall"])
      result[:status].should eq(0)
      result[:output].should contain("removed")
    end

    it "exits non-zero when refusing a third-party hook" do
      third_party = {
        "statusLine" => {
          "type"    => "command",
          "command" => "/usr/local/bin/some-other-statusline",
          "padding" => 0,
        },
      }
      File.write(GalaxyStatusline::SETTINGS_FILE, third_party.to_json)

      result = run_binary(["hook", "uninstall"])
      result[:status].should_not eq(0)
      result[:error].should contain("Refusing to remove")
    end
  end

  describe "hook status" do
    it "reports not installed initially" do
      File.write(GalaxyStatusline::SETTINGS_FILE, "{}")

      result = run_binary(["hook", "status"])
      result[:status].should eq(0)
      result[:output].should contain("Not installed")
    end

    it "reports installed after install" do
      run_binary(["hook", "install"])

      result = run_binary(["hook", "status"])
      result[:status].should eq(0)
      result[:output].should contain("Installed")
    end

    it "emits JSON with --json" do
      run_binary(["hook", "install"])

      result = run_binary(["hook", "status", "--json"])
      result[:status].should eq(0)
      json = JSON.parse(result[:output])
      json["installed"].as_bool.should be_true
      json["matches_expected_command"].as_bool.should be_true
    end
  end

  describe "hook help" do
    it "lists the subcommands in the main banner" do
      result = run_binary(["--help"])
      result[:output].should contain("hook install")
      result[:output].should contain("hook uninstall")
      result[:output].should contain("hook status")
    end

    it "shows hook-specific help with the help subcommand" do
      result = run_binary(["hook", "help"])
      result[:status].should eq(0)
      result[:output].should contain("Manage the Claude Code statusline hook")
    end

    it "shows hook-specific help when no subcommand given" do
      result = run_binary(["hook"])
      result[:status].should eq(0)
      result[:output].should contain("Manage the Claude Code statusline hook")
    end

    it "rejects unknown hook subcommands" do
      result = run_binary(["hook", "frobnicate"])
      result[:status].should_not eq(0)
      result[:error].should contain("Unknown hook command")
    end
  end
end
