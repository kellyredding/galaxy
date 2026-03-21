require "../spec_helper"

# Helper to create a snapshot and return its DB primary key ID.
def create_snapshot_for_annotation_cli : Int64
  GalaxySnapshots::Database.save_snapshot(1_i64, "Test snapshot", "Line 1\nLine 2\nLine 3\nLine 4\nLine 5")
  snapshot = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
  flush_wal
  snapshot.not_nil!.id
end

describe "CLI snapshot annotation commands", tags: "integration" do
  describe "annotation create" do
    it "creates an annotation from stdin" do
      snapshot_id = create_snapshot_for_annotation_cli

      result = run_binary(
        ["annotation", "create",
         "--snapshot-id", snapshot_id.to_s,
         "--start-line", "1", "--end-line", "3"],
        stdin: "Important design decision",
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      ann = parsed["annotation"]
      ann["number"].as_i.should eq(1)
      ann["start_line"].as_i.should eq(1)
      ann["end_line"].as_i.should eq(3)
      ann["content"].as_s.should eq("Important design decision")
      ann["snapshot_id"].as_i64.should eq(snapshot_id)

      # Verify DB record
      db_ann = GalaxySnapshots::Database.get_snapshot_annotation(snapshot_id, 1)
      db_ann.should_not be_nil
      db_ann.not_nil!.content.should eq("Important design decision")
    end

    it "auto-assigns sequential numbers" do
      snapshot_id = create_snapshot_for_annotation_cli

      r1 = run_binary(
        ["annotation", "create",
         "--snapshot-id", snapshot_id.to_s,
         "--start-line", "1", "--end-line", "1"],
        stdin: "First",
      )
      r2 = run_binary(
        ["annotation", "create",
         "--snapshot-id", snapshot_id.to_s,
         "--start-line", "2", "--end-line", "2"],
        stdin: "Second",
      )

      r1[:status].should eq(0)
      r2[:status].should eq(0)
      JSON.parse(r1[:output])["annotation"]["number"].as_i.should eq(1)
      JSON.parse(r2[:output])["annotation"]["number"].as_i.should eq(2)
    end

    it "errors when --snapshot-id is missing" do
      result = run_binary(
        ["annotation", "create",
         "--start-line", "1", "--end-line", "3"],
        stdin: "content",
      )

      result[:status].should_not eq(0)
      result[:error].should contain("--snapshot-id")
    end

    it "errors when --start-line is missing" do
      snapshot_id = create_snapshot_for_annotation_cli

      result = run_binary(
        ["annotation", "create",
         "--snapshot-id", snapshot_id.to_s,
         "--end-line", "3"],
        stdin: "content",
      )

      result[:status].should_not eq(0)
      result[:error].should contain("--start-line is required")
    end

    it "errors when --end-line is missing" do
      snapshot_id = create_snapshot_for_annotation_cli

      result = run_binary(
        ["annotation", "create",
         "--snapshot-id", snapshot_id.to_s,
         "--start-line", "1"],
        stdin: "content",
      )

      result[:status].should_not eq(0)
      result[:error].should contain("--end-line is required")
    end

    it "errors when stdin is empty" do
      snapshot_id = create_snapshot_for_annotation_cli

      result = run_binary(
        ["annotation", "create",
         "--snapshot-id", snapshot_id.to_s,
         "--start-line", "1", "--end-line", "3"],
        stdin: "",
      )

      result[:status].should_not eq(0)
      result[:error].should contain("no content provided on stdin")
    end
  end

  describe "annotation list" do
    it "lists annotations in human-readable format" do
      snapshot_id = create_snapshot_for_annotation_cli
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 3, "First annotation")
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 4, 5, "Second annotation")
      flush_wal

      result = run_binary(
        ["annotation", "list", "--snapshot-id", snapshot_id.to_s],
      )

      result[:status].should eq(0)
      result[:output].should contain("2 total")
      result[:output].should contain("#1")
      result[:output].should contain("lines 1-3")
      result[:output].should contain("First annotation")
      result[:output].should contain("#2")
      result[:output].should contain("lines 4-5")
    end

    it "lists annotations in JSON format" do
      snapshot_id = create_snapshot_for_annotation_cli
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 1, "JSON test")
      flush_wal

      result = run_binary(
        ["annotation", "list",
         "--snapshot-id", snapshot_id.to_s, "--json"],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      annotations = parsed["annotations"].as_a
      annotations.size.should eq(1)
      annotations[0]["number"].as_i.should eq(1)
      annotations[0]["content"].as_s.should eq("JSON test")
      annotations[0]["start_line"].as_i.should eq(1)
      annotations[0]["end_line"].as_i.should eq(1)
    end

    it "shows empty message when no annotations" do
      snapshot_id = create_snapshot_for_annotation_cli

      result = run_binary(
        ["annotation", "list", "--snapshot-id", snapshot_id.to_s],
      )

      result[:status].should eq(0)
      result[:output].should contain("No annotations")
    end

    it "shows single line format for same start and end line" do
      snapshot_id = create_snapshot_for_annotation_cli
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 5, 5, "Single line")
      flush_wal

      result = run_binary(
        ["annotation", "list", "--snapshot-id", snapshot_id.to_s],
      )

      result[:status].should eq(0)
      result[:output].should contain("line 5")
      result[:output].should_not contain("lines 5-5")
    end
  end

  describe "annotation view" do
    it "views a single annotation by number" do
      snapshot_id = create_snapshot_for_annotation_cli
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 3, "View target")
      flush_wal

      result = run_binary(
        ["annotation", "view",
         "--snapshot-id", snapshot_id.to_s, "1"],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["annotation"]["number"].as_i.should eq(1)
      parsed["annotation"]["content"].as_s.should eq("View target")
    end

    it "errors for non-existent annotation number" do
      snapshot_id = create_snapshot_for_annotation_cli

      result = run_binary(
        ["annotation", "view",
         "--snapshot-id", snapshot_id.to_s, "99"],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end

    it "errors when annotation number is missing" do
      snapshot_id = create_snapshot_for_annotation_cli

      result = run_binary(
        ["annotation", "view",
         "--snapshot-id", snapshot_id.to_s],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("annotation number is required")
    end
  end

  describe "annotation update" do
    it "updates annotation content from stdin" do
      snapshot_id = create_snapshot_for_annotation_cli
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 3, "Original content")
      flush_wal

      result = run_binary(
        ["annotation", "update",
         "--snapshot-id", snapshot_id.to_s, "1"],
        stdin: "Updated content",
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["annotation"]["content"].as_s.should eq("Updated content")
      parsed["annotation"]["number"].as_i.should eq(1)

      # Verify in DB
      db_ann = GalaxySnapshots::Database.get_snapshot_annotation(snapshot_id, 1)
      db_ann.not_nil!.content.should eq("Updated content")
    end

    it "preserves line ranges on update" do
      snapshot_id = create_snapshot_for_annotation_cli
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 5, 10, "Original")
      flush_wal

      result = run_binary(
        ["annotation", "update",
         "--snapshot-id", snapshot_id.to_s, "1"],
        stdin: "New content",
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["annotation"]["start_line"].as_i.should eq(5)
      parsed["annotation"]["end_line"].as_i.should eq(10)
    end

    it "errors for non-existent annotation number" do
      snapshot_id = create_snapshot_for_annotation_cli

      result = run_binary(
        ["annotation", "update",
         "--snapshot-id", snapshot_id.to_s, "99"],
        stdin: "No target",
      )

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end

    it "errors when stdin is empty" do
      snapshot_id = create_snapshot_for_annotation_cli
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 1, "Existing")
      flush_wal

      result = run_binary(
        ["annotation", "update",
         "--snapshot-id", snapshot_id.to_s, "1"],
        stdin: "",
      )

      result[:status].should_not eq(0)
      result[:error].should contain("no content provided on stdin")
    end
  end

  describe "annotation delete" do
    it "deletes an annotation by number" do
      snapshot_id = create_snapshot_for_annotation_cli
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 1, "To delete")
      flush_wal

      result = run_binary(
        ["annotation", "delete",
         "--snapshot-id", snapshot_id.to_s, "1"],
      )

      result[:status].should eq(0)
      result[:output].should contain("Annotation #1 deleted")

      # Verify it's gone
      GalaxySnapshots::Database.get_snapshot_annotation(snapshot_id, 1).should be_nil
    end

    it "errors for non-existent annotation number" do
      snapshot_id = create_snapshot_for_annotation_cli

      result = run_binary(
        ["annotation", "delete",
         "--snapshot-id", snapshot_id.to_s, "99"],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end
  end

  describe "alternative identifier resolution" do
    it "resolves --ledger-session-id + --snapshot to snapshot id" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "Alt resolve", "content")
      snapshot = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
      snapshot_id = snapshot.not_nil!.id
      flush_wal

      # Create via alternative identifiers
      result = run_binary(
        ["annotation", "create",
         "--ledger-session-id", "1",
         "--snapshot", "1",
         "--start-line", "1", "--end-line", "1"],
        stdin: "Alt identifier test",
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["annotation"]["snapshot_id"].as_i64.should eq(snapshot_id)

      # List via alternative identifiers
      list_result = run_binary(
        ["annotation", "list",
         "--ledger-session-id", "1",
         "--snapshot", "1", "--json"],
      )

      list_result[:status].should eq(0)
      list_parsed = JSON.parse(list_result[:output])
      list_parsed["annotations"].as_a.size.should eq(1)
    end

    it "errors when --snapshot is missing with --ledger-session-id" do
      result = run_binary(
        ["annotation", "list",
         "--ledger-session-id", "1"],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("--snapshot is required")
    end
  end

  describe "annotation help" do
    it "shows annotation help" do
      result = run_binary(["annotation", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("Manage snapshot annotations")
      result[:output].should contain("create")
      result[:output].should contain("list")
      result[:output].should contain("view")
      result[:output].should contain("update")
      result[:output].should contain("delete")
    end

    it "shows annotation create help" do
      result = run_binary(["annotation", "create", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("--snapshot-id")
      result[:output].should contain("--start-line")
      result[:output].should contain("--end-line")
      result[:output].should contain("stdin")
    end

    it "shows annotation list help" do
      result = run_binary(["annotation", "list", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("--json")
    end
  end

  describe "end-to-end annotation workflow" do
    it "creates, lists, views, updates, deletes, and verifies" do
      snapshot_id = create_snapshot_for_annotation_cli

      # CREATE two annotations
      r1 = run_binary(
        ["annotation", "create",
         "--snapshot-id", snapshot_id.to_s,
         "--start-line", "1", "--end-line", "2"],
        stdin: "First annotation",
      )
      r1[:status].should eq(0)

      r2 = run_binary(
        ["annotation", "create",
         "--snapshot-id", snapshot_id.to_s,
         "--start-line", "3", "--end-line", "5"],
        stdin: "Second annotation",
      )
      r2[:status].should eq(0)

      # LIST — should show both
      list_result = run_binary(
        ["annotation", "list",
         "--snapshot-id", snapshot_id.to_s, "--json"],
      )
      list_result[:status].should eq(0)
      annotations = JSON.parse(list_result[:output])["annotations"].as_a
      annotations.size.should eq(2)

      # VIEW annotation #1
      view_result = run_binary(
        ["annotation", "view",
         "--snapshot-id", snapshot_id.to_s, "1"],
      )
      view_result[:status].should eq(0)
      JSON.parse(view_result[:output])["annotation"]["content"].as_s.should eq("First annotation")

      # UPDATE annotation #1
      update_result = run_binary(
        ["annotation", "update",
         "--snapshot-id", snapshot_id.to_s, "1"],
        stdin: "Updated first annotation",
      )
      update_result[:status].should eq(0)
      JSON.parse(update_result[:output])["annotation"]["content"].as_s.should eq("Updated first annotation")

      # DELETE annotation #2
      delete_result = run_binary(
        ["annotation", "delete",
         "--snapshot-id", snapshot_id.to_s, "2"],
      )
      delete_result[:status].should eq(0)

      # VERIFY — only annotation #1 remains with updated content
      final_list = run_binary(
        ["annotation", "list",
         "--snapshot-id", snapshot_id.to_s, "--json"],
      )
      final_annotations = JSON.parse(final_list[:output])["annotations"].as_a
      final_annotations.size.should eq(1)
      final_annotations[0]["number"].as_i.should eq(1)
      final_annotations[0]["content"].as_s.should eq("Updated first annotation")
    end
  end
end
