require "../spec_helper"

describe GalaxyLedger::Chart do
  describe ".sparkline" do
    it "returns empty string for empty values" do
      GalaxyLedger::Chart.sparkline([] of Float64).should eq("")
    end

    it "renders single value as highest block" do
      result = GalaxyLedger::Chart.sparkline([5.0])
      result.should eq("█")
    end

    it "renders all zeros as lowest blocks" do
      result = GalaxyLedger::Chart.sparkline([0.0, 0.0, 0.0])
      result.should eq("▁▁▁")
    end

    it "renders proportional blocks" do
      result = GalaxyLedger::Chart.sparkline([0.0, 50.0, 100.0])
      result.size.should eq(3)
      # First should be lowest, last should be highest
      result[0].should eq('▁')
      result[2].should eq('█')
    end

    it "renders uniform values as all highest" do
      result = GalaxyLedger::Chart.sparkline([10.0, 10.0, 10.0])
      result.should eq("███")
    end
  end

  describe ".bar_chart" do
    it "returns empty string for empty rows" do
      GalaxyLedger::Chart.bar_chart([] of GalaxyLedger::Chart::BarRow).should eq("")
    end

    it "renders a single row" do
      rows = [GalaxyLedger::Chart::BarRow.new(label: "Jan", value: 10.0, extra: "$10.00")]
      result = GalaxyLedger::Chart.bar_chart(rows)
      result.should contain("Jan")
      result.should contain("█")
      result.should contain("$10.00")
    end

    it "marks peak row when multiple rows exist" do
      rows = [
        GalaxyLedger::Chart::BarRow.new(label: "Jan", value: 5.0, extra: "$5.00"),
        GalaxyLedger::Chart::BarRow.new(label: "Feb", value: 10.0, extra: "$10.00"),
        GalaxyLedger::Chart::BarRow.new(label: "Mar", value: 3.0, extra: "$3.00"),
      ]
      result = GalaxyLedger::Chart.bar_chart(rows)
      result.should contain("← peak")
      # Peak should be on the Feb line
      lines = result.split("\n")
      peak_line = lines.find { |l| l.includes?("← peak") }
      peak_line.should_not be_nil
      peak_line.not_nil!.should contain("Feb")
    end

    it "shows dash for zero-value rows" do
      rows = [
        GalaxyLedger::Chart::BarRow.new(label: "Jan", value: 5.0, extra: "$5.00"),
        GalaxyLedger::Chart::BarRow.new(label: "Feb", value: 0.0),
      ]
      result = GalaxyLedger::Chart.bar_chart(rows)
      lines = result.split("\n")
      zero_line = lines.find { |l| l.includes?("Feb") }
      zero_line.should_not be_nil
      zero_line.not_nil!.should contain("—")
    end
  end

  describe ".format_cost" do
    it "formats zero" do
      GalaxyLedger::Chart.format_cost(0.0).should eq("$0.00")
    end

    it "formats small values" do
      GalaxyLedger::Chart.format_cost(0.15).should eq("$0.15")
    end

    it "formats normal values" do
      GalaxyLedger::Chart.format_cost(42.50).should eq("$42.50")
    end

    it "formats large values" do
      GalaxyLedger::Chart.format_cost(1234.56).should eq("$1234.56")
    end
  end

  describe ".format_tokens" do
    it "formats small counts" do
      GalaxyLedger::Chart.format_tokens(500_i64).should eq("500 tok")
    end

    it "formats thousands" do
      GalaxyLedger::Chart.format_tokens(156800_i64).should eq("156.8k tok")
    end

    it "formats millions" do
      GalaxyLedger::Chart.format_tokens(6400000_i64).should eq("6.4M tok")
    end
  end
end
