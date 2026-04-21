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

    it "succeeds even when galaxy-timeline is unavailable" do
      # The fire-and-forget timeline recording should not affect
      # snapshot creation when the binary is not in PATH.
      result = run_binary(
        ["create", "--ledger-session-id", "1", "--title", "Timeline test"],
        stdin: "## Test\n\nTimeline integration content",
      )

      result[:status].should eq(0)
      result[:output].should contain("Snapshot #1 saved")
      result[:output].should contain("Timeline test")

      snapshot = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
      snapshot.should_not be_nil
      snapshot.not_nil!.title.should eq("Timeline test")
    end

    it "publishes snapshot.show socket event by default" do
      sock_path = SPEC_GALAXY_DIR / "galaxy.sock"
      received = Channel(String?).new(1)

      server = UNIXServer.new(sock_path.to_s)
      spawn do
        begin
          client = server.accept
          line = client.gets
          received.send(line)
          client.close
        rescue
          received.send(nil)
        end
      end

      begin
        sleep 10.milliseconds

        ledger_bin = SPEC_GALAXY_DIR / "bin" /
                     "galaxy-ledger"
        File.write(
          ledger_bin,
          "#!/bin/sh\n" \
          "echo '{\"session_identifiers\":[]}'\n",
        )
        File.chmod(ledger_bin, 0o755)

        result = run_binary(
          [
            "create", "--ledger-session-id", "1",
            "--title", "Event test",
          ],
          stdin: "content",
          extra_env: {
            "GALAXY_LEDGER_BIN" => ledger_bin.to_s,
          },
        )
        result[:status].should eq(0)

        select
        when line = received.receive
          line.should_not be_nil
          if json_line = line
            parsed = JSON.parse(json_line)
            parsed["event"].as_s
              .should eq("snapshot.show")
            detail = parsed["detail_data"]
            detail["snapshot_number"].as_i
              .should eq(1)
          end
        when timeout(2.seconds)
          fail "Timed out waiting for socket event"
        end
      ensure
        server.close rescue nil
        File.delete(sock_path.to_s) \
          if File.exists?(sock_path.to_s)
      end
    end

    it "skips socket event with --skip-event" do
      sock_path = SPEC_GALAXY_DIR / "galaxy.sock"
      received = Channel(String?).new(1)

      server = UNIXServer.new(sock_path.to_s)
      spawn do
        begin
          client = server.accept
          line = client.gets
          received.send(line)
          client.close
        rescue
          received.send(nil)
        end
      end

      begin
        sleep 10.milliseconds

        ledger_bin = SPEC_GALAXY_DIR / "bin" /
                     "galaxy-ledger"
        File.write(
          ledger_bin,
          "#!/bin/sh\n" \
          "echo '{\"session_identifiers\":[]}'\n",
        )
        File.chmod(ledger_bin, 0o755)

        result = run_binary(
          [
            "create", "--ledger-session-id", "1",
            "--title", "Silent save",
            "--skip-event",
          ],
          stdin: "content",
          extra_env: {
            "GALAXY_LEDGER_BIN" => ledger_bin.to_s,
          },
        )
        result[:status].should eq(0)

        # Expect NO snapshot.show event to arrive.
        # Short timeout keeps the spec fast while
        # being long enough to catch a stray publish.
        select
        when line = received.receive
          if json_line = line
            parsed = JSON.parse(json_line)
            parsed["event"].as_s
              .should_not eq("snapshot.show")
          end
        when timeout(500.milliseconds)
          # Expected path: nothing arrives.
        end
      ensure
        server.close rescue nil
        File.delete(sock_path.to_s) \
          if File.exists?(sock_path.to_s)
      end
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

  describe "show" do
    it "publishes snapshot.show socket event" do
      GalaxySnapshots::Database.save_snapshot(
        1_i64, "Show target", "content here",
      )
      flush_wal

      sock_path = SPEC_GALAXY_DIR / "galaxy.sock"
      received = Channel(String?).new(1)

      server = UNIXServer.new(sock_path.to_s)
      spawn do
        begin
          client = server.accept
          line = client.gets
          received.send(line)
          client.close
        rescue
          received.send(nil)
        end
      end

      begin
        sleep 10.milliseconds

        ledger_bin = SPEC_GALAXY_DIR / "bin" /
                     "galaxy-ledger"
        File.write(
          ledger_bin,
          "#!/bin/sh\n" \
          "echo '{\"session_identifiers\":[]}'\n",
        )
        File.chmod(ledger_bin, 0o755)

        result = run_binary(
          [
            "show", "--ledger-session-id", "1", "1",
          ],
          extra_env: {
            "GALAXY_LEDGER_BIN" => ledger_bin.to_s,
          },
        )
        result[:status].should eq(0)
        result[:output].should contain(
          "Showing snapshot #1",
        )

        select
        when line = received.receive
          line.should_not be_nil
          if json_line = line
            parsed = JSON.parse(json_line)
            parsed["event"].as_s
              .should eq("snapshot.show")
            detail = parsed["detail_data"]
            detail["snapshot_number"].as_i
              .should eq(1)
          end
        when timeout(2.seconds)
          fail "Timed out waiting for socket event"
        end
      ensure
        server.close rescue nil
        File.delete(sock_path.to_s) \
          if File.exists?(sock_path.to_s)
      end
    end

    it "errors when snapshot not found" do
      result = run_binary([
        "show", "--ledger-session-id", "1", "99",
      ])

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end

    it "errors when no session identifier provided" do
      result = run_binary(["show", "1"])

      result[:status].should_not eq(0)
      result[:error].should contain(
        "--pid or --ledger-session-id is required",
      )
    end

    it "errors when snapshot number missing" do
      result = run_binary([
        "show", "--ledger-session-id", "1",
      ])

      result[:status].should_not eq(0)
      result[:error].should contain(
        "snapshot number is required",
      )
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
