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

  describe "bar chart column alignment" do
    # Regression tests for right-aligned cost and token columns.
    # The caller (CLI spend command) pre-computes column widths and
    # uses rjust to align decimal points across rows. These tests
    # verify the contract: given aligned extras, bar_chart preserves
    # the alignment in output lines.

    it "aligns cost decimal points across rows with varying magnitudes" do
      # Simulate the CLI's two-pass alignment pattern
      costs = [49.37, 115.43, 184.47, 38.70]
      cost_strs = costs.map { |c| GalaxyLedger::Chart.format_cost(c) }
      max_w = cost_strs.max_of(&.size)
      aligned = cost_strs.map(&.rjust(max_w))

      # All aligned strings should be the same width
      aligned.map(&.size).uniq.size.should eq(1)

      # Decimal points should be at the same position in each string
      dot_positions = aligned.map { |s| s.index('.').not_nil! }
      dot_positions.uniq.size.should eq(1)
    end

    it "aligns token decimal points across rows with varying magnitudes" do
      tokens = [1_100_000_i64, 12_700_000_i64, 48_200_000_i64, 5_800_000_i64]
      tok_strs = tokens.map { |t| GalaxyLedger::Chart.format_tokens(t) }
      max_w = tok_strs.max_of(&.size)
      aligned = tok_strs.map(&.rjust(max_w))

      # All aligned strings should be the same width
      aligned.map(&.size).uniq.size.should eq(1)

      # Decimal points should be at the same position
      dot_positions = aligned.map { |s| s.index('.').not_nil! }
      dot_positions.uniq.size.should eq(1)
    end

    it "produces aligned columns in bar chart output" do
      # Simulate full CLI alignment flow: format, measure, rjust, build rows
      data = [
        {label: "Feb 18", cost: 49.37, tokens: 1_100_000_i64},
        {label: "Feb 19", cost: 115.43, tokens: 12_700_000_i64},
        {label: "Feb 21", cost: 184.47, tokens: 48_200_000_i64},
      ]
      cost_strs = data.map { |d| GalaxyLedger::Chart.format_cost(d[:cost]) }
      tok_strs = data.map { |d| GalaxyLedger::Chart.format_tokens(d[:tokens]) }
      max_cost_w = cost_strs.max_of(&.size)
      max_tok_w = tok_strs.max_of(&.size)

      rows = data.map_with_index do |d, i|
        extra = "#{cost_strs[i].rjust(max_cost_w)}    #{tok_strs[i].rjust(max_tok_w)}"
        GalaxyLedger::Chart::BarRow.new(label: d[:label], value: d[:cost], extra: extra)
      end

      result = GalaxyLedger::Chart.bar_chart(rows)
      lines = result.split("\n")

      # Extract the cost column ($xx.xx) from each line and verify decimal alignment
      cost_dot_positions = lines.map { |l| l.index("$.").try { |i| nil } || l.index('$').try { |i| l.index('.', i) } }
      non_nil = cost_dot_positions.compact
      non_nil.size.should eq(3)
      non_nil.uniq.size.should eq(1)
    end

    it "handles mixed k and M token magnitudes" do
      tokens = [500_000_i64, 12_700_000_i64]
      tok_strs = tokens.map { |t| GalaxyLedger::Chart.format_tokens(t) }
      max_w = tok_strs.max_of(&.size)
      aligned = tok_strs.map(&.rjust(max_w))

      # Both should be padded to same width
      aligned.map(&.size).uniq.size.should eq(1)
      # "500.0k tok" (10 chars) vs " 12.7M tok" (padded to 10) — shorter one gets padded
      aligned[1].should start_with(" ")
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
