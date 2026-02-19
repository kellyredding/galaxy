require "../spec_helper"

describe GalaxyLedger::CLI do
  describe ".parse_prune_duration" do
    it "parses 1w to 7 days" do
      GalaxyLedger::CLI.parse_prune_duration("1w").should eq(7)
    end

    it "parses 2w to 14 days" do
      GalaxyLedger::CLI.parse_prune_duration("2w").should eq(14)
    end

    it "parses 1m to 30 days" do
      GalaxyLedger::CLI.parse_prune_duration("1m").should eq(30)
    end

    it "parses 2m to 60 days" do
      GalaxyLedger::CLI.parse_prune_duration("2m").should eq(60)
    end

    it "parses 3m to 90 days" do
      GalaxyLedger::CLI.parse_prune_duration("3m").should eq(90)
    end

    it "parses 6m to 180 days" do
      GalaxyLedger::CLI.parse_prune_duration("6m").should eq(180)
    end

    it "parses 1y to 365 days" do
      GalaxyLedger::CLI.parse_prune_duration("1y").should eq(365)
    end

    it "parses 2y to 730 days" do
      GalaxyLedger::CLI.parse_prune_duration("2y").should eq(730)
    end

    it "parses 5y to 1825 days" do
      GalaxyLedger::CLI.parse_prune_duration("5y").should eq(1825)
    end

    it "returns nil for invalid duration" do
      GalaxyLedger::CLI.parse_prune_duration("invalid").should be_nil
    end

    it "returns nil for empty string" do
      GalaxyLedger::CLI.parse_prune_duration("").should be_nil
    end

    it "returns nil for numeric-only input" do
      GalaxyLedger::CLI.parse_prune_duration("30").should be_nil
    end

    it "returns nil for unsupported duration" do
      GalaxyLedger::CLI.parse_prune_duration("4m").should be_nil
    end
  end
end
