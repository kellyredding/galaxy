require "json"

module GalaxyLedger
  # Manages installation and removal of ledger hooks in Claude Code settings.json
  module HooksManager
    # Hook definitions that will be installed
    # Note: PreCompact and SessionEnd were removed in Phase 6.1 (direct DB writes)
    LEDGER_HOOKS = {
      "UserPromptSubmit" => [
        {
          "hooks" => [
            {
              "type"    => "command",
              "command" => "~/.claude/galaxy/bin/galaxy-ledger on-user-prompt-submit",
              "async"   => true,
              "timeout" => 10,
            },
          ],
        },
      ],
      "PostToolUse" => [
        {
          "matcher" => "Edit|Write|Read|Grep|Glob",
          "hooks"   => [
            {
              "type"    => "command",
              "command" => "~/.claude/galaxy/bin/galaxy-ledger on-post-tool-use",
              "async"   => true,
              "timeout" => 10,
            },
          ],
        },
      ],
      "Stop" => [
        {
          "hooks" => [
            {
              "type"    => "command",
              "command" => "~/.claude/galaxy/bin/galaxy-ledger on-stop",
              "timeout" => 30,
            },
          ],
        },
      ],
      "SessionStart" => [
        {
          "matcher" => "clear|compact",
          "hooks"   => [
            {
              "type"    => "command",
              "command" => "~/.claude/galaxy/bin/galaxy-ledger on-session-start",
              "timeout" => 30,
            },
          ],
        },
        {
          "matcher" => "startup",
          "hooks"   => [
            {
              "type"    => "command",
              "command" => "~/.claude/galaxy/bin/galaxy-ledger on-startup",
              "timeout" => 10,
            },
          ],
        },
      ],
    }

    # Marker to identify ledger-managed hooks
    LEDGER_MARKER = "galaxy-ledger"

    struct HookStatus
      getter installed : Bool
      getter hook_events : Array(String)
      getter settings_path : Path

      def initialize(@installed : Bool, @hook_events : Array(String), @settings_path : Path)
      end
    end

    # Install ledger hooks into settings.json
    def self.install : Bool
      settings = load_settings
      hooks = settings["hooks"]?.try(&.as_h?) || {} of String => JSON::Any

      LEDGER_HOOKS.each do |event_name, event_hooks|
        existing = hooks[event_name]?.try(&.as_a?) || [] of JSON::Any

        # Remove any existing ledger hooks first to avoid duplicates
        filtered = existing.reject do |hook|
          is_ledger_hook?(hook)
        end

        # Add our hooks
        event_hooks.each do |new_hook|
          filtered << JSON.parse(new_hook.to_json)
        end

        hooks[event_name] = JSON.parse(filtered.to_json)
      end

      settings_hash = settings.as_h
      settings_hash["hooks"] = JSON.parse(hooks.to_json)

      save_settings(JSON.parse(settings_hash.to_json))
      true
    rescue ex
      STDERR.puts "Error installing hooks: #{ex.message}"
      false
    end

    # Uninstall ledger hooks from settings.json
    def self.uninstall : Bool
      settings = load_settings
      hooks = settings["hooks"]?.try(&.as_h?) || {} of String => JSON::Any

      return true if hooks.empty?

      modified_hooks = {} of String => JSON::Any

      hooks.each do |event_name, event_hooks_json|
        event_hooks = event_hooks_json.as_a? || [] of JSON::Any

        # Remove ledger hooks
        filtered = event_hooks.reject do |hook|
          is_ledger_hook?(hook)
        end

        # Only include if there are remaining hooks
        unless filtered.empty?
          modified_hooks[event_name] = JSON.parse(filtered.to_json)
        end
      end

      settings_hash = settings.as_h
      if modified_hooks.empty?
        settings_hash.delete("hooks")
      else
        settings_hash["hooks"] = JSON.parse(modified_hooks.to_json)
      end

      save_settings(JSON.parse(settings_hash.to_json))
      true
    rescue ex
      STDERR.puts "Error uninstalling hooks: #{ex.message}"
      false
    end

    # Check which hooks are installed
    def self.status : HookStatus
      settings = load_settings
      hooks = settings["hooks"]?.try(&.as_h?) || {} of String => JSON::Any

      installed_events = [] of String

      LEDGER_HOOKS.keys.each do |event_name|
        event_hooks = hooks[event_name]?.try(&.as_a?) || [] of JSON::Any
        if event_hooks.any? { |hook| is_ledger_hook?(hook) }
          installed_events << event_name
        end
      end

      HookStatus.new(
        installed: installed_events.size == LEDGER_HOOKS.keys.size,
        hook_events: installed_events,
        settings_path: SETTINGS_FILE
      )
    end

    # Check if a hook is a ledger hook (by checking command path)
    private def self.is_ledger_hook?(hook : JSON::Any) : Bool
      hooks_array = hook["hooks"]?.try(&.as_a?)
      return false unless hooks_array

      hooks_array.any? do |h|
        command = h["command"]?.try(&.as_s?)
        command && command.includes?(LEDGER_MARKER)
      end
    end

    private def self.load_settings : JSON::Any
      if File.exists?(SETTINGS_FILE)
        JSON.parse(File.read(SETTINGS_FILE))
      else
        JSON.parse("{}")
      end
    end

    private def self.save_settings(settings : JSON::Any)
      # Ensure parent directory exists
      Dir.mkdir_p(SETTINGS_FILE.parent)

      # Write with pretty formatting
      File.write(SETTINGS_FILE, settings.to_pretty_json + "\n")
    end
  end
end
