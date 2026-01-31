require "../spec_helper"

describe GalaxyStatusline::Colors do
  describe ".colorize" do
    it "applies named colors" do
      result = GalaxyStatusline::Colors.colorize("test", "green")
      result.should eq("\e[32mtest\e[0m")
    end

    it "applies bright colors" do
      result = GalaxyStatusline::Colors.colorize("test", "bright_red")
      result.should eq("\e[91mtest\e[0m")
    end

    it "applies bold modifier" do
      result = GalaxyStatusline::Colors.colorize("test", "bold:green")
      result.should eq("\e[1m\e[32mtest\e[0m")
    end

    it "returns plain text for 'default'" do
      result = GalaxyStatusline::Colors.colorize("test", "default")
      result.should eq("test")
    end

    it "returns plain text for empty color spec" do
      result = GalaxyStatusline::Colors.colorize("test", "")
      result.should eq("test")
    end

    it "returns plain text for unknown color" do
      result = GalaxyStatusline::Colors.colorize("test", "neonpink")
      result.should eq("test")
    end
  end

  describe "ANSI_CODES" do
    it "has all standard colors" do
      GalaxyStatusline::Colors::ANSI_CODES.has_key?("red").should eq(true)
      GalaxyStatusline::Colors::ANSI_CODES.has_key?("green").should eq(true)
      GalaxyStatusline::Colors::ANSI_CODES.has_key?("yellow").should eq(true)
      GalaxyStatusline::Colors::ANSI_CODES.has_key?("blue").should eq(true)
      GalaxyStatusline::Colors::ANSI_CODES.has_key?("magenta").should eq(true)
      GalaxyStatusline::Colors::ANSI_CODES.has_key?("cyan").should eq(true)
      GalaxyStatusline::Colors::ANSI_CODES.has_key?("white").should eq(true)
    end

    it "has bright variants" do
      GalaxyStatusline::Colors::ANSI_CODES.has_key?("bright_red").should eq(true)
      GalaxyStatusline::Colors::ANSI_CODES.has_key?("bright_green").should eq(true)
    end

    it "has default color" do
      GalaxyStatusline::Colors::ANSI_CODES.has_key?("default").should eq(true)
      GalaxyStatusline::Colors::ANSI_CODES["default"].should eq("")
    end
  end

  describe "RESET" do
    it "is the correct ANSI reset code" do
      GalaxyStatusline::Colors::RESET.should eq("\e[0m")
    end
  end
end
