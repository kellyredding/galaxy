require "../spec_helper"

# Helper to create a test session with PID mapping for artifact CLI tests.
def create_artifact_session_with_pid(pid : Int64) : Int64
  session_id = "art-cli-#{pid}"
  GalaxyLedger::Database.create_session(session_id, claude_pid: pid)
end

describe "CLI artifact commands", tags: "integration" do
  describe "artifact save" do
    it "saves an artifact from a source file" do
      pid = 88001_i64
      session_id = create_artifact_session_with_pid(pid)

      # Create a temp source file
      source = File.tempname("art-save-test", ".csv")
      File.write(source, "id,name\n1,alice\n2,bob")

      result = run_binary(
        ["artifact", "save", "--pid", pid.to_s, "--source-path", source, "--title", "Test Export"],
      )

      result[:status].should eq(0)
      result[:output].should contain("Artifact #1 saved")
      result[:output].should contain("Test Export")
      result[:output].should contain("csv")

      # Verify DB record
      artifact = GalaxyLedger::Database.get_artifact_by_number(session_id, 1)
      artifact.should_not be_nil
      artifact.not_nil!.title.should eq("Test Export")
      artifact.not_nil!.artifact_type.should eq("csv")

      File.delete(source) if File.exists?(source)
    end

    it "derives title from filename when not provided" do
      pid = 88002_i64
      session_id = create_artifact_session_with_pid(pid)

      source = File.tempname("quarterly-report", ".csv")
      File.write(source, "data")

      result = run_binary(
        ["artifact", "save", "--pid", pid.to_s, "--source-path", source],
      )

      result[:status].should eq(0)
      result[:output].should contain("Artifact #1 saved")

      File.delete(source) if File.exists?(source)
    end

    it "errors when source file does not exist" do
      pid = 88003_i64
      create_artifact_session_with_pid(pid)

      result = run_binary(
        ["artifact", "save", "--pid", pid.to_s, "--source-path", "/nonexistent/file.csv"],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("file not found")
    end

    it "errors when --pid is missing" do
      result = run_binary(["artifact", "save", "--source-path", "/tmp/test.csv"])

      result[:status].should_not eq(0)
      result[:error].should contain("--pid is required")
    end

    it "errors when --source-path is missing" do
      result = run_binary(["artifact", "save", "--pid", "12345"])

      result[:status].should_not eq(0)
      result[:error].should contain("--source-path is required")
    end
  end

  describe "artifact save dedup" do
    it "reports 'updated' when saving same source_path with same content" do
      pid = 88060_i64
      session_id = create_artifact_session_with_pid(pid)

      source = File.tempname("dedup-enrich", ".csv")
      File.write(source, "id,name\n1,alice")

      # First save
      r1 = run_binary(
        ["artifact", "save", "--pid", pid.to_s, "--source-path", source, "--title", "Short"],
      )
      r1[:status].should eq(0)
      r1[:output].should contain("Artifact #1 saved")

      # Second save — same file (unchanged), richer title
      r2 = run_binary(
        ["artifact", "save", "--pid", pid.to_s, "--source-path", source,
         "--title", "Detailed User Export Report",
         "--description", "Complete user data export"],
      )
      r2[:status].should eq(0)
      r2[:output].should contain("Artifact #1 updated")

      # Still only 1 artifact
      list_result = run_binary(["artifact", "list", "--pid", pid.to_s])
      list_result[:output].should contain("1 total")
      list_result[:output].should contain("Detailed User Export Report")

      File.delete(source) if File.exists?(source)
    end

    it "reports 'updated' when saving same source_path with new content" do
      pid = 88061_i64
      session_id = create_artifact_session_with_pid(pid)

      source = File.tempname("dedup-version", ".csv")
      File.write(source, "v1 data")

      # First save
      r1 = run_binary(
        ["artifact", "save", "--pid", pid.to_s, "--source-path", source, "--title", "Version Test"],
      )
      r1[:status].should eq(0)
      r1[:output].should contain("Artifact #1 saved")

      # Modify the file
      File.write(source, "v2 data with more content")

      # Second save — same path, different content
      r2 = run_binary(
        ["artifact", "save", "--pid", pid.to_s, "--source-path", source, "--title", "Version Test Updated"],
      )
      r2[:status].should eq(0)
      r2[:output].should contain("Artifact #1 updated")

      # Still only 1 artifact
      list_result = run_binary(["artifact", "list", "--pid", pid.to_s])
      list_result[:output].should contain("1 total")

      File.delete(source) if File.exists?(source)
    end

    it "creates separate artifacts for different source_paths" do
      pid = 88062_i64
      session_id = create_artifact_session_with_pid(pid)

      source_a = File.tempname("dedup-diff-a", ".csv")
      source_b = File.tempname("dedup-diff-b", ".csv")
      File.write(source_a, "data a")
      File.write(source_b, "data b")

      r1 = run_binary(
        ["artifact", "save", "--pid", pid.to_s, "--source-path", source_a, "--title", "File A"],
      )
      r2 = run_binary(
        ["artifact", "save", "--pid", pid.to_s, "--source-path", source_b, "--title", "File B"],
      )

      r1[:status].should eq(0)
      r2[:status].should eq(0)
      r1[:output].should contain("Artifact #1 saved")
      r2[:output].should contain("Artifact #2 saved")

      list_result = run_binary(["artifact", "list", "--pid", pid.to_s])
      list_result[:output].should contain("2 total")

      File.delete(source_a) if File.exists?(source_a)
      File.delete(source_b) if File.exists?(source_b)
    end
  end

  describe "artifact list" do
    it "lists artifacts for a session" do
      pid = 88010_i64
      session_id = create_artifact_session_with_pid(pid)

      # Create artifacts via DB directly
      GalaxyLedger::Database.save_artifact(session_id, title: "Report CSV", artifact_type: "csv", mime_type: "text/csv", original_filename: "report.csv", stored_path: "/a", source_path: "/a", file_size: 1024_i64, content_hash: "h1")
      GalaxyLedger::Database.save_artifact(session_id, title: "Diagram", artifact_type: "mermaid", mime_type: "text/x-mermaid", original_filename: "flow.mmd", stored_path: "/b", source_path: "/b", file_size: 512_i64, content_hash: "h2")

      result = run_binary(["artifact", "list", "--pid", pid.to_s])

      result[:status].should eq(0)
      result[:output].should contain("2 total")
      result[:output].should contain("Report CSV")
      result[:output].should contain("Diagram")
      result[:output].should contain("[csv]")
      result[:output].should contain("[mermaid]")
    end

    it "shows empty message when no artifacts" do
      pid = 88011_i64
      create_artifact_session_with_pid(pid)

      result = run_binary(["artifact", "list", "--pid", pid.to_s])

      result[:status].should eq(0)
      result[:output].should contain("No artifacts")
    end
  end

  describe "artifact view" do
    it "outputs text artifact content to stdout" do
      pid = 88020_i64
      session_id = create_artifact_session_with_pid(pid)

      # Store a real file
      content = "id,name,value\n1,foo,100\n2,bar,200"
      stored_path = GalaxyLedger::ArtifactStorage.store_content(
        session_id, 1, content, "data.csv",
      )

      GalaxyLedger::Database.save_artifact(session_id, title: "Data Export", artifact_type: "csv", mime_type: "text/csv", original_filename: "data.csv", stored_path: stored_path.not_nil!, source_path: "/tmp/data.csv", file_size: content.size.to_i64, content_hash: "hv")

      result = run_binary(["artifact", "view", "--pid", pid.to_s, "1"])

      result[:status].should eq(0)
      result[:output].should contain("id,name,value")
      result[:output].should contain("1,foo,100")

      # Cleanup stored file
      File.delete(stored_path.not_nil!) if stored_path && File.exists?(stored_path.not_nil!)
      session_dir = GalaxyLedger::ArtifactStorage::ARTIFACTS_DIR / session_id.to_s
      Dir.delete(session_dir) if Dir.exists?(session_dir) && Dir.empty?(session_dir)
    end

    it "rejects binary artifact types" do
      pid = 88021_i64
      session_id = create_artifact_session_with_pid(pid)

      # Create a stored file for a binary type
      session_dir = GalaxyLedger::ArtifactStorage::ARTIFACTS_DIR / session_id.to_s
      Dir.mkdir_p(session_dir)
      stored_file = (session_dir / "001_photo.png").to_s
      File.write(stored_file, "fake png data")

      GalaxyLedger::Database.save_artifact(session_id, title: "Photo", artifact_type: "image", mime_type: "image/png", original_filename: "photo.png", stored_path: stored_file, source_path: "/tmp/photo.png", file_size: 13_i64, content_hash: "himg")

      result = run_binary(["artifact", "view", "--pid", pid.to_s, "1"])

      result[:status].should_not eq(0)
      result[:error].should contain("binary")
      result[:error].should contain("artifact open")

      # Cleanup
      File.delete(stored_file) if File.exists?(stored_file)
      Dir.delete(session_dir) if Dir.exists?(session_dir) && Dir.empty?(session_dir)
    end

    it "errors for non-existent artifact" do
      pid = 88022_i64
      create_artifact_session_with_pid(pid)

      result = run_binary(["artifact", "view", "--pid", pid.to_s, "99"])

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end
  end

  describe "artifact delete" do
    it "deletes an artifact" do
      pid = 88030_i64
      session_id = create_artifact_session_with_pid(pid)

      # Create stored file
      session_dir = GalaxyLedger::ArtifactStorage::ARTIFACTS_DIR / session_id.to_s
      Dir.mkdir_p(session_dir)
      stored_file = (session_dir / "001_test.csv").to_s
      File.write(stored_file, "data")

      GalaxyLedger::Database.save_artifact(session_id, title: "To delete", artifact_type: "csv", mime_type: "text/csv", original_filename: "test.csv", stored_path: stored_file, source_path: "/tmp/test.csv", file_size: 4_i64, content_hash: "hd")

      result = run_binary(["artifact", "delete", "--pid", pid.to_s, "1"])

      result[:status].should eq(0)
      result[:output].should contain("Artifact #1 deleted")

      # Verify gone
      GalaxyLedger::Database.get_artifact_by_number(session_id, 1).should be_nil
      File.exists?(stored_file).should be_false
    end

    it "errors for non-existent artifact" do
      pid = 88031_i64
      create_artifact_session_with_pid(pid)

      result = run_binary(["artifact", "delete", "--pid", pid.to_s, "99"])

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end
  end

  describe "artifact help" do
    it "shows help with no args" do
      result = run_binary(["artifact"])

      result[:status].should eq(0)
      result[:output].should contain("Manage session artifacts")
      result[:output].should contain("save")
      result[:output].should contain("list")
      result[:output].should contain("view")
      result[:output].should contain("open")
      result[:output].should contain("delete")
    end

    it "shows help with --help" do
      result = run_binary(["artifact", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("Manage session artifacts")
    end

    it "shows save help" do
      result = run_binary(["artifact", "save", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("--source-path")
      result[:output].should contain("--pid")
    end

    it "shows list help" do
      result = run_binary(["artifact", "list", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("--pid")
    end
  end

  describe "end-to-end artifact workflow" do
    it "saves, lists, views, and deletes an artifact" do
      pid = 88050_i64
      session_id = create_artifact_session_with_pid(pid)

      # Create source file
      source = File.tempname("e2e-artifact", ".csv")
      File.write(source, "col1,col2\nval1,val2")

      # Save
      save_result = run_binary(
        ["artifact", "save", "--pid", pid.to_s, "--source-path", source, "--title", "E2E Test"],
      )
      save_result[:status].should eq(0)
      save_result[:output].should contain("Artifact #1")

      # List
      list_result = run_binary(["artifact", "list", "--pid", pid.to_s])
      list_result[:status].should eq(0)
      list_result[:output].should contain("E2E Test")
      list_result[:output].should contain("1 total")

      # View
      view_result = run_binary(["artifact", "view", "--pid", pid.to_s, "1"])
      view_result[:status].should eq(0)
      view_result[:output].should contain("col1,col2")
      view_result[:output].should contain("val1,val2")

      # Delete
      delete_result = run_binary(["artifact", "delete", "--pid", pid.to_s, "1"])
      delete_result[:status].should eq(0)
      delete_result[:output].should contain("deleted")

      # Verify gone
      list_after = run_binary(["artifact", "list", "--pid", pid.to_s])
      list_after[:output].should contain("No artifacts")

      File.delete(source) if File.exists?(source)
    end

    it "save → enrich → version update → view lifecycle" do
      pid = 88051_i64
      session_id = create_artifact_session_with_pid(pid)

      source = File.tempname("e2e-dedup", ".csv")
      File.write(source, "initial,data")

      # 1. First save — insert
      r1 = run_binary(
        ["artifact", "save", "--pid", pid.to_s, "--source-path", source, "--title", "Auto Title"],
      )
      r1[:status].should eq(0)
      r1[:output].should contain("saved")

      # 2. Same content, richer title — enrichment
      r2 = run_binary(
        ["artifact", "save", "--pid", pid.to_s, "--source-path", source,
         "--title", "Detailed Revenue Analysis Report",
         "--description", "Full Q4 breakdown"],
      )
      r2[:status].should eq(0)
      r2[:output].should contain("updated")

      # 3. Modify file content — version update
      File.write(source, "updated,data,with,more,columns")

      r3 = run_binary(
        ["artifact", "save", "--pid", pid.to_s, "--source-path", source,
         "--title", "Even More Detailed Revenue Analysis Report"],
      )
      r3[:status].should eq(0)
      r3[:output].should contain("updated")

      # Still only 1 artifact
      list_result = run_binary(["artifact", "list", "--pid", pid.to_s])
      list_result[:output].should contain("1 total")
      list_result[:output].should contain("Even More Detailed Revenue Analysis Report")

      # View should show the latest content
      view_result = run_binary(["artifact", "view", "--pid", pid.to_s, "1"])
      view_result[:status].should eq(0)
      view_result[:output].should contain("updated,data,with,more,columns")

      File.delete(source) if File.exists?(source)
    end
  end
end
