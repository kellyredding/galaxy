require "./spec_helper"

describe GalaxyLedger::HooksManager do
  describe ".install" do
    it "creates hooks section in empty settings.json" do
      # Settings file should be in the test directory
      File.write(GalaxyLedger::SETTINGS_FILE, "{}")

      result = GalaxyLedger::HooksManager.install
      result.should be_true

      # Verify hooks were added
      settings = JSON.parse(File.read(GalaxyLedger::SETTINGS_FILE))
      hooks = settings["hooks"]?.should_not be_nil
      hooks = settings["hooks"].as_h

      hooks.has_key?("UserPromptSubmit").should be_true
      hooks.has_key?("PostToolUse").should be_true
      hooks.has_key?("Stop").should be_true
      hooks.has_key?("PreCompact").should be_true
      hooks.has_key?("SessionStart").should be_true
      hooks.has_key?("SessionEnd").should be_true
    end

    it "preserves existing non-ledger hooks" do
      existing_settings = {
        "hooks" => {
          "Stop" => [
            {
              "hooks" => [
                {
                  "type"    => "command",
                  "command" => "my-custom-hook",
                  "timeout" => 10,
                },
              ],
            },
          ],
        },
      }
      File.write(GalaxyLedger::SETTINGS_FILE, existing_settings.to_json)

      result = GalaxyLedger::HooksManager.install
      result.should be_true

      settings = JSON.parse(File.read(GalaxyLedger::SETTINGS_FILE))
      stop_hooks = settings["hooks"]["Stop"].as_a

      # Should have both custom hook and ledger hook
      stop_hooks.size.should eq(2)

      commands = stop_hooks.map do |hook|
        hook["hooks"].as_a.first["command"].as_s
      end

      commands.should contain("my-custom-hook")
      commands.any?(&.includes?("galaxy-ledger")).should be_true
    end

    it "updates existing ledger hooks (no duplicates)" do
      # Install once
      File.write(GalaxyLedger::SETTINGS_FILE, "{}")
      GalaxyLedger::HooksManager.install

      # Install again
      result = GalaxyLedger::HooksManager.install
      result.should be_true

      settings = JSON.parse(File.read(GalaxyLedger::SETTINGS_FILE))
      stop_hooks = settings["hooks"]["Stop"].as_a

      # Should only have one ledger hook, not two
      ledger_hooks = stop_hooks.select do |hook|
        hook["hooks"].as_a.any? do |h|
          h["command"]?.try(&.as_s?).try(&.includes?("galaxy-ledger")) || false
        end
      end

      ledger_hooks.size.should eq(1)
    end

    it "preserves other settings" do
      existing_settings = {
        "model"       => "claude-sonnet",
        "permissions" => {"allow" => ["Read"]},
      }
      File.write(GalaxyLedger::SETTINGS_FILE, existing_settings.to_json)

      GalaxyLedger::HooksManager.install

      settings = JSON.parse(File.read(GalaxyLedger::SETTINGS_FILE))
      settings["model"].as_s.should eq("claude-sonnet")
      settings["permissions"]["allow"].as_a.first.as_s.should eq("Read")
    end

    it "creates settings file if it doesn't exist" do
      File.delete(GalaxyLedger::SETTINGS_FILE) if File.exists?(GalaxyLedger::SETTINGS_FILE)

      result = GalaxyLedger::HooksManager.install
      result.should be_true

      File.exists?(GalaxyLedger::SETTINGS_FILE).should be_true
    end
  end

  describe ".uninstall" do
    it "removes ledger hooks" do
      File.write(GalaxyLedger::SETTINGS_FILE, "{}")
      GalaxyLedger::HooksManager.install

      # Verify hooks exist
      status = GalaxyLedger::HooksManager.status
      status.installed.should be_true

      # Uninstall
      result = GalaxyLedger::HooksManager.uninstall
      result.should be_true

      # Verify hooks are gone
      status = GalaxyLedger::HooksManager.status
      status.installed.should be_false
      status.hook_events.should be_empty
    end

    it "preserves non-ledger hooks" do
      existing_settings = {
        "hooks" => {
          "Stop" => [
            {
              "hooks" => [
                {"type" => "command", "command" => "my-custom-hook"},
              ],
            },
          ],
        },
      }
      File.write(GalaxyLedger::SETTINGS_FILE, existing_settings.to_json)

      # Install ledger hooks
      GalaxyLedger::HooksManager.install

      # Uninstall
      GalaxyLedger::HooksManager.uninstall

      settings = JSON.parse(File.read(GalaxyLedger::SETTINGS_FILE))
      stop_hooks = settings["hooks"]["Stop"].as_a

      # Custom hook should remain
      stop_hooks.size.should eq(1)
      stop_hooks.first["hooks"].as_a.first["command"].as_s.should eq("my-custom-hook")
    end

    it "removes empty hooks section" do
      File.write(GalaxyLedger::SETTINGS_FILE, "{}")
      GalaxyLedger::HooksManager.install
      GalaxyLedger::HooksManager.uninstall

      settings = JSON.parse(File.read(GalaxyLedger::SETTINGS_FILE))
      settings["hooks"]?.should be_nil
    end

    it "handles missing settings file" do
      File.delete(GalaxyLedger::SETTINGS_FILE) if File.exists?(GalaxyLedger::SETTINGS_FILE)

      result = GalaxyLedger::HooksManager.uninstall
      result.should be_true
    end

    it "handles empty settings file" do
      File.write(GalaxyLedger::SETTINGS_FILE, "{}")

      result = GalaxyLedger::HooksManager.uninstall
      result.should be_true
    end
  end

  describe ".status" do
    it "reports not installed when settings is empty" do
      File.write(GalaxyLedger::SETTINGS_FILE, "{}")

      status = GalaxyLedger::HooksManager.status
      status.installed.should be_false
      status.hook_events.should be_empty
    end

    it "reports fully installed after install" do
      File.write(GalaxyLedger::SETTINGS_FILE, "{}")
      GalaxyLedger::HooksManager.install

      status = GalaxyLedger::HooksManager.status
      status.installed.should be_true
      status.hook_events.size.should eq(GalaxyLedger::HooksManager::LEDGER_HOOKS.keys.size)
    end

    it "reports partial installation" do
      # Install just one hook manually
      partial_settings = {
        "hooks" => {
          "Stop" => [
            {
              "hooks" => [
                {"type" => "command", "command" => "~/.claude/galaxy/bin/galaxy-ledger on-stop"},
              ],
            },
          ],
        },
      }
      File.write(GalaxyLedger::SETTINGS_FILE, partial_settings.to_json)

      status = GalaxyLedger::HooksManager.status
      status.installed.should be_false
      status.hook_events.should eq(["Stop"])
    end

    it "returns correct settings path" do
      File.write(GalaxyLedger::SETTINGS_FILE, "{}")

      status = GalaxyLedger::HooksManager.status
      status.settings_path.should eq(GalaxyLedger::SETTINGS_FILE)
    end
  end
end

describe "CLI hooks commands" do
  describe "hooks status" do
    it "shows not installed status" do
      File.write(GalaxyLedger::SETTINGS_FILE, "{}")

      result = run_binary(["hooks", "status"])
      result[:status].should eq(0)
      result[:output].should contain("No hooks installed")
    end

    it "shows installed status after install" do
      File.write(GalaxyLedger::SETTINGS_FILE, "{}")
      GalaxyLedger::HooksManager.install

      result = run_binary(["hooks", "status"])
      result[:status].should eq(0)
      result[:output].should contain("All hooks installed")
    end
  end

  describe "hooks install" do
    it "installs hooks successfully" do
      File.write(GalaxyLedger::SETTINGS_FILE, "{}")

      result = run_binary(["hooks", "install"])
      result[:status].should eq(0)
      result[:output].should contain("Hooks installed successfully")
    end
  end

  describe "hooks uninstall" do
    it "uninstalls hooks successfully" do
      File.write(GalaxyLedger::SETTINGS_FILE, "{}")
      GalaxyLedger::HooksManager.install

      result = run_binary(["hooks", "uninstall"])
      result[:status].should eq(0)
      result[:output].should contain("Hooks uninstalled successfully")
    end
  end

  describe "hooks help" do
    it "shows help with -h flag" do
      result = run_binary(["hooks", "-h"])
      result[:status].should eq(0)
      result[:output].should contain("USAGE")
      result[:output].should contain("install")
      result[:output].should contain("uninstall")
      result[:output].should contain("status")
    end

    it "shows install help" do
      result = run_binary(["hooks", "install", "-h"])
      result[:status].should eq(0)
      result[:output].should contain("Install ledger hooks")
    end

    it "shows uninstall help" do
      result = run_binary(["hooks", "uninstall", "-h"])
      result[:status].should eq(0)
      result[:output].should contain("Remove ledger hooks")
    end

    it "shows status help" do
      result = run_binary(["hooks", "status", "-h"])
      result[:status].should eq(0)
      result[:output].should contain("Check hook installation status")
    end
  end
end
