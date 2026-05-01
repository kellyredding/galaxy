require "json"

module GalaxyStatusline
  # Manages the `statusLine` hook block in Claude Code's
  # settings.json. Mirrors GalaxyLedger::HooksManager but
  # writes a single top-level key instead of a `hooks` map.
  #
  # The Claude Code statusline hook lives at the top level
  # of ~/.claude/settings.json:
  #
  #   {
  #     "statusLine": {
  #       "type": "command",
  #       "command": "~/.claude/galaxy/bin/galaxy-statusline",
  #       "padding": 0
  #     }
  #   }
  #
  # `install` is idempotent. `uninstall` refuses to remove a
  # hook whose command does not contain HOOK_MARKER, so a
  # third-party statusline registered by the user is safe.
  module HookManager
    # Marker substring used to detect a galaxy-managed hook
    # in the `statusLine.command` value.
    HOOK_MARKER = "galaxy-statusline"

    struct HookStatus
      include JSON::Serializable

      getter installed : Bool
      getter command : String?
      getter matches_expected_command : Bool
      getter expected_command : String
      getter settings_path : String

      def initialize(
        @installed : Bool,
        @command : String?,
        @matches_expected_command : Bool,
        @expected_command : String,
        @settings_path : String,
      )
      end
    end

    # Idempotently write the statusLine block.
    def self.install : Bool
      settings = load_settings.as_h

      settings["statusLine"] = JSON.parse({
        "type"    => "command",
        "command" => HOOK_COMMAND,
        "padding" => 0,
      }.to_json)

      save_settings(JSON.parse(settings.to_json))
      true
    rescue ex
      STDERR.puts "Error installing statusline hook: #{ex.message}"
      false
    end

    # Remove the statusLine block. No-op if absent. Refuses to
    # remove a hook whose command does not contain HOOK_MARKER.
    def self.uninstall : Bool
      settings = load_settings.as_h
      current = settings["statusLine"]?

      if current
        cmd = current["command"]?.try(&.as_s?)
        if cmd && !cmd.includes?(HOOK_MARKER)
          STDERR.puts "Refusing to remove non-galaxy statusLine hook: #{cmd}"
          return false
        end
        settings.delete("statusLine")
      end

      save_settings(JSON.parse(settings.to_json))
      true
    rescue ex
      STDERR.puts "Error uninstalling statusline hook: #{ex.message}"
      false
    end

    # Inspect the current settings file and report whether
    # the statusline hook is installed and whether it points
    # at the galaxy-managed command path.
    def self.status : HookStatus
      settings = load_settings
      sl = settings["statusLine"]?

      command = sl.try(&.["command"]?).try(&.as_s?)
      installed = !command.nil?
      matches = command ? command.not_nil!.includes?(HOOK_MARKER) : false

      HookStatus.new(
        installed: installed,
        command: command,
        matches_expected_command: matches,
        expected_command: HOOK_COMMAND,
        settings_path: SETTINGS_FILE.to_s,
      )
    end

    private def self.load_settings : JSON::Any
      if File.exists?(SETTINGS_FILE)
        JSON.parse(File.read(SETTINGS_FILE))
      else
        JSON.parse("{}")
      end
    end

    private def self.save_settings(settings : JSON::Any)
      Dir.mkdir_p(SETTINGS_FILE.parent)
      File.write(SETTINGS_FILE, settings.to_pretty_json + "\n")
    end
  end
end
