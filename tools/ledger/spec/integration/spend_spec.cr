require "../spec_helper"

# Helper to seed daily usage records directly for spend command testing
def seed_daily_usage(
  ledger_session_id : Int64,
  date : String,
  cost : Float64,
  tokens : Int64,
  baseline_cost : Float64 = 0.0,
  baseline_tokens : Int64 = 0_i64,
  oneshot_cost : Float64 = 0.0,
  oneshot_tokens : Int64 = 0_i64,
)
  GalaxyLedger::Database.open do |db|
    db.exec(
      <<-SQL,
        INSERT INTO ledger_session_daily_usages (
          ledger_session_id, date,
          baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
          baseline_tokens, current_tokens, cumulative_tokens,
          oneshot_cost_usd, oneshot_tokens
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      ledger_session_id, date,
      baseline_cost, baseline_cost + cost, cost,
      baseline_tokens, baseline_tokens + tokens, tokens,
      oneshot_cost, oneshot_tokens,
    )
  end
end

describe "CLI Integration - spend" do
  describe "spend --help" do
    it "shows help text" do
      result = run_binary(["spend", "--help"])
      result[:output].should contain("galaxy-ledger spend")
      result[:output].should contain("PERIODS")
      result[:output].should contain("mtd")
      result[:status].should eq(0)
    end
  end

  describe "spend with no data" do
    it "outputs header and zero summary" do
      result = run_binary(["spend", "today"])
      result[:output].should contain("Spend")
      result[:output].should contain("$0.00")
      result[:output].should contain("Active Days:")
      result[:status].should eq(0)
    end
  end

  describe "spend with data" do
    it "shows summary for today" do
      lid = GalaxyLedger::Database.create_session("sess-spend-today")
      today = Time.utc.to_s("%Y-%m-%d")
      seed_daily_usage(lid, today, 5.50, 150000_i64)

      result = run_binary(["spend", "today"])
      result[:output].should contain("$5.50")
      result[:output].should contain("150.0k tok")
      result[:output].should contain("Active Sessions:  1")
      result[:status].should eq(0)
    end

    it "shows MTD summary by default" do
      lid = GalaxyLedger::Database.create_session("sess-spend-mtd")
      today = Time.utc
      seed_daily_usage(lid, today.to_s("%Y-%m-%d"), 3.25, 50000_i64)

      result = run_binary(["spend"])
      result[:output].should contain("Month to Date")
      result[:output].should contain("$3.25")
      result[:status].should eq(0)
    end
  end

  describe "spend --json" do
    it "outputs valid JSON" do
      lid = GalaxyLedger::Database.create_session("sess-spend-json")
      today = Time.utc.to_s("%Y-%m-%d")
      seed_daily_usage(lid, today, 2.00, 80000_i64)

      result = run_binary(["spend", "today", "--json"])
      result[:status].should eq(0)

      json = JSON.parse(result[:output])
      json["period"].as_s.should eq("today")
      json["summary"]["total_cost_usd"].as_f.should eq(2.0)
      json["summary"]["total_tokens"].as_i64.should eq(80000_i64)
      json["summary"]["active_sessions"].as_i.should eq(1)
      json["daily"].as_a.size.should eq(1)
      json["daily"][0]["date"].as_s.should eq(today)
    end

    it "outputs empty daily array when no data" do
      result = run_binary(["spend", "today", "--json"])
      result[:status].should eq(0)

      json = JSON.parse(result[:output])
      json["summary"]["total_cost_usd"].as_f.should eq(0.0)
      json["daily"].as_a.should be_empty
    end
  end

  describe "spend with custom range" do
    it "accepts YYYY-MM-DD..YYYY-MM-DD format" do
      lid = GalaxyLedger::Database.create_session("sess-spend-custom")
      seed_daily_usage(lid, "2025-01-15", 10.0, 200000_i64)

      result = run_binary(["spend", "2025-01-01..2025-01-31"])
      result[:output].should contain("$10.00")
      result[:status].should eq(0)
    end
  end

  describe "spend with unknown period" do
    it "exits with error" do
      result = run_binary(["spend", "bogus"])
      result[:error].should contain("unknown period")
      result[:status].should_not eq(0)
    end
  end

  describe "spend --no-chart --no-sparkline" do
    it "suppresses chart and sparkline output" do
      lid = GalaxyLedger::Database.create_session("sess-spend-novis")
      today = Time.utc.to_s("%Y-%m-%d")
      seed_daily_usage(lid, today, 5.00, 100000_i64)

      result = run_binary(["spend", "today", "--no-chart", "--no-sparkline"])
      result[:output].should contain("$5.00")
      # Should still have the summary
      result[:output].should contain("Total Cost:")
      result[:status].should eq(0)
    end
  end

  describe "spend with oneshot data" do
    it "includes oneshot in total cost" do
      lid = GalaxyLedger::Database.create_session("sess-spend-oneshot")
      today = Time.utc.to_s("%Y-%m-%d")
      seed_daily_usage(lid, today, 5.00, 100000_i64, oneshot_cost: 0.50, oneshot_tokens: 10000_i64)

      result = run_binary(["spend", "today"])
      result[:output].should contain("$5.50")
      result[:output].should contain("110.0k tok")
      result[:status].should eq(0)
    end

    it "includes oneshot in JSON output" do
      lid = GalaxyLedger::Database.create_session("sess-spend-oneshot-json")
      today = Time.utc.to_s("%Y-%m-%d")
      seed_daily_usage(lid, today, 5.00, 100000_i64, oneshot_cost: 0.50, oneshot_tokens: 10000_i64)

      result = run_binary(["spend", "today", "--json"])
      result[:status].should eq(0)

      json = JSON.parse(result[:output])
      json["summary"]["total_cost_usd"].as_f.should eq(5.5)
      json["summary"]["total_tokens"].as_i64.should eq(110000_i64)
    end

    it "shows cost when only oneshot data exists (no session activity)" do
      lid = GalaxyLedger::Database.create_session("sess-spend-oneshot-only")
      today = Time.utc.to_s("%Y-%m-%d")
      seed_daily_usage(lid, today, 0.0, 0_i64, oneshot_cost: 0.25, oneshot_tokens: 5000_i64)

      result = run_binary(["spend", "today"])
      result[:output].should contain("$0.25")
      result[:output].should contain("5.0k tok")
      result[:status].should eq(0)
    end
  end
end
