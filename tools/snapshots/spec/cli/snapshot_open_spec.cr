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

    it "returns config editor when set" do
      config = GalaxySnapshots::Config.load
      config.editor = "subl"
      config.save

      result = GalaxySnapshots::CLI.resolve_editor
      result.should eq("subl")

      # Reset config
      config.editor = ""
      config.save
    end

    it "falls back to VISUAL when config editor is empty" do
      # Ensure config editor is empty
      config = GalaxySnapshots::Config.load
      config.editor = ""
      config.save

      ENV["VISUAL"] = "code"
      result = GalaxySnapshots::CLI.resolve_editor
      result.should eq("code")
    end

    it "falls back to EDITOR when config and VISUAL are empty" do
      config = GalaxySnapshots::Config.load
      config.editor = ""
      config.save

      ENV["EDITOR"] = "vim"
      result = GalaxySnapshots::CLI.resolve_editor
      result.should eq("vim")
    end

    it "prefers VISUAL over EDITOR" do
      config = GalaxySnapshots::Config.load
      config.editor = ""
      config.save

      ENV["VISUAL"] = "code"
      ENV["EDITOR"] = "vim"
      result = GalaxySnapshots::CLI.resolve_editor
      result.should eq("code")
    end

    it "prefers config over VISUAL and EDITOR" do
      config = GalaxySnapshots::Config.load
      config.editor = "cursor"
      config.save

      ENV["VISUAL"] = "code"
      ENV["EDITOR"] = "vim"
      result = GalaxySnapshots::CLI.resolve_editor
      result.should eq("cursor")

      # Reset config
      config.editor = ""
      config.save
    end

    it "falls back to 'open' when nothing is set" do
      config = GalaxySnapshots::Config.load
      config.editor = ""
      config.save

      result = GalaxySnapshots::CLI.resolve_editor
      result.should eq("open")
    end

    it "skips empty VISUAL and falls to EDITOR" do
      config = GalaxySnapshots::Config.load
      config.editor = ""
      config.save

      ENV["VISUAL"] = ""
      ENV["EDITOR"] = "nano"
      result = GalaxySnapshots::CLI.resolve_editor
      result.should eq("nano")
    end
  end
end
