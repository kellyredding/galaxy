require "../spec_helper"

describe GalaxyLedger::CLI do
  describe ".utc_bar_footnote" do
    describe "daily grouping" do
      it "returns nil when UTC and local dates match" do
        result = GalaxyLedger::CLI.utc_bar_footnote("2026-02-18", "2026-02-18", :daily)
        result.should be_nil
      end

      it "returns annotation when UTC day is ahead of local day" do
        result = GalaxyLedger::CLI.utc_bar_footnote("2026-02-18", "2026-02-17", :daily)
        result.should_not be_nil
        result.not_nil!.should contain("local date is still")
        result.not_nil!.should contain("Feb 17")
      end

      it "returns annotation at month boundary (UTC in March, local still February)" do
        result = GalaxyLedger::CLI.utc_bar_footnote("2026-03-01", "2026-02-28", :daily)
        result.should_not be_nil
        result.not_nil!.should contain("local date is still")
        result.not_nil!.should contain("Feb 28")
      end

      it "returns annotation at year boundary (UTC in January, local still December)" do
        result = GalaxyLedger::CLI.utc_bar_footnote("2027-01-01", "2026-12-31", :daily)
        result.should_not be_nil
        result.not_nil!.should contain("local date is still")
        result.not_nil!.should contain("Dec 31")
      end
    end

    describe "monthly grouping" do
      it "returns nil when UTC and local are in the same month" do
        result = GalaxyLedger::CLI.utc_bar_footnote("2026-02-18", "2026-02-17", :monthly)
        result.should be_nil
      end

      it "returns nil when UTC and local dates match" do
        result = GalaxyLedger::CLI.utc_bar_footnote("2026-02-18", "2026-02-18", :monthly)
        result.should be_nil
      end

      it "returns annotation when UTC month is ahead of local month" do
        result = GalaxyLedger::CLI.utc_bar_footnote("2026-03-01", "2026-02-28", :monthly)
        result.should_not be_nil
        result.not_nil!.should contain("local month is still")
        result.not_nil!.should contain("February")
      end

      it "returns annotation at year boundary (UTC in January, local still December)" do
        result = GalaxyLedger::CLI.utc_bar_footnote("2027-01-01", "2026-12-31", :monthly)
        result.should_not be_nil
        result.not_nil!.should contain("local month is still")
        result.not_nil!.should contain("December")
      end
    end

    describe "unknown grouping" do
      it "returns nil for unrecognized grouping" do
        result = GalaxyLedger::CLI.utc_bar_footnote("2026-02-18", "2026-02-17", :weekly)
        result.should be_nil
      end
    end
  end
end
