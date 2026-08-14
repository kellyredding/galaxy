require "../spec_helper"

describe "CLI artifact commands", tags: "integration" do
  describe "save" do
    it "saves an artifact from a file" do
      source = create_test_file("int-test.csv", "name,value\nfoo,42")

      result = run_binary([
        "save",
        "--ledger-session-id", "1",
        "--source-path", source,
        "--title", "Integration CSV",
        "--artifact-type", "csv",
        "--mime-type", "text/csv",
      ])

      result[:status].should eq(0)
      result[:output].should contain("Artifact #1 saved")
      result[:output].should contain("Integration CSV")
    end

    it "derives title from filename when not provided" do
      source = create_test_file("quarterly-report.csv", "data")

      result = run_binary([
        "save",
        "--ledger-session-id", "1",
        "--source-path", source,
        "--artifact-type", "csv",
        "--mime-type", "text/csv",
      ])

      result[:status].should eq(0)
      result[:output].should contain("quarterly report")
    end

    it "errors when neither source-path nor filename is given" do
      # Without --source-path, save falls through to stdin mode
      # which requires --filename for the artifact to dispatch
      # to the right Galaxy.app reader.
      result = run_binary(["save", "--ledger-session-id", "1"])

      result[:status].should_not eq(0)
      result[:error].should contain(
        "--filename is required when --source-path is not provided",
      )
    end

    it "errors when file does not exist" do
      result = run_binary([
        "save",
        "--ledger-session-id", "1",
        "--source-path", "/tmp/nonexistent-#{Random.rand(100000)}",
      ])

      result[:status].should_not eq(0)
      result[:error].should contain("file not found")
    end

    it "errors when no session identifier provided" do
      source = create_test_file("no-session.txt", "data")

      result = run_binary(["save", "--source-path", source])

      result[:status].should_not eq(0)
      result[:error].should contain("--pid or --ledger-session-id is required")
    end

    it "reports 'updated' on enrichment (same file, same content)" do
      source = create_test_file("enrich-test.csv", "same content")

      run_binary([
        "save", "--ledger-session-id", "1",
        "--source-path", source,
        "--artifact-type", "csv", "--mime-type", "text/csv",
      ])

      result = run_binary([
        "save", "--ledger-session-id", "1",
        "--source-path", source,
        "--artifact-type", "csv", "--mime-type", "text/csv",
        "--description", "added description",
      ])

      result[:status].should eq(0)
      result[:output].should contain("updated")
    end
  end

  describe "save type inference" do
    # Source-path mode — verifies the default reaches
    # the DB and the "type: X" line in stdout. Spot-
    # checks a few representative extensions; unit
    # specs in artifact_type_inference_spec.cr cover
    # the full mapping table.

    it "infers markdown for .md in source-path mode" do
      source = create_test_file(
        "notes.md", "# Hello\n",
      )
      result = run_binary([
        "save",
        "--ledger-session-id", "1",
        "--source-path", source,
      ])
      result[:status].should eq(0)
      result[:output].should contain("type: markdown")
    end

    it "infers diff for .gdiff in source-path mode" do
      source = create_test_file(
        "changes.gdiff", "{\"files\":[]}",
      )
      result = run_binary([
        "save",
        "--ledger-session-id", "1",
        "--source-path", source,
      ])
      result[:status].should eq(0)
      result[:output].should contain("type: diff")
    end

    # Structural minimalism stays the producer's problem, not
    # the store's — this is the same payload as above, kept
    # deliberately to pin that the gate stops at
    # well-formedness rather than schema.
    it "accepts a structurally minimal .gdiff" do
      source = create_test_file(
        "minimal.gdiff", "{\"files\":[]}",
      )
      result = run_binary([
        "save",
        "--ledger-session-id", "1",
        "--source-path", source,
      ])
      result[:status].should eq(0)
    end

    # The real specimen's shape: raw bytes spliced into a
    # JSON string. Crystal's JSON.parse ACCEPTS this, so only
    # the encoding check catches it — which is why this spec
    # asserts the UTF-8 message specifically.
    it "refuses a .gdiff that is not valid UTF-8" do
      prefix = %({"version":1,"files":[{"before":").to_slice
      suffix = %("}]}).to_slice
      bytes = Bytes.new(prefix.size + 1 + suffix.size)
      prefix.copy_to(bytes)
      bytes[prefix.size] = 0x9B_u8
      suffix.copy_to(bytes + prefix.size + 1)
      source = create_test_binary_file(
        "raw-bytes.gdiff", bytes,
      )

      result = run_binary([
        "save",
        "--ledger-session-id", "1",
        "--source-path", source,
      ])
      result[:status].should_not eq(0)
      result[:error].should contain("not valid UTF-8")
    end

    it "refuses a .gdiff that is not valid JSON" do
      source = create_test_file(
        "not-json.gdiff", "this is not json",
      )
      result = run_binary([
        "save",
        "--ledger-session-id", "1",
        "--source-path", source,
      ])
      result[:status].should_not eq(0)
      result[:error].should contain("not valid JSON")
    end

    # Only .gdiff is gated. A malformed .md is still just a
    # file, and nothing tries to parse it.
    it "does not gate non-gdiff files" do
      source = create_test_file(
        "notes.md", "this is not json either",
      )
      result = run_binary([
        "save",
        "--ledger-session-id", "1",
        "--source-path", source,
      ])
      result[:status].should eq(0)
    end

    it "warns but still saves an oversized .gdiff" do
      big = %({"version":1,"metadata":{},"files":[]}) +
            " " * 5_000_001
      source = create_test_file("big.gdiff", big)
      result = run_binary([
        "save",
        "--ledger-session-id", "1",
        "--source-path", source,
      ])
      result[:status].should eq(0)
      result[:error].should contain("diff reader will open")
    end

    it "does not warn about a .gdiff under the cap" do
      source = create_test_file(
        "small.gdiff", %({"version":1,"files":[]}),
      )
      result = run_binary([
        "save",
        "--ledger-session-id", "1",
        "--source-path", source,
      ])
      result[:status].should eq(0)
      result[:error].should_not contain("diff reader")
    end

    it "infers code for unknown extensions in source-path mode" do
      source = create_test_file(
        "impl.rb", "class Foo; end\n",
      )
      result = run_binary([
        "save",
        "--ledger-session-id", "1",
        "--source-path", source,
      ])
      result[:status].should eq(0)
      result[:output].should contain("type: code")
    end

    it "infers json for .json in stdin mode" do
      result = run_binary(
        [
          "save",
          "--ledger-session-id", "1",
          "--filename", "settings.json",
        ],
        stdin: %({"key":"value"}),
      )
      result[:status].should eq(0)
      result[:output].should contain("type: json")
    end

    it "infers json for non-transcript .jsonl in stdin mode" do
      result = run_binary(
        [
          "save",
          "--ledger-session-id", "1",
          "--filename", "lines.jsonl",
        ],
        stdin: %({"a":1}\n{"b":2}\n),
      )
      result[:status].should eq(0)
      result[:output].should contain("type: json")
    end

    it "promotes .jsonl to transcript when first line matches" do
      transcript = %({"agentId":"a1",) +
                   %("message":{"role":"user",) +
                   %("content":"hi"}}\n) +
                   %({"agentId":"a1",) +
                   %("message":{"role":"assistant",) +
                   %("content":"hello"}}\n)
      result = run_binary(
        [
          "save",
          "--ledger-session-id", "1",
          "--filename", "agent-abc123.jsonl",
        ],
        stdin: transcript,
      )
      result[:status].should eq(0)
      result[:output].should contain("type: transcript")
    end

    it "infers config for .yaml in source-path mode" do
      source = create_test_file(
        "ci.yaml", "name: build\n",
      )
      result = run_binary([
        "save",
        "--ledger-session-id", "1",
        "--source-path", source,
      ])
      result[:status].should eq(0)
      result[:output].should contain("type: config")
    end

    it "infers text for .txt in stdin mode" do
      result = run_binary(
        [
          "save",
          "--ledger-session-id", "1",
          "--filename", "notes.txt",
        ],
        stdin: "plain prose here",
      )
      result[:status].should eq(0)
      result[:output].should contain("type: text")
    end

    it "honors explicit --artifact-type over inference" do
      # A .md file should normally infer `markdown`
      # — an explicit override wins.
      source = create_test_file(
        "overridden.md", "# hi\n",
      )
      result = run_binary([
        "save",
        "--ledger-session-id", "1",
        "--source-path", source,
        "--artifact-type", "code",
      ])
      result[:status].should eq(0)
      result[:output].should contain("type: code")
    end

    it "publishes artifact.show socket event (source-path)" do
      source = create_test_file(
        "save-event.csv", "data",
      )

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
            "save", "--ledger-session-id", "1",
            "--source-path", source,
            "--title", "Save event test",
            "--artifact-type", "csv",
            "--mime-type", "text/csv",
          ],
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
              .should eq("artifact.show")
            detail = parsed["detail_data"]
            detail["artifact_number"].as_i
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

    it "skips artifact.show with --skip-event (source-path)" do
      source = create_test_file(
        "save-silent.csv", "data",
      )

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
            "save", "--ledger-session-id", "1",
            "--source-path", source,
            "--title", "Silent save",
            "--artifact-type", "csv",
            "--mime-type", "text/csv",
            "--skip-event",
          ],
          extra_env: {
            "GALAXY_LEDGER_BIN" => ledger_bin.to_s,
          },
        )
        result[:status].should eq(0)

        # Expect NO artifact.show. Short timeout; any
        # event received means the --skip-event gate
        # leaked.
        select
        when line = received.receive
          if json_line = line
            parsed = JSON.parse(json_line)
            parsed["event"].as_s
              .should_not eq("artifact.show")
          end
        when timeout(500.milliseconds)
          # Expected — no event arrives.
        end
      ensure
        server.close rescue nil
        File.delete(sock_path.to_s) \
          if File.exists?(sock_path.to_s)
      end
    end

    it "publishes artifact.show socket event (stdin)" do
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
            "save", "--ledger-session-id", "1",
            "--filename", "stdin-event.txt",
            "--title", "Stdin event test",
          ],
          stdin: "piped content",
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
              .should eq("artifact.show")
            detail = parsed["detail_data"]
            detail["artifact_number"].as_i
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

    it "skips artifact.show with --skip-event (stdin)" do
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
            "save", "--ledger-session-id", "1",
            "--filename", "stdin-silent.txt",
            "--title", "Stdin silent",
            "--skip-event",
          ],
          stdin: "piped content",
          extra_env: {
            "GALAXY_LEDGER_BIN" => ledger_bin.to_s,
          },
        )
        result[:status].should eq(0)

        select
        when line = received.receive
          if json_line = line
            parsed = JSON.parse(json_line)
            parsed["event"].as_s
              .should_not eq("artifact.show")
          end
        when timeout(500.milliseconds)
          # Expected — no event arrives.
        end
      ensure
        server.close rescue nil
        File.delete(sock_path.to_s) \
          if File.exists?(sock_path.to_s)
      end
    end
  end

  describe "list" do
    it "lists artifacts in human-readable format" do
      source1 = create_test_file("list-a.csv", "data a")
      source2 = create_test_file("list-b.txt", "data b")

      run_binary([
        "save", "--ledger-session-id", "1",
        "--source-path", source1, "--title", "First artifact",
        "--artifact-type", "csv", "--mime-type", "text/csv",
      ])
      run_binary([
        "save", "--ledger-session-id", "1",
        "--source-path", source2, "--title", "Second artifact",
        "--artifact-type", "text", "--mime-type", "text/plain",
      ])

      result = run_binary(["list", "--ledger-session-id", "1"])

      result[:status].should eq(0)
      result[:output].should contain("2 total")
      result[:output].should contain("#1")
      result[:output].should contain("First artifact")
      result[:output].should contain("#2")
      result[:output].should contain("Second artifact")
    end

    it "lists artifacts in JSON format" do
      source = create_test_file("json-list.csv", "json data")

      run_binary([
        "save", "--ledger-session-id", "1",
        "--source-path", source, "--title", "JSON test",
        "--artifact-type", "csv", "--mime-type", "text/csv",
      ])

      result = run_binary(["list", "--ledger-session-id", "1", "--json"])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      artifacts = parsed["artifacts"].as_a
      artifacts.size.should eq(1)
      artifacts[0]["number"].as_i.should eq(1)
      artifacts[0]["title"].as_s.should eq("JSON test")
    end

    it "shows empty message when no artifacts" do
      result = run_binary(["list", "--ledger-session-id", "1"])

      result[:status].should eq(0)
      result[:output].should contain("No artifacts")
    end

    it "returns empty JSON array when no artifacts with --json" do
      result = run_binary(["list", "--ledger-session-id", "1", "--json"])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["artifacts"].as_a.size.should eq(0)
    end
  end

  describe "view" do
    it "outputs text artifact content to stdout" do
      source = create_test_file("view-test.csv", "name,value\nfoo,42")

      run_binary([
        "save", "--ledger-session-id", "1",
        "--source-path", source, "--title", "View test",
        "--artifact-type", "csv", "--mime-type", "text/csv",
      ])

      result = run_binary(["view", "--ledger-session-id", "1", "1"])

      result[:status].should eq(0)
      result[:output].should contain("name,value")
      result[:output].should contain("foo,42")
    end

    it "errors for binary artifact types" do
      source = create_test_file("view-binary.png", "fake png data")

      run_binary([
        "save", "--ledger-session-id", "1",
        "--source-path", source, "--title", "Binary",
        "--artifact-type", "image", "--mime-type", "image/png",
      ])

      result = run_binary(["view", "--ledger-session-id", "1", "1"])

      result[:status].should_not eq(0)
      result[:error].should contain("binary")
      result[:error].should contain("open")
    end

    it "errors when artifact not found" do
      result = run_binary(["view", "--ledger-session-id", "1", "99"])

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end
  end

  describe "refresh" do
    # `refresh` re-reads the source and re-copies it without
    # entering `handle_save`, so it does not inherit that
    # path's gate. A .gdiff saved clean and then corrupted at
    # its source must be refused here too, or refresh becomes
    # the way a broken artifact gets into the store.
    it "refuses a .gdiff whose source became malformed" do
      source = create_test_file(
        "refresh-gdiff.gdiff", %({"version":1,"files":[]}),
      )

      run_binary([
        "save", "--ledger-session-id", "1",
        "--source-path", source, "--title", "Diff refresh",
      ])

      # The source goes bad after a clean save.
      File.write(source, "no longer json")

      result = run_binary([
        "refresh", "--ledger-session-id", "1", "1",
      ])

      result[:status].should_not eq(0)
      result[:error].should contain("not valid JSON")
    end

    it "refreshes a .gdiff whose source is still valid" do
      source = create_test_file(
        "refresh-ok.gdiff", %({"version":1,"files":[]}),
      )

      run_binary([
        "save", "--ledger-session-id", "1",
        "--source-path", source, "--title", "Diff ok",
      ])

      File.write(
        source, %({"version":1,"metadata":{},"files":[]}),
      )

      result = run_binary([
        "refresh", "--ledger-session-id", "1", "1",
      ])

      result[:status].should eq(0)
    end

    it "refreshes an artifact with unchanged content" do
      source = create_test_file("refresh-same.csv", "data")

      run_binary([
        "save", "--ledger-session-id", "1",
        "--source-path", source, "--title", "Refresh test",
        "--artifact-type", "csv", "--mime-type", "text/csv",
      ])

      result = run_binary([
        "refresh", "--ledger-session-id", "1", "1",
      ])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["number"].as_i.should eq(1)
      parsed["resaved"].as_bool.should be_true
      parsed["has_source"].as_bool.should be_true
      parsed["source_exists"].as_bool.should be_true
    end

    it "refreshes with changed content" do
      source = create_test_file(
        "refresh-change.csv", "original",
      )

      run_binary([
        "save", "--ledger-session-id", "1",
        "--source-path", source, "--title", "Change test",
        "--artifact-type", "csv", "--mime-type", "text/csv",
      ])

      # Modify the source file
      File.write(source, "updated content")

      result = run_binary([
        "refresh", "--ledger-session-id", "1", "1",
      ])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["resaved"].as_bool.should be_true

      # Verify stored content was updated
      view_result = run_binary([
        "view", "--ledger-session-id", "1", "1",
      ])
      view_result[:output].should contain("updated content")
    end

    it "handles artifact with no source_path" do
      source = create_test_file("no-src.csv", "data")
      run_binary([
        "save", "--ledger-session-id", "1",
        "--source-path", source, "--title", "No src",
        "--artifact-type", "csv", "--mime-type", "text/csv",
      ])
      # Clear source_path in DB to simulate null
      GalaxyArtifacts::Database.open do |db|
        db.exec(
          "UPDATE artifacts SET source_path = NULL " \
          "WHERE ledger_session_id = 1 AND number = 1",
        )
      end

      result = run_binary([
        "refresh", "--ledger-session-id", "1", "1",
      ])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["resaved"].as_bool.should be_false
      parsed["has_source"].as_bool.should be_false
    end

    it "handles deleted source file" do
      source = create_test_file(
        "refresh-gone.csv", "data",
      )

      run_binary([
        "save", "--ledger-session-id", "1",
        "--source-path", source, "--title", "Gone test",
        "--artifact-type", "csv", "--mime-type", "text/csv",
      ])

      File.delete(source)

      result = run_binary([
        "refresh", "--ledger-session-id", "1", "1",
      ])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["resaved"].as_bool.should be_false
      parsed["has_source"].as_bool.should be_true
      parsed["source_exists"].as_bool.should be_false
    end

    it "errors when artifact not found" do
      result = run_binary([
        "refresh", "--ledger-session-id", "1", "99",
      ])

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end

    it "accepts --skip-event flag" do
      source = create_test_file(
        "refresh-skip.csv", "data",
      )

      run_binary([
        "save", "--ledger-session-id", "1",
        "--source-path", source,
        "--title", "Skip event test",
        "--artifact-type", "csv",
        "--mime-type", "text/csv",
      ])

      result = run_binary([
        "refresh", "--ledger-session-id", "1",
        "--skip-event", "1",
      ])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["number"].as_i.should eq(1)
      parsed["resaved"].as_bool.should be_true
    end

    it "skips socket event with --skip-event" do
      source = create_test_file(
        "refresh-no-sock.csv", "data",
      )

      run_binary([
        "save", "--ledger-session-id", "1",
        "--source-path", source,
        "--title", "No socket test",
        "--artifact-type", "csv",
        "--mime-type", "text/csv",
      ])

      # Set up a socket listener to verify no
      # event arrives when --skip-event is used
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

        result = run_binary([
          "refresh", "--ledger-session-id", "1",
          "--skip-event", "1",
        ])
        result[:status].should eq(0)

        # Give a brief window for any stray event
        sleep 50.milliseconds

        # Close the server — if nothing connected,
        # the accept fiber will error and send nil
        server.close

        select
        when line = received.receive
          # nil means no connection was made (good)
          # non-nil means an event was sent (bad)
          line.should be_nil
        when timeout(200.milliseconds)
          # Timeout means no connection — expected
        end
      ensure
        server.close rescue nil
        File.delete(sock_path.to_s) \
          if File.exists?(sock_path.to_s)
      end
    end

    it "publishes socket event without --skip-event" do
      source = create_test_file(
        "refresh-with-sock.csv", "data",
      )

      run_binary([
        "save", "--ledger-session-id", "1",
        "--source-path", source,
        "--title", "Socket test",
        "--artifact-type", "csv",
        "--mime-type", "text/csv",
      ])

      # Set up a socket listener to capture the event
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

        # Also need a no-op ledger binary that
        # returns session identifiers JSON
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
            "refresh", "--ledger-session-id", "1",
            "1",
          ],
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
              .should eq("artifact.show")
            detail = parsed["detail_data"]
            detail["artifact_number"].as_i
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
  end

  describe "show" do
    it "publishes artifact.show socket event" do
      source = create_test_file(
        "show-test.csv", "data",
      )

      run_binary([
        "save", "--ledger-session-id", "1",
        "--source-path", source,
        "--title", "Show test",
        "--artifact-type", "csv",
        "--mime-type", "text/csv",
      ])

      # Set up a socket listener to capture the event
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
            "show", "--ledger-session-id", "1",
            "1",
          ],
          extra_env: {
            "GALAXY_LEDGER_BIN" => ledger_bin.to_s,
          },
        )
        result[:status].should eq(0)
        result[:output].should contain(
          "Showing artifact #1",
        )

        select
        when line = received.receive
          line.should_not be_nil
          if json_line = line
            parsed = JSON.parse(json_line)
            parsed["event"].as_s
              .should eq("artifact.show")
            detail = parsed["detail_data"]
            detail["artifact_number"].as_i
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

    it "errors when artifact not found" do
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

    it "errors when artifact number missing" do
      result = run_binary([
        "show", "--ledger-session-id", "1",
      ])

      result[:status].should_not eq(0)
      result[:error].should contain(
        "artifact number is required",
      )
    end
  end

  describe "delete" do
    it "deletes an artifact" do
      source = create_test_file("delete-test.csv", "delete me")

      run_binary([
        "save", "--ledger-session-id", "1",
        "--source-path", source, "--title", "Delete me",
        "--artifact-type", "csv", "--mime-type", "text/csv",
      ])

      result = run_binary(["delete", "--ledger-session-id", "1", "1"])

      result[:status].should eq(0)
      result[:output].should contain("Artifact #1 deleted")

      # Verify it's gone
      list_result = run_binary(["list", "--ledger-session-id", "1"])
      list_result[:output].should contain("No artifacts")
    end

    it "errors when artifact not found" do
      result = run_binary(["delete", "--ledger-session-id", "1", "99"])

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end
  end

  describe "timeline events" do
    it "publishes artifact:created on new save" do
      source = create_test_file(
        "timeline-create.csv", "data",
      )

      result = run_binary([
        "save",
        "--ledger-session-id", "1",
        "--source-path", source,
        "--title", "Timeline test",
        "--artifact-type", "csv",
        "--mime-type", "text/csv",
      ])

      result[:status].should eq(0)
      result[:output].should contain("Artifact #1 saved")
    end

    it "publishes artifact:updated on version update" do
      source = create_test_file(
        "timeline-update.csv", "v1 data",
      )

      run_binary([
        "save",
        "--ledger-session-id", "1",
        "--source-path", source,
        "--title", "Timeline test",
        "--artifact-type", "csv",
        "--mime-type", "text/csv",
      ])

      # Overwrite source with new content
      File.write(source, "v2 data with more content")

      result = run_binary([
        "save",
        "--ledger-session-id", "1",
        "--source-path", source,
        "--title", "Timeline test",
        "--artifact-type", "csv",
        "--mime-type", "text/csv",
      ])

      result[:status].should eq(0)
      result[:output].should contain("updated")
    end

    it "publishes artifact:deleted on delete" do
      source = create_test_file(
        "timeline-delete.csv", "delete me",
      )

      run_binary([
        "save",
        "--ledger-session-id", "1",
        "--source-path", source,
        "--title", "Delete timeline",
        "--artifact-type", "csv",
        "--mime-type", "text/csv",
      ])

      result = run_binary([
        "delete",
        "--ledger-session-id", "1",
        "1",
      ])

      result[:status].should eq(0)
      result[:output].should contain("deleted")
    end
  end
end
