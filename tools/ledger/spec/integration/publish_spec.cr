require "../spec_helper"

# Helper to create a session with a registered PID for publish tests.
def create_publish_session_with_pid(pid : Int64) : Int64
  session_id = "publish-test-#{Random.rand(100000)}"
  GalaxyLedger::Database.create_session(session_id, claude_pid: pid)
end

describe "CLI Integration: publish" do
  describe "help" do
    it "shows help with --help flag" do
      result = run_binary(["publish", "--help"])
      result[:output].should contain("galaxy-ledger publish")
      result[:output].should contain("--event")
      result[:output].should contain("--pid")
      result[:status].should eq(0)
    end

    it "shows help with -h flag" do
      result = run_binary(["publish", "-h"])
      result[:output].should contain("galaxy-ledger publish")
      result[:status].should eq(0)
    end
  end

  describe "flag validation" do
    it "errors when --event is missing" do
      result = run_binary(["publish", "--pid", "12345"])
      result[:error].should contain("--event is required")
      result[:status].should_not eq(0)
    end

    it "errors when --pid and --session are both missing" do
      result = run_binary(["publish", "--event", "session.metrics"])
      result[:error].should contain("--session or --pid is required")
      result[:status].should_not eq(0)
    end

    it "errors when --pid resolves to no session" do
      result = run_binary(["publish", "--event", "session.metrics", "--pid", "99999"])
      result[:error].should contain("no session found")
      result[:status].should_not eq(0)
    end

    it "errors when --session resolves to no session" do
      result = run_binary(["publish", "--event", "session.metrics", "--session", "nonexistent-id"])
      result[:error].should contain("no session found")
      result[:status].should_not eq(0)
    end
  end

  describe "successful publish" do
    it "exits 0 with --pid when session exists (no socket listener)" do
      pid = Random.rand(10000).to_i64 + 50000
      create_publish_session_with_pid(pid)

      result = run_binary(["publish", "--event", "session.metrics", "--pid", pid.to_s])
      result[:status].should eq(0)
    end

    it "exits 0 with --session when session exists (no socket listener)" do
      session_id = "publish-ok-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(session_id)

      result = run_binary(["publish", "--event", "session.metrics", "--session", session_id])
      result[:status].should eq(0)
    end

    it "exits 0 with --ref flag" do
      session_id = "publish-ref-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(session_id)

      result = run_binary(["publish", "--event", "snapshot.created", "--session", session_id, "--ref", "3"])
      result[:status].should eq(0)
    end
  end
end
