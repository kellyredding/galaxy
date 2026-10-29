require "../spec_helper"

describe GalaxySnapshots::CLI do
  describe ".snapshot_temp_path" do
    it "returns a deterministic path for a given session and number" do
      path = GalaxySnapshots::CLI.snapshot_temp_path(42_i64, 3)
      path.should eq(File.join(Dir.tempdir, "galaxy-snapshots-snapshot-42-3.md"))
    end

    it "returns different paths for different snapshot numbers" do
      path1 = GalaxySnapshots::CLI.snapshot_temp_path(42_i64, 1)
      path2 = GalaxySnapshots::CLI.snapshot_temp_path(42_i64, 2)
      path1.should_not eq(path2)
    end

    it "returns different paths for different sessions" do
      path1 = GalaxySnapshots::CLI.snapshot_temp_path(1_i64, 1)
      path2 = GalaxySnapshots::CLI.snapshot_temp_path(2_i64, 1)
      path1.should_not eq(path2)
    end

    it "produces a .md extension for editor syntax highlighting" do
      path = GalaxySnapshots::CLI.snapshot_temp_path(1_i64, 1)
      path.should end_with(".md")
    end
  end

  describe ".resolve_editor" do
    # Save and restore env vars around each test
    {% for var in ["VISUAL", "EDITOR"] %}
      before_each do
        if ENV.has_key?({{ var }})
          ENV.delete({{ var }})
        end
      end
    {% end %}

    it "uses VISUAL" do
      ENV["VISUAL"] = "code"
      result = GalaxySnapshots::CLI.resolve_editor
      result.should eq("code")
    end

    it "falls back to EDITOR when VISUAL is unset" do
      ENV["EDITOR"] = "vim"
      result = GalaxySnapshots::CLI.resolve_editor
      result.should eq("vim")
    end

    it "prefers VISUAL over EDITOR" do
      ENV["VISUAL"] = "code"
      ENV["EDITOR"] = "vim"
      result = GalaxySnapshots::CLI.resolve_editor
      result.should eq("code")
    end

    it "falls back to 'open' when nothing is set" do
      result = GalaxySnapshots::CLI.resolve_editor
      result.should eq("open")
    end

    it "skips empty VISUAL and falls to EDITOR" do
      ENV["VISUAL"] = ""
      ENV["EDITOR"] = "nano"
      result = GalaxySnapshots::CLI.resolve_editor
      result.should eq("nano")
    end
  end

  # A config that fails to parse silently loads defaults, so neither an old
  # file that still carries the removed editor key nor one without it may
  # cost the settings beside it.
  describe "loading a config around the removed editor setting" do
    {% for label, editor in {"with" => true, "without" => false} %}
      it "keeps the other settings in a file {{ label.id }} an editor key" do
        settings = {
          "_schema_version" => "0.1.0",
          "inline_char_cap" => 4321,
          "max_per_session" => 7,
        } of String => String | Int32
        settings["editor"] = "subl" if {{ editor }}
        File.write(GalaxySnapshots::CONFIG_FILE, settings.to_json)

        config = GalaxySnapshots::Config.load
        config.inline_char_cap.should eq(4321)
        config.max_per_session.should eq(7)
      ensure
        File.write(GalaxySnapshots::CONFIG_FILE, SPEC_DEFAULT_CONFIG)
      end
    {% end %}
  end
end
