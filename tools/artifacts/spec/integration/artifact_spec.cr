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

    it "errors when source-path is missing" do
      result = run_binary(["save", "--ledger-session-id", "1"])

      result[:status].should_not eq(0)
      result[:error].should contain("--source-path is required")
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
