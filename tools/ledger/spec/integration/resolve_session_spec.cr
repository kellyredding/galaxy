require "../spec_helper"

describe "CLI Integration: resolve-session" do
  describe "help" do
    it "shows help with --help flag" do
      result = run_binary(["resolve-session", "--help"])
      result[:output].should contain("galaxy-ledger resolve-session")
      result[:output].should contain("--pid")
      result[:output].should contain("--session")
      result[:status].should eq(0)
    end

    it "shows help with -h flag" do
      result = run_binary(["resolve-session", "-h"])
      result[:output].should contain("galaxy-ledger resolve-session")
      result[:status].should eq(0)
    end
  end

  describe "flag validation" do
    it "errors when no flags provided" do
      result = run_binary(["resolve-session"])
      result[:error].should contain("--pid or --session is required")
      result[:status].should_not eq(0)
    end
  end

  describe "--pid resolution" do
    it "resolves a PID to ledger session ID" do
      pid = Random.rand(10000).to_i64 + 50000
      session_id = "resolve-pid-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(
        session_id,
        claude_pid: pid,
      )

      flush_wal

      result = run_binary(["resolve-session", "--pid", pid.to_s])
      result[:status].should eq(0)
      result[:output].strip.should eq(ledger_session_id.to_s)
    end

    it "exits non-zero when PID not found" do
      result = run_binary(["resolve-session", "--pid", "999999999"])
      result[:status].should_not eq(0)
      result[:error].should contain("no session found")
    end

    it "exits non-zero with invalid PID (non-integer)" do
      result = run_binary(["resolve-session", "--pid", "not-a-number"])
      result[:status].should_not eq(0)
      result[:error].should contain("invalid --pid")
    end
  end

  describe "--session resolution" do
    it "resolves a session identifier to ledger session ID" do
      session_id = "resolve-sid-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      flush_wal

      result = run_binary(["resolve-session", "--session", session_id])
      result[:status].should eq(0)
      result[:output].strip.should eq(ledger_session_id.to_s)
    end

    it "resolves a registered identifier (not the creation identifier)" do
      session_id = "resolve-sid-orig-#{Random.rand(100000)}"
      resumed_id = "resolve-sid-resumed-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)
      GalaxyLedger::Database.register_session_identifier(
        ledger_session_id,
        resumed_id,
      )

      flush_wal

      result = run_binary(["resolve-session", "--session", resumed_id])
      result[:status].should eq(0)
      result[:output].strip.should eq(ledger_session_id.to_s)
    end

    it "exits non-zero when session identifier not found" do
      result = run_binary([
        "resolve-session",
        "--session", "ses_does_not_exist_#{Random.rand(100000)}",
      ])
      result[:status].should_not eq(0)
      result[:error].should contain("no session found")
    end
  end
end
