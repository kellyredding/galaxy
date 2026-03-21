require "../spec_helper"

describe "CLI snapshot commands", tags: "integration" do
  describe "create" do
    it "creates a snapshot from stdin" do
      result = run_binary(
        ["create", "--ledger-session-id", "1", "--title", "Design discussion"],
        stdin: "## Exchange 1\n\n### User\nHello\n\n### Assistant\nHi there!",
      )

      result[:status].should eq(0)
      result[:output].should contain("Snapshot #1 saved")
      result[:output].should contain("Design discussion")

      # Verify DB record
      snapshot = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
      snapshot.should_not be_nil
      snapshot.not_nil!.title.should eq("Design discussion")
    end

    it "includes char count in output" do
      content = "Hello, world! This is test content."

      result = run_binary(
        ["create", "--ledger-session-id", "1", "--title", "Chars test"],
        stdin: content,
      )

      result[:status].should eq(0)
      result[:output].should contain("chars: #{content.size}")
    end

    it "supports --exchanges flag" do
      result = run_binary(
        ["create", "--ledger-session-id", "1", "--title", "Multi", "--exchanges", "3"],
        stdin: "content here",
      )

      result[:status].should eq(0)
      snapshot = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
      snapshot.not_nil!.exchange_count.should eq(3)
    end

    it "errors when --ledger-session-id and --pid are both missing" do
      result = run_binary(
        ["create", "--title", "No session"],
        stdin: "content",
      )

      result[:status].should_not eq(0)
      result[:error].should contain("--pid or --ledger-session-id is required")
    end

    it "errors when --title is missing" do
      result = run_binary(
        ["create", "--ledger-session-id", "1"],
        stdin: "content",
      )

      result[:status].should_not eq(0)
      result[:error].should contain("--title is required")
    end

    it "errors when stdin is empty" do
      result = run_binary(
        ["create", "--ledger-session-id", "1", "--title", "Empty"],
        stdin: "",
      )

      result[:status].should_not eq(0)
      result[:error].should contain("no content provided on stdin")
    end
  end

  describe "list" do
    it "lists snapshots in human-readable format" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "First snap", "content 1")
      GalaxySnapshots::Database.save_snapshot(1_i64, "Second snap", "content 2")
      flush_wal

      result = run_binary(["list", "--ledger-session-id", "1"])

      result[:status].should eq(0)
      result[:output].should contain("2 total")
      result[:output].should contain("#1")
      result[:output].should contain("First snap")
      result[:output].should contain("#2")
      result[:output].should contain("Second snap")
    end

    it "lists snapshots in JSON format" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "JSON test", "json content")
      flush_wal

      result = run_binary(["list", "--ledger-session-id", "1", "--json"])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      snapshots = parsed["snapshots"].as_a
      snapshots.size.should eq(1)
      snapshots[0]["number"].as_i.should eq(1)
      snapshots[0]["title"].as_s.should eq("JSON test")
      snapshots[0]["char_count"].as_i.should eq("json content".size)
    end

    it "shows empty message when no snapshots" do
      result = run_binary(["list", "--ledger-session-id", "1"])

      result[:status].should eq(0)
      result[:output].should contain("No snapshots")
    end

    it "includes content with --content --json" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "Content test", "the full body")
      flush_wal

      result = run_binary(["list", "--ledger-session-id", "1", "--json", "--content"])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      snapshots = parsed["snapshots"].as_a
      snapshots[0]["content"].as_s.should eq("the full body")
    end

    it "includes review_count in JSON output" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "Review count", "content")
      flush_wal

      result = run_binary(["list", "--ledger-session-id", "1", "--json"])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["snapshots"][0]["review_count"].as_i.should eq(0)
    end
  end

  describe "view" do
    it "outputs snapshot content" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "View test", "## The Content\n\nHere it is.")
      flush_wal

      result = run_binary(["view", "--ledger-session-id", "1", "1"])

      result[:status].should eq(0)
      result[:output].should contain("## The Content")
      result[:output].should contain("Here it is.")
    end

    it "outputs JSON with --json flag" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "JSON view", "the body")
      flush_wal

      result = run_binary(["view", "--ledger-session-id", "1", "--json", "1"])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["snapshot"]["title"].as_s.should eq("JSON view")
      parsed["snapshot"]["content"].as_s.should eq("the body")
      parsed["snapshot"]["number"].as_i.should eq(1)
    end

    it "errors for non-existent snapshot number" do
      result = run_binary(["view", "--ledger-session-id", "1", "99"])

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end
  end

  describe "delete" do
    it "deletes a snapshot by number" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "To delete", "content")
      flush_wal

      result = run_binary(["delete", "--ledger-session-id", "1", "1"])

      result[:status].should eq(0)
      result[:output].should contain("Snapshot #1 deleted")

      # Verify it's gone
      GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1).should be_nil
    end

    it "errors for non-existent snapshot number" do
      result = run_binary(["delete", "--ledger-session-id", "1", "99"])

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end
  end

  describe "stats" do
    it "returns JSON stats for a session" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "A", "hello")
      GalaxySnapshots::Database.save_snapshot(1_i64, "B", "world!!")
      flush_wal

      result = run_binary(["stats", "--ledger-session-id", "1"])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["count"].as_i.should eq(2)
      parsed["total_chars"].as_i.should eq(12)
    end

    it "returns zeros for empty session" do
      result = run_binary(["stats", "--ledger-session-id", "1"])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["count"].as_i.should eq(0)
      parsed["total_chars"].as_i.should eq(0)
    end
  end

  describe "help" do
    it "shows top-level help" do
      result = run_binary(["--help"])

      result[:status].should eq(0)
      result[:output].should contain("Manage session snapshots")
      result[:output].should contain("create")
      result[:output].should contain("list")
      result[:output].should contain("view")
      result[:output].should contain("delete")
      result[:output].should contain("annotation")
      result[:output].should contain("review")
    end

    it "shows create help" do
      result = run_binary(["create", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("--title")
      result[:output].should contain("--ledger-session-id")
    end
  end

  describe "version" do
    it "shows version" do
      result = run_binary(["version"])

      result[:status].should eq(0)
      result[:output].should contain("galaxy-snapshots")
    end
  end

  describe "end-to-end snapshot workflow" do
    it "creates, lists, views, deletes, and verifies deletion" do
      # CREATE
      create_result = run_binary(
        ["create", "--ledger-session-id", "1", "--title", "E2E Snapshot"],
        stdin: "## Full lifecycle test\n\nThis is the content.",
      )
      create_result[:status].should eq(0)
      create_result[:output].should contain("Snapshot #1 saved")

      # LIST
      list_result = run_binary(["list", "--ledger-session-id", "1"])
      list_result[:status].should eq(0)
      list_result[:output].should contain("E2E Snapshot")
      list_result[:output].should contain("1 total")

      # VIEW
      view_result = run_binary(["view", "--ledger-session-id", "1", "1"])
      view_result[:status].should eq(0)
      view_result[:output].should contain("Full lifecycle test")

      # DELETE
      delete_result = run_binary(["delete", "--ledger-session-id", "1", "1"])
      delete_result[:status].should eq(0)
      delete_result[:output].should contain("deleted")

      # VERIFY DELETION
      list_after = run_binary(["list", "--ledger-session-id", "1"])
      list_after[:output].should contain("No snapshots")
    end
  end
end
