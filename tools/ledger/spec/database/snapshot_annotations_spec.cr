require "../spec_helper"

# Helper to create a session and snapshot for annotation tests.
def create_session_with_snapshot(session_name : String) : {Int64, Int64}
  session_id = GalaxyLedger::Database.create_session(session_name)
  GalaxyLedger::Database.save_snapshot(session_id, "Test snapshot", "Line 1\nLine 2\nLine 3\nLine 4\nLine 5")
  snapshot = GalaxyLedger::Database.get_snapshot_by_number(session_id, 1)
  {session_id, snapshot.not_nil!.id}
end

describe GalaxyLedger::Database do
  # Clean database before each test
  before_each do
    db_path = GalaxyLedger::Database.database_path
    File.delete(db_path) if File.exists?(db_path)
  end

  describe ".save_snapshot_annotation" do
    it "saves and returns annotation with number 1 for first annotation" do
      _, snapshot_id = create_session_with_snapshot("ann-save-1")
      result = GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 1, 3, "Test note")
      result.should_not be_nil
      ann = result.not_nil!
      ann.number.should eq(1)
      ann.start_line.should eq(1)
      ann.end_line.should eq(3)
      ann.content.should eq("Test note")
      ann.ledger_snapshot_id.should eq(snapshot_id)
    end

    it "increments numbers sequentially within the same snapshot" do
      _, snapshot_id = create_session_with_snapshot("ann-save-2")

      a1 = GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 1, 2, "First")
      a2 = GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 3, 4, "Second")
      a3 = GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 5, 5, "Third")

      a1.not_nil!.number.should eq(1)
      a2.not_nil!.number.should eq(2)
      a3.not_nil!.number.should eq(3)
    end

    it "starts numbering at 1 for a new snapshot" do
      session_id = GalaxyLedger::Database.create_session("ann-save-3")
      GalaxyLedger::Database.save_snapshot(session_id, "Snap A", "content a")
      GalaxyLedger::Database.save_snapshot(session_id, "Snap B", "content b")
      snap_a = GalaxyLedger::Database.get_snapshot_by_number(session_id, 1)
      snap_b = GalaxyLedger::Database.get_snapshot_by_number(session_id, 2)

      GalaxyLedger::Database.save_snapshot_annotation(snap_a.not_nil!.id, 1, 1, "On snap A")
      GalaxyLedger::Database.save_snapshot_annotation(snap_a.not_nil!.id, 2, 2, "Another on A")

      ann_b = GalaxyLedger::Database.save_snapshot_annotation(snap_b.not_nil!.id, 1, 1, "On snap B")
      ann_b.not_nil!.number.should eq(1)
    end

    it "stores start_line, end_line, and content correctly" do
      _, snapshot_id = create_session_with_snapshot("ann-save-4")
      result = GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 10, 22, "Multi-line\nannotation content")
      ann = result.not_nil!
      ann.start_line.should eq(10)
      ann.end_line.should eq(22)
      ann.content.should eq("Multi-line\nannotation content")
    end

    it "returns nil for invalid snapshot id" do
      result = GalaxyLedger::Database.save_snapshot_annotation(0_i64, 1, 1, "Bad")
      result.should be_nil
    end

    it "populates created_at and updated_at timestamps" do
      _, snapshot_id = create_session_with_snapshot("ann-save-5")
      result = GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 1, 1, "Timestamped")
      ann = result.not_nil!
      ann.created_at.should_not be_empty
      ann.updated_at.should_not be_empty
    end
  end

  describe ".list_snapshot_annotations" do
    it "returns annotations in reading order" do
      _, snapshot_id = create_session_with_snapshot("ann-list-1")
      # Create in reverse order to verify sorting
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 5, 5, "Third by position")
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 1, 2, "First by position")
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 3, 4, "Second by position")

      annotations = GalaxyLedger::Database.list_snapshot_annotations(snapshot_id)
      annotations.size.should eq(3)
      annotations[0].start_line.should eq(1)
      annotations[1].start_line.should eq(3)
      annotations[2].start_line.should eq(5)
    end

    it "orders by start_line, then end_line, then number" do
      _, snapshot_id = create_session_with_snapshot("ann-list-2")
      # Same start_line, different end_line
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 1, 5, "Wider range")
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 1, 2, "Narrower range")

      annotations = GalaxyLedger::Database.list_snapshot_annotations(snapshot_id)
      annotations.size.should eq(2)
      annotations[0].end_line.should eq(2) # Narrower first
      annotations[1].end_line.should eq(5)
    end

    it "returns empty array for snapshot with no annotations" do
      _, snapshot_id = create_session_with_snapshot("ann-list-3")
      annotations = GalaxyLedger::Database.list_snapshot_annotations(snapshot_id)
      annotations.should be_empty
    end

    it "returns empty array for invalid snapshot id" do
      annotations = GalaxyLedger::Database.list_snapshot_annotations(0_i64)
      annotations.should be_empty
    end

    it "only returns annotations for the specified snapshot" do
      session_id = GalaxyLedger::Database.create_session("ann-list-4")
      GalaxyLedger::Database.save_snapshot(session_id, "Snap A", "content a")
      GalaxyLedger::Database.save_snapshot(session_id, "Snap B", "content b")
      snap_a = GalaxyLedger::Database.get_snapshot_by_number(session_id, 1)
      snap_b = GalaxyLedger::Database.get_snapshot_by_number(session_id, 2)

      GalaxyLedger::Database.save_snapshot_annotation(snap_a.not_nil!.id, 1, 1, "On A")
      GalaxyLedger::Database.save_snapshot_annotation(snap_b.not_nil!.id, 1, 1, "On B")

      a_anns = GalaxyLedger::Database.list_snapshot_annotations(snap_a.not_nil!.id)
      a_anns.size.should eq(1)
      a_anns[0].content.should eq("On A")
    end
  end

  describe ".get_snapshot_annotation" do
    it "returns annotation by snapshot id and number" do
      _, snapshot_id = create_session_with_snapshot("ann-get-1")
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 1, 3, "Target annotation")

      result = GalaxyLedger::Database.get_snapshot_annotation(snapshot_id, 1)
      result.should_not be_nil
      ann = result.not_nil!
      ann.content.should eq("Target annotation")
      ann.number.should eq(1)
      ann.ledger_snapshot_id.should eq(snapshot_id)
    end

    it "returns nil for non-existent number" do
      _, snapshot_id = create_session_with_snapshot("ann-get-2")
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 1, 1, "Only one")

      result = GalaxyLedger::Database.get_snapshot_annotation(snapshot_id, 99)
      result.should be_nil
    end

    it "returns nil for invalid snapshot id" do
      result = GalaxyLedger::Database.get_snapshot_annotation(0_i64, 1)
      result.should be_nil
    end

    it "does not return annotation from a different snapshot" do
      session_id = GalaxyLedger::Database.create_session("ann-get-3")
      GalaxyLedger::Database.save_snapshot(session_id, "Snap A", "content a")
      GalaxyLedger::Database.save_snapshot(session_id, "Snap B", "content b")
      snap_a = GalaxyLedger::Database.get_snapshot_by_number(session_id, 1)
      snap_b = GalaxyLedger::Database.get_snapshot_by_number(session_id, 2)

      GalaxyLedger::Database.save_snapshot_annotation(snap_a.not_nil!.id, 1, 1, "On A only")

      result = GalaxyLedger::Database.get_snapshot_annotation(snap_b.not_nil!.id, 1)
      result.should be_nil
    end
  end

  describe ".update_snapshot_annotation" do
    it "updates content and returns the updated annotation" do
      _, snapshot_id = create_session_with_snapshot("ann-upd-1")
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 1, 3, "Original content")

      updated = GalaxyLedger::Database.update_snapshot_annotation(snapshot_id, 1, "Updated content")
      updated.should_not be_nil
      updated.not_nil!.content.should eq("Updated content")
      updated.not_nil!.number.should eq(1)
    end

    it "updates updated_at timestamp" do
      _, snapshot_id = create_session_with_snapshot("ann-upd-2")
      created = GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 1, 1, "Original")
      original_updated_at = created.not_nil!.updated_at

      # Small delay to ensure timestamp difference
      sleep(1.1.seconds)

      updated = GalaxyLedger::Database.update_snapshot_annotation(snapshot_id, 1, "Changed")
      updated.not_nil!.updated_at.should_not eq(original_updated_at)
    end

    it "does not change start_line or end_line" do
      _, snapshot_id = create_session_with_snapshot("ann-upd-3")
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 5, 10, "Original")

      updated = GalaxyLedger::Database.update_snapshot_annotation(snapshot_id, 1, "New content")
      updated.not_nil!.start_line.should eq(5)
      updated.not_nil!.end_line.should eq(10)
    end

    it "returns nil for non-existent annotation" do
      _, snapshot_id = create_session_with_snapshot("ann-upd-4")
      updated = GalaxyLedger::Database.update_snapshot_annotation(snapshot_id, 99, "No target")
      updated.should be_nil
    end

    it "returns nil for invalid snapshot id" do
      updated = GalaxyLedger::Database.update_snapshot_annotation(0_i64, 1, "Bad")
      updated.should be_nil
    end
  end

  describe ".delete_snapshot_annotation" do
    it "deletes and returns true" do
      _, snapshot_id = create_session_with_snapshot("ann-del-1")
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 1, 1, "To delete")

      result = GalaxyLedger::Database.delete_snapshot_annotation(snapshot_id, 1)
      result.should be_true

      # Verify it's gone
      result = GalaxyLedger::Database.get_snapshot_annotation(snapshot_id, 1)
      result.should be_nil
    end

    it "returns false for non-existent number" do
      _, snapshot_id = create_session_with_snapshot("ann-del-2")
      result = GalaxyLedger::Database.delete_snapshot_annotation(snapshot_id, 99)
      result.should be_false
    end

    it "returns false for invalid snapshot id" do
      result = GalaxyLedger::Database.delete_snapshot_annotation(0_i64, 1)
      result.should be_false
    end
  end

  describe "cascade delete" do
    it "deletes annotations when parent snapshot is deleted" do
      session_id, snapshot_id = create_session_with_snapshot("ann-cascade-1")
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 1, 2, "Will be cascaded")
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 3, 4, "Also cascaded")

      # Verify annotations exist
      GalaxyLedger::Database.list_snapshot_annotations(snapshot_id).size.should eq(2)

      # Delete the snapshot
      GalaxyLedger::Database.delete_snapshot_by_number(session_id, 1)

      # Annotations should be gone
      GalaxyLedger::Database.list_snapshot_annotations(snapshot_id).should be_empty
    end
  end

  describe "number gap behavior" do
    it "assigns MAX+1 after deletion (does not reuse numbers)" do
      _, snapshot_id = create_session_with_snapshot("ann-gap-1")
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 1, 1, "First")
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 2, 2, "Second")
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 3, 3, "Third")

      # Delete #2
      GalaxyLedger::Database.delete_snapshot_annotation(snapshot_id, 2)

      # Next annotation should be #4, not #2
      a4 = GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 4, 4, "Fourth")
      a4.not_nil!.number.should eq(4)
    end
  end
end
