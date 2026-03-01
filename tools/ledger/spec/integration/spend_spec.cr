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
      result[:output].should contain("30d")
      result[:output].should contain("mtd")
      result[:status].should eq(0)
    end
  end

  describe "spend with no data" do
    it "outputs header and zero summary" do
      result = run_binary(["spend", "wtd"])
      result[:output].should contain("Spend")
      result[:output].should contain("$0.00")
      result[:output].should contain("Active Days:")
      result[:status].should eq(0)
    end
  end

  describe "spend with data" do
    it "shows WTD summary" do
      lid = GalaxyLedger::Database.create_session("sess-spend-wtd")
      today = Time.utc.to_s("%Y-%m-%d")
      seed_daily_usage(lid, today, 5.50, 150000_i64)

      result = run_binary(["spend", "wtd"])
      result[:output].should contain("Week to Date")
      result[:output].should contain("$5.50")
      result[:output].should contain("Active Sessions:  1")
      result[:status].should eq(0)
    end

    it "shows 30d summary by default" do
      lid = GalaxyLedger::Database.create_session("sess-spend-30d")
      today = Time.utc.to_s("%Y-%m-%d")
      seed_daily_usage(lid, today, 3.25, 50000_i64)

      result = run_binary(["spend"])
      result[:output].should contain("Last 30 Days")
      result[:output].should contain("$3.25")
      result[:status].should eq(0)
    end

    it "shows 30d summary" do
      lid = GalaxyLedger::Database.create_session("sess-spend-30d-explicit")
      today = Time.utc.to_s("%Y-%m-%d")
      seed_daily_usage(lid, today, 7.00, 200000_i64)

      result = run_binary(["spend", "30d"])
      result[:output].should contain("Last 30 Days")
      result[:output].should contain("$7.00")
      result[:output].should contain("Active Sessions:  1")
      result[:status].should eq(0)
    end
  end

  describe "spend --json" do
    it "outputs valid JSON" do
      lid = GalaxyLedger::Database.create_session("sess-spend-json")
      today = Time.utc.to_s("%Y-%m-%d")
      seed_daily_usage(lid, today, 2.00, 80000_i64)

      result = run_binary(["spend", "mtd", "--json"])
      result[:status].should eq(0)

      json = JSON.parse(result[:output])
      json["period"].as_s.should eq("mtd")
      json["summary"]["total_cost_usd"].as_f.should eq(2.0)
      json["summary"]["total_tokens"].as_i64.should eq(80000_i64)
      json["summary"]["active_sessions"].as_i.should eq(1)
      json["daily"].as_a.size.should eq(1)
      json["daily"][0]["date"].as_s.should eq(today)
    end

    it "outputs empty daily array when no data" do
      result = run_binary(["spend", "mtd", "--json"])
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

      result = run_binary(["spend", "mtd", "--no-chart", "--no-sparkline"])
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

      result = run_binary(["spend", "mtd"])
      result[:output].should contain("$5.50")
      result[:output].should contain("110.0k tok")
      result[:status].should eq(0)
    end

    it "includes oneshot in JSON output" do
      lid = GalaxyLedger::Database.create_session("sess-spend-oneshot-json")
      today = Time.utc.to_s("%Y-%m-%d")
      seed_daily_usage(lid, today, 5.00, 100000_i64, oneshot_cost: 0.50, oneshot_tokens: 10000_i64)

      result = run_binary(["spend", "mtd", "--json"])
      result[:status].should eq(0)

      json = JSON.parse(result[:output])
      json["summary"]["total_cost_usd"].as_f.should eq(5.5)
      json["summary"]["total_tokens"].as_i64.should eq(110000_i64)
    end

    it "shows cost when only oneshot data exists (no session activity)" do
      lid = GalaxyLedger::Database.create_session("sess-spend-oneshot-only")
      today = Time.utc.to_s("%Y-%m-%d")
      seed_daily_usage(lid, today, 0.0, 0_i64, oneshot_cost: 0.25, oneshot_tokens: 5000_i64)

      result = run_binary(["spend", "mtd"])
      result[:output].should contain("$0.25")
      result[:output].should contain("5.0k tok")
      result[:status].should eq(0)
    end
  end

  describe "spend gap-fills calendar days" do
    it "shows all days in a custom range including gaps" do
      lid = GalaxyLedger::Database.create_session("sess-gap-fill")
      seed_daily_usage(lid, "2025-03-01", 5.00, 100000_i64)
      seed_daily_usage(lid, "2025-03-03", 3.00, 50000_i64)

      result = run_binary(["spend", "2025-03-01..2025-03-03"])
      result[:status].should eq(0)
      # All three days should appear in the bar chart
      result[:output].should contain("Mar 01")
      result[:output].should contain("Mar 02")
      result[:output].should contain("Mar 03")
    end

    it "does not gap-fill JSON output" do
      lid = GalaxyLedger::Database.create_session("sess-json-no-gap")
      seed_daily_usage(lid, "2025-03-01", 5.00, 100000_i64)
      seed_daily_usage(lid, "2025-03-05", 3.00, 50000_i64)

      result = run_binary(["spend", "2025-03-01..2025-03-07", "--json"])
      result[:status].should eq(0)

      json = JSON.parse(result[:output])
      json["daily"].as_a.size.should eq(2)
    end
  end

  describe "spend avg daily rate excludes zero-cost days" do
    it "computes average from non-zero days only" do
      lid = GalaxyLedger::Database.create_session("sess-avg-nonzero")
      seed_daily_usage(lid, "2025-03-01", 10.00, 100000_i64)
      seed_daily_usage(lid, "2025-03-02", 0.00, 0_i64)
      seed_daily_usage(lid, "2025-03-03", 20.00, 200000_i64)

      result = run_binary(["spend", "2025-03-01..2025-03-03"])
      result[:status].should eq(0)
      # Avg should be (10 + 20) / 2 = $15.00, not (10 + 0 + 20) / 3 = $10.00
      result[:output].should contain("Avg Daily Rate:   $15.00")
    end

    it "returns $0.00 avg when all days have zero cost" do
      lid = GalaxyLedger::Database.create_session("sess-all-zeros")
      seed_daily_usage(lid, "2025-03-01", 0.00, 0_i64)
      seed_daily_usage(lid, "2025-03-02", 0.00, 0_i64)

      result = run_binary(["spend", "2025-03-01..2025-03-02"])
      result[:status].should eq(0)
      result[:output].should contain("Avg Daily Rate:   $0.00")
    end
  end

  describe "spend sparkline stats exclude zero-cost days" do
    it "excludes zero days from Low/High/Avg" do
      lid = GalaxyLedger::Database.create_session("sess-spark-nonzero")
      seed_daily_usage(lid, "2025-03-01", 10.00, 100000_i64)
      seed_daily_usage(lid, "2025-03-03", 20.00, 200000_i64)

      # Range includes 3 days, but only 2 have data
      result = run_binary(["spend", "2025-03-01..2025-03-03"])
      result[:status].should eq(0)
      # Low should be $10.00 (not $0.00 from gap-filled day)
      result[:output].should contain("Low: $10.00")
      # Avg should be (10 + 20) / 2 = $15.00
      result[:output].should contain("Avg: $15.00")
    end
  end

  describe "spend today is no longer valid" do
    it "exits with error for today period" do
      result = run_binary(["spend", "today"])
      result[:error].should contain("unknown period")
      result[:status].should_not eq(0)
    end
  end

  describe "spend grouping tiers" do
    it "shows daily sparkline and daily bars for 30d" do
      lid = GalaxyLedger::Database.create_session("sess-tier-30d")
      fake_today = Time.utc(Time.utc.year, Time.utc.month, 15)
      seed_daily_usage(lid, (fake_today - 5.days).to_s("%Y-%m-%d"), 4.00, 80000_i64)
      seed_daily_usage(lid, fake_today.to_s("%Y-%m-%d"), 6.00, 120000_i64)

      result = run_binary(["spend", "30d"], extra_env: {"GALAXY_LEDGER_TODAY" => fake_today.to_s("%Y-%m-%d")})
      result[:status].should eq(0)
      result[:output].should contain("Daily:")
      result[:output].should contain("excludes days with no usage")
    end

    it "shows daily sparkline and daily bars for mtd" do
      lid = GalaxyLedger::Database.create_session("sess-tier-daily")
      # Pin "today" to mid-month so mtd always has multiple days
      fake_today = Time.utc(Time.utc.year, Time.utc.month, 15)
      fake_yesterday = fake_today - 1.day
      seed_daily_usage(lid, fake_yesterday.to_s("%Y-%m-%d"), 4.00, 80000_i64)
      seed_daily_usage(lid, fake_today.to_s("%Y-%m-%d"), 6.00, 120000_i64)

      result = run_binary(["spend", "mtd"], extra_env: {"GALAXY_LEDGER_TODAY" => fake_today.to_s("%Y-%m-%d")})
      result[:status].should eq(0)
      result[:output].should contain("Daily:")
      result[:output].should contain("excludes days with no usage")
    end

    it "shows single-day mtd on first of month without sparkline" do
      lid = GalaxyLedger::Database.create_session("sess-tier-first")
      # Pin "today" to the 1st — only one possible day in mtd range
      fake_today = Time.utc(Time.utc.year, Time.utc.month, 1)
      seed_daily_usage(lid, fake_today.to_s("%Y-%m-%d"), 6.00, 120000_i64)

      result = run_binary(["spend", "mtd"], extra_env: {"GALAXY_LEDGER_TODAY" => fake_today.to_s("%Y-%m-%d")})
      result[:status].should eq(0)
      # Single day: no sparkline/Daily: header, but bars still render
      result[:output].should_not contain("Daily:")
      result[:output].should contain(fake_today.to_s("%b %d"))
    end

    it "shows weekly sparkline and weekly bars for qtd" do
      lid = GalaxyLedger::Database.create_session("sess-tier-weekly")
      today = Time.utc
      quarter_month = ((today.month - 1) // 3) * 3 + 1
      q_first = Time.utc(today.year, quarter_month, 1)
      seed_daily_usage(lid, q_first.to_s("%Y-%m-%d"), 4.00, 80000_i64)
      seed_daily_usage(lid, today.to_s("%Y-%m-%d"), 6.00, 120000_i64)

      result = run_binary(["spend", "qtd"])
      result[:status].should eq(0)
      result[:output].should contain("Weekly:")
      result[:output].should contain("/wk")
      result[:output].should contain("excludes weeks with no usage")
    end

    it "shows monthly sparkline and monthly bars for 1y" do
      lid = GalaxyLedger::Database.create_session("sess-tier-monthly")
      today = Time.utc
      six_months_ago = today - 180.days
      seed_daily_usage(lid, six_months_ago.to_s("%Y-%m-%d"), 4.00, 80000_i64)
      seed_daily_usage(lid, today.to_s("%Y-%m-%d"), 6.00, 120000_i64)

      result = run_binary(["spend", "1y"])
      result[:status].should eq(0)
      result[:output].should contain("Monthly:")
      result[:output].should contain("/mo")
      result[:output].should contain("excludes months with no usage")
    end

    it "shows weekly sparkline and weekly bars for ytd" do
      lid = GalaxyLedger::Database.create_session("sess-tier-ytd")
      today = Time.utc
      jan_first = Time.utc(today.year, 1, 1)
      seed_daily_usage(lid, jan_first.to_s("%Y-%m-%d"), 3.00, 50000_i64)
      seed_daily_usage(lid, today.to_s("%Y-%m-%d"), 5.00, 100000_i64)

      result = run_binary(["spend", "ytd"])
      result[:status].should eq(0)
      result[:output].should contain("Weekly:")
      result[:output].should contain("/wk")
      result[:output].should contain("excludes weeks with no usage")
    end
  end

  describe "spend footnote" do
    it "shows days footnote for daily periods" do
      lid = GalaxyLedger::Database.create_session("sess-footnote-daily")
      # Pin "today" to mid-month so mtd always has multiple days
      fake_today = Time.utc(Time.utc.year, Time.utc.month, 15)
      first = Time.utc(fake_today.year, fake_today.month, 1)
      seed_daily_usage(lid, first.to_s("%Y-%m-%d"), 3.00, 50000_i64)
      seed_daily_usage(lid, fake_today.to_s("%Y-%m-%d"), 5.00, 100000_i64)

      result = run_binary(["spend", "mtd"], extra_env: {"GALAXY_LEDGER_TODAY" => fake_today.to_s("%Y-%m-%d")})
      result[:status].should eq(0)
      result[:output].should contain("\u2020")
      result[:output].should contain("excludes days with no usage")
    end

    it "shows weeks footnote for weekly periods" do
      lid = GalaxyLedger::Database.create_session("sess-footnote-weekly")
      today = Time.utc
      quarter_month = ((today.month - 1) // 3) * 3 + 1
      q_first = Time.utc(today.year, quarter_month, 1)
      seed_daily_usage(lid, q_first.to_s("%Y-%m-%d"), 3.00, 50000_i64)
      seed_daily_usage(lid, today.to_s("%Y-%m-%d"), 5.00, 100000_i64)

      result = run_binary(["spend", "qtd"])
      result[:status].should eq(0)
      result[:output].should contain("excludes weeks with no usage")
    end

    it "shows months footnote for monthly periods" do
      lid = GalaxyLedger::Database.create_session("sess-footnote-monthly")
      today = Time.utc
      year_ago = today - 365.days
      seed_daily_usage(lid, year_ago.to_s("%Y-%m-%d"), 3.00, 50000_i64)
      seed_daily_usage(lid, today.to_s("%Y-%m-%d"), 5.00, 100000_i64)

      result = run_binary(["spend", "1y"])
      result[:status].should eq(0)
      result[:output].should contain("excludes months with no usage")
    end
  end
end
