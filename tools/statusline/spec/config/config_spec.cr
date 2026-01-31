require "../spec_helper"

describe GalaxcStatusline::Config do
  describe ".default" do
    it "creates a config with default values" do
      config = GalaxcStatusline::Config.default

      config.version.should eq(GalaxcStatusline::VERSION)
      config.branch_style.should eq("symbolic")
      config.context_thresholds.warning.should eq(60)
      config.context_thresholds.critical.should eq(80)
      config.layout.min_width.should eq(60)
      config.layout.show_cost.should eq(true)
      config.layout.show_model.should eq(true)
      config.layout.directory_style.should eq("smart")
    end

    it "creates config with default colors" do
      config = GalaxcStatusline::Config.default

      config.colors.directory.should eq("bold:yellow")
      config.colors.branch.should eq("green")
      config.colors.dirty.should eq("yellow")
      config.colors.staged.should eq("green")
      config.colors.context_normal.should eq("green")
      config.colors.context_warning.should eq("yellow")
      config.colors.context_critical.should eq("red")
    end
  end

  describe ".load" do
    it "creates default config when file doesn't exist" do
      # Clean up any existing config
      FileUtils.rm_rf(GalaxcStatusline::CONFIG_DIR.to_s)

      config = GalaxcStatusline::Config.load
      config.branch_style.should eq("symbolic")

      # Should have created the file
      File.exists?(GalaxcStatusline::CONFIG_FILE).should eq(true)
    end
  end

  describe "#set and #get" do
    it "sets and gets branch_style" do
      config = GalaxcStatusline::Config.default
      config.set("branch_style", "arrows")
      config.get("branch_style").should eq("arrows")
    end

    it "sets and gets nested color values" do
      config = GalaxcStatusline::Config.default
      config.set("colors.branch", "cyan")
      config.get("colors.branch").should eq("cyan")
    end

    it "sets and gets threshold values" do
      config = GalaxcStatusline::Config.default
      config.set("context_thresholds.warning", "50")
      config.get("context_thresholds.warning").should eq("50")
    end

    it "sets and gets layout values" do
      config = GalaxcStatusline::Config.default
      config.set("layout.show_cost", "false")
      config.get("layout.show_cost").should eq("false")
    end

    it "sets and gets layout directory_style" do
      config = GalaxcStatusline::Config.default
      config.set("layout.directory_style", "basename")
      config.get("layout.directory_style").should eq("basename")
    end

    it "validates branch_style values" do
      config = GalaxcStatusline::Config.default
      expect_raises(Exception, /Invalid branch_style/) do
        config.set("branch_style", "invalid")
      end
    end

    it "validates color values" do
      config = GalaxcStatusline::Config.default
      expect_raises(Exception, /Invalid color/) do
        config.set("colors.branch", "neonpink")
      end
    end

    it "accepts bold: color modifier" do
      config = GalaxcStatusline::Config.default
      config.set("colors.branch", "bold:cyan")
      config.get("colors.branch").should eq("bold:cyan")
    end

    it "validates threshold range" do
      config = GalaxcStatusline::Config.default
      expect_raises(Exception, /between 0 and 100/) do
        config.set("context_thresholds.warning", "150")
      end
    end

    it "raises for unknown keys" do
      config = GalaxcStatusline::Config.default
      expect_raises(Exception, /Unknown setting/) do
        config.set("nonexistent", "value")
      end
    end
  end

  describe "#to_pretty_json" do
    it "produces valid JSON" do
      config = GalaxcStatusline::Config.default
      json = config.to_pretty_json

      # Should be valid JSON that can be parsed back
      parsed = GalaxcStatusline::Config.from_json(json)
      parsed.branch_style.should eq("symbolic")
    end
  end
end
