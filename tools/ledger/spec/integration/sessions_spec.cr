require "../spec_helper"

describe "CLI Integration: sessions" do
  describe "help" do
    it "shows help with --help flag" do
      result = run_binary(["sessions", "--help"])
      result[:output].should contain("galaxy-ledger sessions")
      result[:output].should contain("--json")
      result[:output].should contain("--session")
      result[:status].should eq(0)
    end

    it "shows help with -h flag" do
      result = run_binary(["sessions", "-h"])
      result[:output].should contain("galaxy-ledger sessions")
      result[:status].should eq(0)
    end
  end

  describe "flag validation" do
    it "errors when --json is missing" do
      result = run_binary(["sessions", "--session", "abc-123"])
      result[:error].should contain("--json is required")
      result[:status].should_not eq(0)
    end

    it "errors when no --session flags provided" do
      result = run_binary(["sessions", "--json"])
      result[:error].should contain("at least one --session is required")
      result[:status].should_not eq(0)
    end
  end

  describe "single session query" do
    it "returns session data as JSON" do
      session_id = "sessions-test-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(
        session_id,
        cwd: "/tmp/test-project",
        project_dir: "/tmp/test-project",
        git_branch: "main",
      )

      result = run_binary(["sessions", "--json", "--session", session_id])
      result[:status].should eq(0)

      parsed = JSON.parse(result[:output])
      sessions = parsed["sessions"].as_a
      sessions.size.should eq(1)

      session = sessions[0]
      session["ledger_session_id"].as_i64.should eq(ledger_session_id)
      session["current_session_identifier"].as_s.should eq(session_id)
      session["cwd"].as_s.should eq("/tmp/test-project")
      session["project_dir"].as_s.should eq("/tmp/test-project")
      session["git_branch"].as_s.should eq("main")
      session["session_identifiers"].as_a.map(&.as_s).should contain(session_id)
    end

    it "includes metric fields with defaults" do
      session_id = "sessions-metrics-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(session_id)

      result = run_binary(["sessions", "--json", "--session", session_id])
      result[:status].should eq(0)

      session = JSON.parse(result[:output])["sessions"].as_a[0]
      session["context_percentage"].as_f.should eq(0.0)
      session["tokens_used"].as_i64.should eq(0)
      session["tokens_max"].as_i64.should eq(0)
      session["cost_usd"].as_f.should eq(0.0)
      session["lines_added"].as_i64.should eq(0)
      session["lines_removed"].as_i64.should eq(0)
    end

    it "includes suggested_name field (nil by default)" do
      session_id = "sessions-name-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(session_id)

      result = run_binary(["sessions", "--json", "--session", session_id])
      result[:status].should eq(0)

      session = JSON.parse(result[:output])["sessions"].as_a[0]
      session["suggested_name"].as_s?.should be_nil
    end

    it "includes suggested_name when set" do
      session_id = "sessions-name-set-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)
      GalaxyLedger::Database.update_suggested_name(ledger_session_id, "Event System Design")

      result = run_binary(["sessions", "--json", "--session", session_id])
      result[:status].should eq(0)

      session = JSON.parse(result[:output])["sessions"].as_a[0]
      session["suggested_name"].as_s.should eq("Event System Design")
    end

    it "includes session_identifiers array with all registered identifiers" do
      session_id = "sessions-ids-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)
      GalaxyLedger::Database.register_session_identifier(ledger_session_id, "resumed-id-1")
      GalaxyLedger::Database.register_session_identifier(ledger_session_id, "resumed-id-2")

      result = run_binary(["sessions", "--json", "--session", session_id])
      result[:status].should eq(0)

      session = JSON.parse(result[:output])["sessions"].as_a[0]
      ids = session["session_identifiers"].as_a.map(&.as_s)
      ids.should contain(session_id)
      ids.should contain("resumed-id-1")
      ids.should contain("resumed-id-2")
    end

    it "includes claude_pids array" do
      pid = Random.rand(10000).to_i64 + 50000
      session_id = "sessions-pids-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id, claude_pid: pid)

      result = run_binary(["sessions", "--json", "--session", session_id])
      result[:status].should eq(0)

      session = JSON.parse(result[:output])["sessions"].as_a[0]
      pids = session["claude_pids"].as_a.map(&.as_i64)
      pids.should contain(pid)
      session["current_claude_pid"].as_i64.should eq(pid)
    end
  end

  describe "multiple session queries" do
    it "returns multiple sessions" do
      sid1 = "sessions-multi-1-#{Random.rand(100000)}"
      sid2 = "sessions-multi-2-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(sid1)
      GalaxyLedger::Database.create_session(sid2)

      result = run_binary(["sessions", "--json", "--session", sid1, "--session", sid2])
      result[:status].should eq(0)

      sessions = JSON.parse(result[:output])["sessions"].as_a
      sessions.size.should eq(2)
    end

    it "deduplicates when multiple identifiers resolve to the same session" do
      sid1 = "sessions-dedup-1-#{Random.rand(100000)}"
      sid2 = "sessions-dedup-2-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(sid1)
      GalaxyLedger::Database.register_session_identifier(ledger_session_id, sid2)

      result = run_binary(["sessions", "--json", "--session", sid1, "--session", sid2])
      result[:status].should eq(0)

      sessions = JSON.parse(result[:output])["sessions"].as_a
      sessions.size.should eq(1)
      sessions[0]["ledger_session_id"].as_i64.should eq(ledger_session_id)
    end
  end

  describe "unknown session handling" do
    it "silently omits unknown session identifiers" do
      result = run_binary(["sessions", "--json", "--session", "nonexistent-id"])
      result[:status].should eq(0)

      sessions = JSON.parse(result[:output])["sessions"].as_a
      sessions.size.should eq(0)
    end

    it "returns known sessions and omits unknown ones" do
      sid = "sessions-mixed-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(sid)

      result = run_binary(["sessions", "--json", "--session", sid, "--session", "nonexistent-id"])
      result[:status].should eq(0)

      sessions = JSON.parse(result[:output])["sessions"].as_a
      sessions.size.should eq(1)
    end
  end
end
