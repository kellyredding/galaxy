require "./spec_helper"

describe GalaxyStatusline::TimeFormat do
  describe ".format" do
    it "reproduces the historical default for a morning time" do
      time = Time.local(2026, 5, 1, 6, 41, 0)
      GalaxyStatusline::TimeFormat.format(time, "%-I:%M %^p").should eq("6:41 AM")
    end

    it "reproduces the historical default for noon" do
      time = Time.local(2026, 5, 1, 12, 41, 0)
      GalaxyStatusline::TimeFormat.format(time, "%-I:%M %^p").should eq("12:41 PM")
    end

    it "reproduces the historical default for an afternoon time" do
      time = Time.local(2026, 5, 1, 18, 5, 0)
      GalaxyStatusline::TimeFormat.format(time, "%-I:%M %^p").should eq("6:05 PM")
    end

    it "reproduces the historical default for midnight" do
      time = Time.local(2026, 5, 1, 0, 0, 0)
      GalaxyStatusline::TimeFormat.format(time, "%-I:%M %^p").should eq("12:00 AM")
    end

    it "supports 24-hour format" do
      time = Time.local(2026, 5, 1, 18, 5, 0)
      GalaxyStatusline::TimeFormat.format(time, "%H:%M").should eq("18:05")
    end

    it "supports 24-hour format with seconds" do
      time = Time.local(2026, 5, 1, 18, 5, 7)
      GalaxyStatusline::TimeFormat.format(time, "%H:%M:%S").should eq("18:05:07")
    end

    it "expands %-I as unpadded 12-hour" do
      time = Time.local(2026, 5, 1, 9, 0, 0)
      GalaxyStatusline::TimeFormat.format(time, "%-I").should eq("9")
    end

    it "expands %-l as unpadded 12-hour (BSD alias)" do
      time = Time.local(2026, 5, 1, 9, 0, 0)
      GalaxyStatusline::TimeFormat.format(time, "%-l").should eq("9")
    end

    it "expands %-H as unpadded 24-hour" do
      time = Time.local(2026, 5, 1, 9, 0, 0)
      GalaxyStatusline::TimeFormat.format(time, "%-H").should eq("9")
    end

    it "expands %P as uppercase meridiem" do
      morning = Time.local(2026, 5, 1, 6, 0, 0)
      evening = Time.local(2026, 5, 1, 18, 0, 0)
      GalaxyStatusline::TimeFormat.format(morning, "%P").should eq("AM")
      GalaxyStatusline::TimeFormat.format(evening, "%P").should eq("PM")
    end

    it "leaves %p lowercase (Crystal default)" do
      time = Time.local(2026, 5, 1, 6, 0, 0)
      GalaxyStatusline::TimeFormat.format(time, "%p").should eq("am")
    end

    it "passes through unsupported directives literally" do
      time = Time.local(2026, 5, 1, 6, 0, 0)
      result = GalaxyStatusline::TimeFormat.format(time, "%H:%M no directives here")
      result.should eq("06:00 no directives here")
    end
  end
end
