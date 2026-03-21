require "../spec_helper"

# Helper to create a snapshot for annotation tests.
def create_snapshot_for_annotations : Int64
  GalaxySnapshots::Database.save_snapshot(1_i64, "Test snapshot", "Line 1\nLine 2\nLine 3\nLine 4\nLine 5")
  snapshot = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
  snapshot.not_nil!.id
end

describe GalaxySnapshots::Database do
  # Clean database before each test
  before_each do
    db_path = GalaxySnapshots::Database.database_path
    File.delete(db_path) if File.exists?(db_path)
  end

  describe ".save_snapshot_annotation" do
    it "saves and returns annotation with number 1 for first annotation" do
      snapshot_id = create_snapshot_for_annotations
      result = GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 3, "Test note")
      result.should_not be_nil
      ann = result.not_nil!
      ann.number.should eq(1)
      ann.start_line.should eq(1)
      ann.end_line.should eq(3)
      ann.content.should eq("Test note")
      ann.snapshot_id.should eq(snapshot_id)
    end

    it "increments numbers sequentially within the same snapshot" do
      snapshot_id = create_snapshot_for_annotations

      a1 = GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 2, "First")
      a2 = GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 3, 4, "Second")
      a3 = GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 5, 5, "Third")

      a1.not_nil!.number.should eq(1)
      a2.not_nil!.number.should eq(2)
      a3.not_nil!.number.should eq(3)
    end

    it "starts numbering at 1 for a new snapshot" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "Snap A", "content a")
      GalaxySnapshots::Database.save_snapshot(1_i64, "Snap B", "content b")
      snap_a = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
      snap_b = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 2)

      GalaxySnapshots::Database.save_snapshot_annotation(snap_a.not_nil!.id, 1, 1, "On snap A")
      GalaxySnapshots::Database.save_snapshot_annotation(snap_a.not_nil!.id, 2, 2, "Another on A")

      ann_b = GalaxySnapshots::Database.save_snapshot_annotation(snap_b.not_nil!.id, 1, 1, "On snap B")
      ann_b.not_nil!.number.should eq(1)
    end

    it "stores start_line, end_line, and content correctly" do
      snapshot_id = create_snapshot_for_annotations
      result = GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 10, 22, "Multi-line\nannotation content")
      ann = result.not_nil!
      ann.start_line.should eq(10)
      ann.end_line.should eq(22)
      ann.content.should eq("Multi-line\nannotation content")
    end

    it "returns nil for invalid snapshot id" do
      result = GalaxySnapshots::Database.save_snapshot_annotation(0_i64, 1, 1, "Bad")
      result.should be_nil
    end

    it "populates created_at and updated_at timestamps" do
      snapshot_id = create_snapshot_for_annotations
      result = GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 1, "Timestamped")
      ann = result.not_nil!
      ann.created_at.should_not be_empty
      ann.updated_at.should_not be_empty
    end
  end

  describe ".list_snapshot_annotations" do
    it "returns annotations in reading order" do
      snapshot_id = create_snapshot_for_annotations
      # Create in reverse order to verify sorting
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 5, 5, "Third by position")
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 2, "First by position")
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 3, 4, "Second by position")

      annotations = GalaxySnapshots::Database.list_snapshot_annotations(snapshot_id)
      annotations.size.should eq(3)
      annotations[0].start_line.should eq(1)
      annotations[1].start_line.should eq(3)
      annotations[2].start_line.should eq(5)
    end

    it "orders by start_line, then end_line, then number" do
      snapshot_id = create_snapshot_for_annotations
      # Same start_line, different end_line
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 5, "Wider range")
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 2, "Narrower range")

      annotations = GalaxySnapshots::Database.list_snapshot_annotations(snapshot_id)
      annotations.size.should eq(2)
      annotations[0].end_line.should eq(2) # Narrower first
      annotations[1].end_line.should eq(5)
    end

    it "returns empty array for snapshot with no annotations" do
      snapshot_id = create_snapshot_for_annotations
      annotations = GalaxySnapshots::Database.list_snapshot_annotations(snapshot_id)
      annotations.should be_empty
    end

    it "returns empty array for invalid snapshot id" do
      annotations = GalaxySnapshots::Database.list_snapshot_annotations(0_i64)
      annotations.should be_empty
    end

    it "only returns annotations for the specified snapshot" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "Snap A", "content a")
      GalaxySnapshots::Database.save_snapshot(1_i64, "Snap B", "content b")
      snap_a = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
      snap_b = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 2)

      GalaxySnapshots::Database.save_snapshot_annotation(snap_a.not_nil!.id, 1, 1, "On A")
      GalaxySnapshots::Database.save_snapshot_annotation(snap_b.not_nil!.id, 1, 1, "On B")

      a_anns = GalaxySnapshots::Database.list_snapshot_annotations(snap_a.not_nil!.id)
      a_anns.size.should eq(1)
      a_anns[0].content.should eq("On A")
    end
  end

  describe ".get_snapshot_annotation" do
    it "returns annotation by snapshot id and number" do
      snapshot_id = create_snapshot_for_annotations
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 3, "Target annotation")

      result = GalaxySnapshots::Database.get_snapshot_annotation(snapshot_id, 1)
      result.should_not be_nil
      ann = result.not_nil!
      ann.content.should eq("Target annotation")
      ann.number.should eq(1)
      ann.snapshot_id.should eq(snapshot_id)
    end

    it "returns nil for non-existent number" do
      snapshot_id = create_snapshot_for_annotations
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 1, "Only one")

      result = GalaxySnapshots::Database.get_snapshot_annotation(snapshot_id, 99)
      result.should be_nil
    end

    it "returns nil for invalid snapshot id" do
      result = GalaxySnapshots::Database.get_snapshot_annotation(0_i64, 1)
      result.should be_nil
    end

    it "does not return annotation from a different snapshot" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "Snap A", "content a")
      GalaxySnapshots::Database.save_snapshot(1_i64, "Snap B", "content b")
      snap_a = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
      snap_b = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 2)

      GalaxySnapshots::Database.save_snapshot_annotation(snap_a.not_nil!.id, 1, 1, "On A only")

      result = GalaxySnapshots::Database.get_snapshot_annotation(snap_b.not_nil!.id, 1)
      result.should be_nil
    end
  end

  describe ".update_snapshot_annotation" do
    it "updates content and returns the updated annotation" do
      snapshot_id = create_snapshot_for_annotations
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 3, "Original content")

      updated = GalaxySnapshots::Database.update_snapshot_annotation(snapshot_id, 1, "Updated content")
      updated.should_not be_nil
      updated.not_nil!.content.should eq("Updated content")
      updated.not_nil!.number.should eq(1)
    end

    it "updates updated_at timestamp" do
      snapshot_id = create_snapshot_for_annotations
      created = GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 1, "Original")
      original_updated_at = created.not_nil!.updated_at

      # Small delay to ensure timestamp difference
      sleep(1.1.seconds)

      updated = GalaxySnapshots::Database.update_snapshot_annotation(snapshot_id, 1, "Changed")
      updated.not_nil!.updated_at.should_not eq(original_updated_at)
    end

    it "does not change start_line or end_line" do
      snapshot_id = create_snapshot_for_annotations
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 5, 10, "Original")

      updated = GalaxySnapshots::Database.update_snapshot_annotation(snapshot_id, 1, "New content")
      updated.not_nil!.start_line.should eq(5)
      updated.not_nil!.end_line.should eq(10)
    end

    it "returns nil for non-existent annotation" do
      snapshot_id = create_snapshot_for_annotations
      updated = GalaxySnapshots::Database.update_snapshot_annotation(snapshot_id, 99, "No target")
      updated.should be_nil
    end

    it "returns nil for invalid snapshot id" do
      updated = GalaxySnapshots::Database.update_snapshot_annotation(0_i64, 1, "Bad")
      updated.should be_nil
    end
  end

  describe ".delete_snapshot_annotation" do
    it "deletes and returns true" do
      snapshot_id = create_snapshot_for_annotations
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 1, "To delete")

      result = GalaxySnapshots::Database.delete_snapshot_annotation(snapshot_id, 1)
      result.should be_true

      # Verify it's gone
      result = GalaxySnapshots::Database.get_snapshot_annotation(snapshot_id, 1)
      result.should be_nil
    end

    it "returns false for non-existent number" do
      snapshot_id = create_snapshot_for_annotations
      result = GalaxySnapshots::Database.delete_snapshot_annotation(snapshot_id, 99)
      result.should be_false
    end

    it "returns false for invalid snapshot id" do
      result = GalaxySnapshots::Database.delete_snapshot_annotation(0_i64, 1)
      result.should be_false
    end
  end

  describe "cascade delete" do
    it "deletes annotations when parent snapshot is deleted" do
      snapshot_id = create_snapshot_for_annotations
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 2, "Will be cascaded")
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 3, 4, "Also cascaded")

      # Verify annotations exist
      GalaxySnapshots::Database.list_snapshot_annotations(snapshot_id).size.should eq(2)

      # Delete the snapshot
      GalaxySnapshots::Database.delete_snapshot_by_number(1_i64, 1)

      # Annotations should be gone
      GalaxySnapshots::Database.list_snapshot_annotations(snapshot_id).should be_empty
    end
  end

  describe "review fields on annotations" do
    it "returns nil review fields for unreviewed annotations" do
      snapshot_id = create_snapshot_for_annotations
      result = GalaxySnapshots::Database.save_snapshot_annotation(
        snapshot_id, 1, 3, "test note"
      )
      result.should_not be_nil
      a = result.not_nil!
      a.review_number.should be_nil
      a.review_reviewed_at.should be_nil
      a.snapshot_review_id.should be_nil
    end

    it "returns review fields via list after review assignment" do
      snapshot_id = create_snapshot_for_annotations
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 2, "note")
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)

      anns = GalaxySnapshots::Database.list_snapshot_annotations(snapshot_id)
      anns.size.should eq(1)
      anns[0].review_number.should eq(1)
      anns[0].review_reviewed_at.should be_nil
      anns[0].snapshot_review_id.should_not be_nil
    end

    it "returns review fields via get after review assignment" do
      snapshot_id = create_snapshot_for_annotations
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 2, "note")
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)

      ann = GalaxySnapshots::Database.get_snapshot_annotation(snapshot_id, 1)
      ann.should_not be_nil
      ann.not_nil!.review_number.should eq(1)
      ann.not_nil!.review_reviewed_at.should be_nil
    end

    it "returns review fields via update after review assignment" do
      snapshot_id = create_snapshot_for_annotations
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 2, "original")
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)

      updated = GalaxySnapshots::Database.update_snapshot_annotation(
        snapshot_id, 1, "changed"
      )
      updated.should_not be_nil
      updated.not_nil!.review_number.should eq(1)
      updated.not_nil!.review_reviewed_at.should be_nil
    end

    it "populates reviewed_at after mark-reviewed" do
      snapshot_id = create_snapshot_for_annotations
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 1, "note")
      result = GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      review = result.not_nil![0]
      GalaxySnapshots::Database.mark_snapshot_review_reviewed(
        snapshot_id, review.number
      )

      anns = GalaxySnapshots::Database.list_snapshot_annotations(snapshot_id)
      anns[0].review_number.should eq(1)
      anns[0].review_reviewed_at.should_not be_nil
    end
  end

  describe "number gap behavior" do
    it "assigns MAX+1 after deletion (does not reuse numbers)" do
      snapshot_id = create_snapshot_for_annotations
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 1, "First")
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 2, 2, "Second")
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 3, 3, "Third")

      # Delete #2
      GalaxySnapshots::Database.delete_snapshot_annotation(snapshot_id, 2)

      # Next annotation should be #4, not #2
      a4 = GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 4, 4, "Fourth")
      a4.not_nil!.number.should eq(4)
    end
  end
end
