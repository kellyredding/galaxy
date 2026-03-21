require "../spec_helper"

describe "CLI Integration: session-identifiers" do
  describe "help" do
    it "shows help with --help flag" do
      result = run_binary(["session-identifiers", "--help"])
      result[:output].should contain("galaxy-ledger session-identifiers")
      result[:output].should contain("--json")
      result[:output].should contain("--ledger-session-id")
      result[:status].should eq(0)
    end

    it "shows help with -h flag" do
      result = run_binary(["session-identifiers", "-h"])
      result[:output].should contain("galaxy-ledger session-identifiers")
      result[:status].should eq(0)
    end
  end

  describe "flag validation" do
    it "errors when --json is missing" do
      result = run_binary([
        "session-identifiers",
        "--ledger-session-id", "1",
      ])
      result[:error].should contain("--json is required")
      result[:status].should_not eq(0)
    end

    it "errors when --ledger-session-id is missing" do
      result = run_binary(["session-identifiers", "--json"])
      result[:error].should contain("--ledger-session-id is required")
      result[:status].should_not eq(0)
    end

    it "errors with invalid (non-integer) ledger session ID" do
      result = run_binary([
        "session-identifiers",
        "--json",
        "--ledger-session-id", "not-a-number",
      ])
      result[:status].should_not eq(0)
      result[:error].should contain("invalid --ledger-session-id")
    end
  end

  describe "successful queries" do
    it "returns session identifiers as JSON" do
      session_id = "sid-test-#{Random.rand(100000)}"
      resumed_id = "sid-resumed-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)
      GalaxyLedger::Database.register_session_identifier(
        ledger_session_id,
        resumed_id,
      )

      flush_wal

      result = run_binary([
        "session-identifiers",
        "--json",
        "--ledger-session-id", ledger_session_id.to_s,
      ])
      result[:status].should eq(0)

      json = JSON.parse(result[:output])
      identifiers = json["session_identifiers"].as_a.map(&.as_s)
      identifiers.should contain(session_id)
      identifiers.should contain(resumed_id)
    end

    it "returns empty array for session with no identifiers" do
      # Create a session — it has at least the creation identifier
      session_id = "sid-empty-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      flush_wal

      result = run_binary([
        "session-identifiers",
        "--json",
        "--ledger-session-id", ledger_session_id.to_s,
      ])
      result[:status].should eq(0)

      json = JSON.parse(result[:output])
      identifiers = json["session_identifiers"].as_a.map(&.as_s)
      # create_session registers the session_id as an identifier
      identifiers.should contain(session_id)
    end

    it "returns empty array for nonexistent session ID" do
      result = run_binary([
        "session-identifiers",
        "--json",
        "--ledger-session-id", "999999999",
      ])
      result[:status].should eq(0)

      json = JSON.parse(result[:output])
      json["session_identifiers"].as_a.size.should eq(0)
    end
  end
end
