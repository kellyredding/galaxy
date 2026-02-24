require "../spec_helper"

# Helper to create a test session with PID mapping for snapshot CLI tests.
def create_snapshot_session_with_pid(pid : Int64) : Int64
  session_id = "snap-cli-#{pid}"
  GalaxyLedger::Database.create_session(session_id, claude_pid: pid)
end

describe "CLI snapshot commands", tags: "integration" do
  describe "snapshot create" do
    it "creates a snapshot from stdin" do
      pid = 90001_i64
      session_id = create_snapshot_session_with_pid(pid)

      result = run_binary(
        ["snapshot", "create", "--pid", pid.to_s, "--title", "Design discussion"],
        stdin: "## Exchange 1\n\n### User\nHello\n\n### Assistant\nHi there!",
      )

      result[:status].should eq(0)
      result[:output].should contain("Snapshot #1 saved")
      result[:output].should contain("Design discussion")

      # Verify DB record
      snapshot = GalaxyLedger::Database.get_snapshot_by_number(session_id, 1)
      snapshot.should_not be_nil
      snapshot.not_nil!.title.should eq("Design discussion")
    end

    it "includes char count in output" do
      pid = 90002_i64
      create_snapshot_session_with_pid(pid)
      content = "Hello, world! This is test content."

      result = run_binary(
        ["snapshot", "create", "--pid", pid.to_s, "--title", "Chars test"],
        stdin: content,
      )

      result[:status].should eq(0)
      result[:output].should contain("chars: #{content.size}")
    end

    it "supports --exchanges flag" do
      pid = 90003_i64
      session_id = create_snapshot_session_with_pid(pid)

      result = run_binary(
        ["snapshot", "create", "--pid", pid.to_s, "--title", "Multi", "--exchanges", "3"],
        stdin: "content here",
      )

      result[:status].should eq(0)
      snapshot = GalaxyLedger::Database.get_snapshot_by_number(session_id, 1)
      snapshot.not_nil!.exchange_count.should eq(3)
    end

    it "errors when --pid is missing" do
      result = run_binary(
        ["snapshot", "create", "--title", "No PID"],
        stdin: "content",
      )

      result[:status].should_not eq(0)
      result[:error].should contain("--pid is required")
    end

    it "errors when --title is missing" do
      pid = 90004_i64
      create_snapshot_session_with_pid(pid)

      result = run_binary(
        ["snapshot", "create", "--pid", pid.to_s],
        stdin: "content",
      )

      result[:status].should_not eq(0)
      result[:error].should contain("--title is required")
    end

    it "errors when stdin is empty" do
      pid = 90005_i64
      create_snapshot_session_with_pid(pid)

      result = run_binary(
        ["snapshot", "create", "--pid", pid.to_s, "--title", "Empty"],
        stdin: "",
      )

      result[:status].should_not eq(0)
      result[:error].should contain("no content provided on stdin")
    end
  end

  describe "snapshot list" do
    it "lists snapshots in human-readable format" do
      pid = 90010_i64
      session_id = create_snapshot_session_with_pid(pid)
      GalaxyLedger::Database.save_snapshot(session_id, "First snap", "content 1")
      GalaxyLedger::Database.save_snapshot(session_id, "Second snap", "content 2")

      result = run_binary(["snapshot", "list", "--pid", pid.to_s])

      result[:status].should eq(0)
      result[:output].should contain("2 total")
      result[:output].should contain("#1")
      result[:output].should contain("First snap")
      result[:output].should contain("#2")
      result[:output].should contain("Second snap")
    end

    it "lists snapshots in JSON format" do
      pid = 90011_i64
      session_id = create_snapshot_session_with_pid(pid)
      GalaxyLedger::Database.save_snapshot(session_id, "JSON test", "json content")

      result = run_binary(["snapshot", "list", "--pid", pid.to_s, "--json"])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      snapshots = parsed["snapshots"].as_a
      snapshots.size.should eq(1)
      snapshots[0]["number"].as_i.should eq(1)
      snapshots[0]["title"].as_s.should eq("JSON test")
      snapshots[0]["char_count"].as_i.should eq("json content".size)
    end

    it "shows empty message when no snapshots" do
      pid = 90012_i64
      create_snapshot_session_with_pid(pid)

      result = run_binary(["snapshot", "list", "--pid", pid.to_s])

      result[:status].should eq(0)
      result[:output].should contain("No snapshots")
    end

    it "supports --ledger-session-id" do
      pid = 90013_i64
      session_id = create_snapshot_session_with_pid(pid)
      GalaxyLedger::Database.save_snapshot(session_id, "By LSID", "content")

      result = run_binary(["snapshot", "list", "--ledger-session-id", session_id.to_s])

      result[:status].should eq(0)
      result[:output].should contain("By LSID")
    end
  end

  describe "snapshot view" do
    it "outputs snapshot content" do
      pid = 90020_i64
      session_id = create_snapshot_session_with_pid(pid)
      GalaxyLedger::Database.save_snapshot(session_id, "View test", "## The Content\n\nHere it is.")

      result = run_binary(["snapshot", "view", "--pid", pid.to_s, "1"])

      result[:status].should eq(0)
      result[:output].should contain("## The Content")
      result[:output].should contain("Here it is.")
    end

    it "outputs JSON with --json flag" do
      pid = 90021_i64
      session_id = create_snapshot_session_with_pid(pid)
      GalaxyLedger::Database.save_snapshot(session_id, "JSON view", "the body")

      result = run_binary(["snapshot", "view", "--pid", pid.to_s, "--json", "1"])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["snapshot"]["title"].as_s.should eq("JSON view")
      parsed["snapshot"]["content"].as_s.should eq("the body")
      parsed["snapshot"]["number"].as_i.should eq(1)
    end

    it "errors for non-existent snapshot number" do
      pid = 90022_i64
      create_snapshot_session_with_pid(pid)

      result = run_binary(["snapshot", "view", "--pid", pid.to_s, "99"])

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end

    it "supports --ledger-session-id" do
      pid = 90023_i64
      session_id = create_snapshot_session_with_pid(pid)
      GalaxyLedger::Database.save_snapshot(session_id, "LSID view", "lsid content")

      result = run_binary(["snapshot", "view", "--ledger-session-id", session_id.to_s, "1"])

      result[:status].should eq(0)
      result[:output].should contain("lsid content")
    end
  end

  describe "snapshot delete" do
    it "deletes a snapshot by number" do
      pid = 90030_i64
      session_id = create_snapshot_session_with_pid(pid)
      GalaxyLedger::Database.save_snapshot(session_id, "To delete", "content")

      result = run_binary(["snapshot", "delete", "--pid", pid.to_s, "1"])

      result[:status].should eq(0)
      result[:output].should contain("Snapshot #1 deleted")

      # Verify it's gone
      GalaxyLedger::Database.get_snapshot_by_number(session_id, 1).should be_nil
    end

    it "errors for non-existent snapshot number" do
      pid = 90031_i64
      create_snapshot_session_with_pid(pid)

      result = run_binary(["snapshot", "delete", "--pid", pid.to_s, "99"])

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end
  end

  describe "snapshot help" do
    it "shows snapshot help" do
      result = run_binary(["snapshot", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("Manage session snapshots")
      result[:output].should contain("create")
      result[:output].should contain("list")
      result[:output].should contain("view")
      result[:output].should contain("delete")
      result[:output].should contain("annotation")
    end

    it "shows snapshot create help" do
      result = run_binary(["snapshot", "create", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("--pid")
      result[:output].should contain("--title")
    end
  end

  describe "end-to-end snapshot workflow" do
    it "creates, lists, views, deletes, and verifies deletion" do
      pid = 90050_i64
      session_id = create_snapshot_session_with_pid(pid)

      # CREATE
      create_result = run_binary(
        ["snapshot", "create", "--pid", pid.to_s, "--title", "E2E Snapshot"],
        stdin: "## Full lifecycle test\n\nThis is the content.",
      )
      create_result[:status].should eq(0)
      create_result[:output].should contain("Snapshot #1 saved")

      # LIST
      list_result = run_binary(["snapshot", "list", "--pid", pid.to_s])
      list_result[:status].should eq(0)
      list_result[:output].should contain("E2E Snapshot")
      list_result[:output].should contain("1 total")

      # VIEW
      view_result = run_binary(["snapshot", "view", "--pid", pid.to_s, "1"])
      view_result[:status].should eq(0)
      view_result[:output].should contain("Full lifecycle test")

      # DELETE
      delete_result = run_binary(["snapshot", "delete", "--pid", pid.to_s, "1"])
      delete_result[:status].should eq(0)
      delete_result[:output].should contain("deleted")

      # VERIFY DELETION
      list_after = run_binary(["snapshot", "list", "--pid", pid.to_s])
      list_after[:output].should contain("No snapshots")
    end
  end
end
