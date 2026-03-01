require "../spec_helper"

# Helper to create a session and snapshot for review tests.
def create_session_with_snapshot_for_reviews(session_name : String) : {Int64, Int64}
  session_id = GalaxyLedger::Database.create_session(session_name)
  GalaxyLedger::Database.save_snapshot(session_id, "Test snapshot", "Line 1\nLine 2\nLine 3\nLine 4\nLine 5")
  snapshot = GalaxyLedger::Database.get_snapshot_by_number(session_id, 1)
  {session_id, snapshot.not_nil!.id}
end

# Helper to create annotations on a snapshot for review tests.
def create_annotations_for_review(snapshot_id : Int64, count : Int32 = 3)
  count.times do |i|
    GalaxyLedger::Database.save_snapshot_annotation(
      snapshot_id, (i + 1).to_i, (i + 1).to_i, "Annotation #{i + 1}",
    )
  end
end

describe GalaxyLedger::Database do
  # Clean database before each test
  before_each do
    db_path = GalaxyLedger::Database.database_path
    File.delete(db_path) if File.exists?(db_path)
  end

  describe ".save_snapshot_review" do
    it "creates review with number 1 and assigns unreviewed annotations" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-save-1")
      create_annotations_for_review(snapshot_id, 3)

      result = GalaxyLedger::Database.save_snapshot_review(snapshot_id)
      result.should_not be_nil
      review, count = result.not_nil!
      review.number.should eq(1)
      review.ledger_snapshot_id.should eq(snapshot_id)
      review.reviewed_at.should be_nil
      count.should eq(3)
    end

    it "returns nil when no unreviewed annotations exist" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-save-2")
      # No annotations at all
      result = GalaxyLedger::Database.save_snapshot_review(snapshot_id)
      result.should be_nil
    end

    it "returns nil after all annotations are assigned to a review" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-save-3")
      create_annotations_for_review(snapshot_id, 2)

      # First review takes all annotations
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      # Second attempt — no unreviewed annotations left
      result = GalaxyLedger::Database.save_snapshot_review(snapshot_id)
      result.should be_nil
    end

    it "assigns sequential numbers across multiple reviews" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-save-4")
      create_annotations_for_review(snapshot_id, 2)

      r1 = GalaxyLedger::Database.save_snapshot_review(snapshot_id)
      r1.not_nil![0].number.should eq(1)

      # Add more annotations, then create another review
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 4, 5, "New annotation")

      r2 = GalaxyLedger::Database.save_snapshot_review(snapshot_id)
      r2.not_nil![0].number.should eq(2)
      r2.not_nil![1].should eq(1) # Only 1 new annotation
    end

    it "only assigns annotations with null review_id" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-save-5")
      create_annotations_for_review(snapshot_id, 3)

      # First review takes all 3
      r1 = GalaxyLedger::Database.save_snapshot_review(snapshot_id)
      r1.not_nil![1].should eq(3)

      # Add 1 more annotation
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 5, 5, "New one")

      # Second review should only take the new one
      r2 = GalaxyLedger::Database.save_snapshot_review(snapshot_id)
      r2.not_nil![1].should eq(1)

      # Verify: review 1 has 3 annotations, review 2 has 1
      review1 = GalaxyLedger::Database.get_snapshot_review(snapshot_id, 1)
      review2 = GalaxyLedger::Database.get_snapshot_review(snapshot_id, 2)
      GalaxyLedger::Database.list_annotations_for_review(review1.not_nil!.id).size.should eq(3)
      GalaxyLedger::Database.list_annotations_for_review(review2.not_nil!.id).size.should eq(1)
    end

    it "returns nil for invalid snapshot id" do
      result = GalaxyLedger::Database.save_snapshot_review(0_i64)
      result.should be_nil
    end

    it "populates created_at and updated_at timestamps" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-save-6")
      create_annotations_for_review(snapshot_id, 1)

      result = GalaxyLedger::Database.save_snapshot_review(snapshot_id)
      review = result.not_nil![0]
      review.created_at.should_not be_empty
      review.updated_at.should_not be_empty
    end
  end

  describe ".list_snapshot_reviews" do
    it "lists all reviews ordered by number" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-list-1")
      create_annotations_for_review(snapshot_id, 2)
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 4, 5, "Extra")
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      reviews = GalaxyLedger::Database.list_snapshot_reviews(snapshot_id)
      reviews.size.should eq(2)
      reviews[0].number.should eq(1)
      reviews[1].number.should eq(2)
    end

    it "filters to pending only when pending_only is true" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-list-2")
      create_annotations_for_review(snapshot_id, 2)
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 4, 5, "Extra")
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      # Mark first review as reviewed
      GalaxyLedger::Database.mark_snapshot_review_reviewed(snapshot_id, 1)

      # All reviews
      all = GalaxyLedger::Database.list_snapshot_reviews(snapshot_id)
      all.size.should eq(2)

      # Pending only
      pending = GalaxyLedger::Database.list_snapshot_reviews(snapshot_id, pending_only: true)
      pending.size.should eq(1)
      pending[0].number.should eq(2)
    end

    it "returns empty array for snapshot with no reviews" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-list-3")
      reviews = GalaxyLedger::Database.list_snapshot_reviews(snapshot_id)
      reviews.should be_empty
    end

    it "returns empty array for invalid snapshot id" do
      reviews = GalaxyLedger::Database.list_snapshot_reviews(0_i64)
      reviews.should be_empty
    end
  end

  describe ".get_snapshot_review" do
    it "retrieves by snapshot_id + number" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-get-1")
      create_annotations_for_review(snapshot_id, 1)
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      review = GalaxyLedger::Database.get_snapshot_review(snapshot_id, 1)
      review.should_not be_nil
      review.not_nil!.number.should eq(1)
      review.not_nil!.ledger_snapshot_id.should eq(snapshot_id)
    end

    it "returns nil for nonexistent number" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-get-2")
      result = GalaxyLedger::Database.get_snapshot_review(snapshot_id, 99)
      result.should be_nil
    end

    it "returns nil for invalid snapshot id" do
      result = GalaxyLedger::Database.get_snapshot_review(0_i64, 1)
      result.should be_nil
    end
  end

  describe ".mark_snapshot_review_reviewed" do
    it "sets reviewed_at timestamp" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-mark-1")
      create_annotations_for_review(snapshot_id, 1)
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      review = GalaxyLedger::Database.mark_snapshot_review_reviewed(snapshot_id, 1)
      review.should_not be_nil
      review.not_nil!.reviewed_at.should_not be_nil
    end

    it "is idempotent — calling again updates timestamp" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-mark-2")
      create_annotations_for_review(snapshot_id, 1)
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      r1 = GalaxyLedger::Database.mark_snapshot_review_reviewed(snapshot_id, 1)
      first_reviewed_at = r1.not_nil!.reviewed_at

      sleep(1.1.seconds)

      r2 = GalaxyLedger::Database.mark_snapshot_review_reviewed(snapshot_id, 1)
      r2.not_nil!.reviewed_at.should_not eq(first_reviewed_at)
    end

    it "returns nil for nonexistent review" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-mark-3")
      result = GalaxyLedger::Database.mark_snapshot_review_reviewed(snapshot_id, 99)
      result.should be_nil
    end

    it "returns nil for invalid snapshot id" do
      result = GalaxyLedger::Database.mark_snapshot_review_reviewed(0_i64, 1)
      result.should be_nil
    end
  end

  describe ".count_unreviewed_annotations" do
    it "returns correct count of unreviewed annotations" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-count-1")
      create_annotations_for_review(snapshot_id, 3)

      count = GalaxyLedger::Database.count_unreviewed_annotations(snapshot_id)
      count.should eq(3)
    end

    it "returns 0 when all annotations are assigned to reviews" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-count-2")
      create_annotations_for_review(snapshot_id, 2)
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      count = GalaxyLedger::Database.count_unreviewed_annotations(snapshot_id)
      count.should eq(0)
    end

    it "returns 0 for snapshot with no annotations" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-count-3")
      count = GalaxyLedger::Database.count_unreviewed_annotations(snapshot_id)
      count.should eq(0)
    end

    it "returns 0 for invalid snapshot id" do
      count = GalaxyLedger::Database.count_unreviewed_annotations(0_i64)
      count.should eq(0)
    end
  end

  describe ".list_annotations_for_review" do
    it "returns annotations assigned to a specific review" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-anns-1")
      create_annotations_for_review(snapshot_id, 3)
      result = GalaxyLedger::Database.save_snapshot_review(snapshot_id)
      review = result.not_nil![0]

      annotations = GalaxyLedger::Database.list_annotations_for_review(review.id)
      annotations.size.should eq(3)
      annotations.all? { |a| a.ledger_snapshot_review_id == review.id }.should be_true
    end

    it "returns annotations in reading order" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-anns-2")
      # Create in reverse order
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 5, 5, "Third")
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 1, 2, "First")
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 3, 4, "Second")
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      review = GalaxyLedger::Database.get_snapshot_review(snapshot_id, 1)
      annotations = GalaxyLedger::Database.list_annotations_for_review(review.not_nil!.id)
      annotations[0].start_line.should eq(1)
      annotations[1].start_line.should eq(3)
      annotations[2].start_line.should eq(5)
    end

    it "returns empty array for nonexistent review id" do
      annotations = GalaxyLedger::Database.list_annotations_for_review(99999_i64)
      annotations.should be_empty
    end

    it "returns empty array for invalid review id" do
      annotations = GalaxyLedger::Database.list_annotations_for_review(0_i64)
      annotations.should be_empty
    end
  end

  describe "cascade delete" do
    it "deletes reviews when parent snapshot is deleted" do
      session_id, snapshot_id = create_session_with_snapshot_for_reviews("rev-cascade-1")
      create_annotations_for_review(snapshot_id, 2)
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      # Verify review exists
      GalaxyLedger::Database.list_snapshot_reviews(snapshot_id).size.should eq(1)

      # Delete the snapshot
      GalaxyLedger::Database.delete_snapshot_by_number(session_id, 1)

      # Reviews should be gone
      GalaxyLedger::Database.list_snapshot_reviews(snapshot_id).should be_empty
    end

    it "sets annotation review_id to null when review is deleted via snapshot cascade" do
      session_id, snapshot_id = create_session_with_snapshot_for_reviews("rev-cascade-2")
      create_annotations_for_review(snapshot_id, 2)
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      # Verify annotations are assigned
      anns = GalaxyLedger::Database.list_snapshot_annotations(snapshot_id)
      anns.all? { |a| !a.ledger_snapshot_review_id.nil? }.should be_true

      # Delete the snapshot — cascades to reviews, which sets annotation review_id to null
      # But annotations also cascade-delete with the snapshot, so verify the cascade chain
      GalaxyLedger::Database.delete_snapshot_by_number(session_id, 1)
      GalaxyLedger::Database.list_snapshot_annotations(snapshot_id).should be_empty
    end
  end

  describe "annotation review fields via list_annotations_for_review" do
    it "populates review_number on annotations assigned to a review" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-annfield-1")
      create_annotations_for_review(snapshot_id, 2)
      result = GalaxyLedger::Database.save_snapshot_review(snapshot_id)
      review = result.not_nil![0]

      anns = GalaxyLedger::Database.list_annotations_for_review(review.id)
      anns.size.should eq(2)
      anns.all? { |a| a.review_number == 1 }.should be_true
      anns.all? { |a| a.review_reviewed_at.nil? }.should be_true
    end

    it "populates reviewed_at after mark-reviewed" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-annfield-2")
      create_annotations_for_review(snapshot_id, 1)
      result = GalaxyLedger::Database.save_snapshot_review(snapshot_id)
      review = result.not_nil![0]
      GalaxyLedger::Database.mark_snapshot_review_reviewed(snapshot_id, review.number)

      anns = GalaxyLedger::Database.list_annotations_for_review(review.id)
      anns[0].review_number.should eq(1)
      anns[0].review_reviewed_at.should_not be_nil
    end
  end

  describe "annotation ledger_snapshot_review_id field" do
    it "returns nil for annotations not assigned to a review" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-field-1")
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 1, 2, "Unreviewed")

      ann = GalaxyLedger::Database.get_snapshot_annotation(snapshot_id, 1)
      ann.not_nil!.ledger_snapshot_review_id.should be_nil
    end

    it "returns review id for annotations assigned to a review" do
      _, snapshot_id = create_session_with_snapshot_for_reviews("rev-field-2")
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 1, 2, "Will be reviewed")

      result = GalaxyLedger::Database.save_snapshot_review(snapshot_id)
      review = result.not_nil![0]

      ann = GalaxyLedger::Database.get_snapshot_annotation(snapshot_id, 1)
      ann.not_nil!.ledger_snapshot_review_id.should eq(review.id)
    end
  end
end
