require "../spec_helper"

# Helper to create a snapshot for review tests.
def create_snapshot_for_reviews : Int64
  GalaxySnapshots::Database.save_snapshot(1_i64, "Test snapshot", "Line 1\nLine 2\nLine 3\nLine 4\nLine 5")
  snapshot = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
  snapshot.not_nil!.id
end

# Helper to create annotations on a snapshot for review tests.
def create_annotations_for_review(snapshot_id : Int64, count : Int32 = 3)
  count.times do |i|
    GalaxySnapshots::Database.save_snapshot_annotation(
      snapshot_id, (i + 1).to_i, (i + 1).to_i, "Annotation #{i + 1}",
    )
  end
end

describe GalaxySnapshots::Database do
  # Clean database before each test
  before_each do
    db_path = GalaxySnapshots::Database.database_path
    File.delete(db_path) if File.exists?(db_path)
  end

  describe ".save_snapshot_review" do
    it "creates review with number 1 and assigns unreviewed annotations" do
      snapshot_id = create_snapshot_for_reviews
      create_annotations_for_review(snapshot_id, 3)

      result = GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      result.should_not be_nil
      review, count = result.not_nil!
      review.number.should eq(1)
      review.snapshot_id.should eq(snapshot_id)
      review.reviewed_at.should be_nil
      count.should eq(3)
    end

    it "returns nil when no unreviewed annotations exist" do
      snapshot_id = create_snapshot_for_reviews
      # No annotations at all
      result = GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      result.should be_nil
    end

    it "returns nil after all annotations are assigned to a review" do
      snapshot_id = create_snapshot_for_reviews
      create_annotations_for_review(snapshot_id, 2)

      # First review takes all annotations
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)

      # Second attempt — no unreviewed annotations left
      result = GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      result.should be_nil
    end

    it "assigns sequential numbers across multiple reviews" do
      snapshot_id = create_snapshot_for_reviews
      create_annotations_for_review(snapshot_id, 2)

      r1 = GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      r1.not_nil![0].number.should eq(1)

      # Add more annotations, then create another review
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 4, 5, "New annotation")

      r2 = GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      r2.not_nil![0].number.should eq(2)
      r2.not_nil![1].should eq(1) # Only 1 new annotation
    end

    it "only assigns annotations with null review_id" do
      snapshot_id = create_snapshot_for_reviews
      create_annotations_for_review(snapshot_id, 3)

      # First review takes all 3
      r1 = GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      r1.not_nil![1].should eq(3)

      # Add 1 more annotation
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 5, 5, "New one")

      # Second review should only take the new one
      r2 = GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      r2.not_nil![1].should eq(1)

      # Verify: review 1 has 3 annotations, review 2 has 1
      review1 = GalaxySnapshots::Database.get_snapshot_review(snapshot_id, 1)
      review2 = GalaxySnapshots::Database.get_snapshot_review(snapshot_id, 2)
      GalaxySnapshots::Database.list_annotations_for_review(review1.not_nil!.id).size.should eq(3)
      GalaxySnapshots::Database.list_annotations_for_review(review2.not_nil!.id).size.should eq(1)
    end

    it "returns nil for invalid snapshot id" do
      result = GalaxySnapshots::Database.save_snapshot_review(0_i64)
      result.should be_nil
    end

    it "populates created_at and updated_at timestamps" do
      snapshot_id = create_snapshot_for_reviews
      create_annotations_for_review(snapshot_id, 1)

      result = GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      review = result.not_nil![0]
      review.created_at.should_not be_empty
      review.updated_at.should_not be_empty
    end
  end

  describe ".list_snapshot_reviews" do
    it "lists all reviews ordered by number" do
      snapshot_id = create_snapshot_for_reviews
      create_annotations_for_review(snapshot_id, 2)
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)

      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 4, 5, "Extra")
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)

      reviews = GalaxySnapshots::Database.list_snapshot_reviews(snapshot_id)
      reviews.size.should eq(2)
      reviews[0].number.should eq(1)
      reviews[1].number.should eq(2)
    end

    it "filters to pending only when pending_only is true" do
      snapshot_id = create_snapshot_for_reviews
      create_annotations_for_review(snapshot_id, 2)
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)

      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 4, 5, "Extra")
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)

      # Mark first review as reviewed
      GalaxySnapshots::Database.mark_snapshot_review_reviewed(snapshot_id, 1)

      # All reviews
      all = GalaxySnapshots::Database.list_snapshot_reviews(snapshot_id)
      all.size.should eq(2)

      # Pending only
      pending = GalaxySnapshots::Database.list_snapshot_reviews(snapshot_id, pending_only: true)
      pending.size.should eq(1)
      pending[0].number.should eq(2)
    end

    it "returns empty array for snapshot with no reviews" do
      snapshot_id = create_snapshot_for_reviews
      reviews = GalaxySnapshots::Database.list_snapshot_reviews(snapshot_id)
      reviews.should be_empty
    end

    it "returns empty array for invalid snapshot id" do
      reviews = GalaxySnapshots::Database.list_snapshot_reviews(0_i64)
      reviews.should be_empty
    end
  end

  describe ".get_snapshot_review" do
    it "retrieves by snapshot_id + number" do
      snapshot_id = create_snapshot_for_reviews
      create_annotations_for_review(snapshot_id, 1)
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)

      review = GalaxySnapshots::Database.get_snapshot_review(snapshot_id, 1)
      review.should_not be_nil
      review.not_nil!.number.should eq(1)
      review.not_nil!.snapshot_id.should eq(snapshot_id)
    end

    it "returns nil for nonexistent number" do
      snapshot_id = create_snapshot_for_reviews
      result = GalaxySnapshots::Database.get_snapshot_review(snapshot_id, 99)
      result.should be_nil
    end

    it "returns nil for invalid snapshot id" do
      result = GalaxySnapshots::Database.get_snapshot_review(0_i64, 1)
      result.should be_nil
    end
  end

  describe ".mark_snapshot_review_reviewed" do
    it "sets reviewed_at timestamp" do
      snapshot_id = create_snapshot_for_reviews
      create_annotations_for_review(snapshot_id, 1)
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)

      review = GalaxySnapshots::Database.mark_snapshot_review_reviewed(snapshot_id, 1)
      review.should_not be_nil
      review.not_nil!.reviewed_at.should_not be_nil
    end

    it "is idempotent — calling again updates timestamp" do
      snapshot_id = create_snapshot_for_reviews
      create_annotations_for_review(snapshot_id, 1)
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)

      r1 = GalaxySnapshots::Database.mark_snapshot_review_reviewed(snapshot_id, 1)
      first_reviewed_at = r1.not_nil!.reviewed_at

      sleep(1.1.seconds)

      r2 = GalaxySnapshots::Database.mark_snapshot_review_reviewed(snapshot_id, 1)
      r2.not_nil!.reviewed_at.should_not eq(first_reviewed_at)
    end

    it "returns nil for nonexistent review" do
      snapshot_id = create_snapshot_for_reviews
      result = GalaxySnapshots::Database.mark_snapshot_review_reviewed(snapshot_id, 99)
      result.should be_nil
    end

    it "returns nil for invalid snapshot id" do
      result = GalaxySnapshots::Database.mark_snapshot_review_reviewed(0_i64, 1)
      result.should be_nil
    end
  end

  describe ".count_unreviewed_annotations" do
    it "returns correct count of unreviewed annotations" do
      snapshot_id = create_snapshot_for_reviews
      create_annotations_for_review(snapshot_id, 3)

      count = GalaxySnapshots::Database.count_unreviewed_annotations(snapshot_id)
      count.should eq(3)
    end

    it "returns 0 when all annotations are assigned to reviews" do
      snapshot_id = create_snapshot_for_reviews
      create_annotations_for_review(snapshot_id, 2)
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)

      count = GalaxySnapshots::Database.count_unreviewed_annotations(snapshot_id)
      count.should eq(0)
    end

    it "returns 0 for snapshot with no annotations" do
      snapshot_id = create_snapshot_for_reviews
      count = GalaxySnapshots::Database.count_unreviewed_annotations(snapshot_id)
      count.should eq(0)
    end

    it "returns 0 for invalid snapshot id" do
      count = GalaxySnapshots::Database.count_unreviewed_annotations(0_i64)
      count.should eq(0)
    end
  end

  describe ".list_annotations_for_review" do
    it "returns annotations assigned to a specific review" do
      snapshot_id = create_snapshot_for_reviews
      create_annotations_for_review(snapshot_id, 3)
      result = GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      review = result.not_nil![0]

      annotations = GalaxySnapshots::Database.list_annotations_for_review(review.id)
      annotations.size.should eq(3)
      annotations.all? { |a| a.snapshot_review_id == review.id }.should be_true
    end

    it "returns annotations in reading order" do
      snapshot_id = create_snapshot_for_reviews
      # Create in reverse order
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 5, 5, "Third")
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 2, "First")
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 3, 4, "Second")
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)

      review = GalaxySnapshots::Database.get_snapshot_review(snapshot_id, 1)
      annotations = GalaxySnapshots::Database.list_annotations_for_review(review.not_nil!.id)
      annotations[0].start_line.should eq(1)
      annotations[1].start_line.should eq(3)
      annotations[2].start_line.should eq(5)
    end

    it "returns empty array for nonexistent review id" do
      annotations = GalaxySnapshots::Database.list_annotations_for_review(99999_i64)
      annotations.should be_empty
    end

    it "returns empty array for invalid review id" do
      annotations = GalaxySnapshots::Database.list_annotations_for_review(0_i64)
      annotations.should be_empty
    end
  end

  describe "cascade delete" do
    it "deletes reviews when parent snapshot is deleted" do
      snapshot_id = create_snapshot_for_reviews
      create_annotations_for_review(snapshot_id, 2)
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)

      # Verify review exists
      GalaxySnapshots::Database.list_snapshot_reviews(snapshot_id).size.should eq(1)

      # Delete the snapshot
      GalaxySnapshots::Database.delete_snapshot_by_number(1_i64, 1)

      # Reviews should be gone
      GalaxySnapshots::Database.list_snapshot_reviews(snapshot_id).should be_empty
    end

    it "deletes annotations when parent snapshot is deleted via cascade" do
      snapshot_id = create_snapshot_for_reviews
      create_annotations_for_review(snapshot_id, 2)
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)

      # Verify annotations are assigned
      anns = GalaxySnapshots::Database.list_snapshot_annotations(snapshot_id)
      anns.all? { |a| !a.snapshot_review_id.nil? }.should be_true

      # Delete the snapshot — cascades to reviews and annotations
      GalaxySnapshots::Database.delete_snapshot_by_number(1_i64, 1)
      GalaxySnapshots::Database.list_snapshot_annotations(snapshot_id).should be_empty
    end
  end

  describe "annotation review fields via list_annotations_for_review" do
    it "populates review_number on annotations assigned to a review" do
      snapshot_id = create_snapshot_for_reviews
      create_annotations_for_review(snapshot_id, 2)
      result = GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      review = result.not_nil![0]

      anns = GalaxySnapshots::Database.list_annotations_for_review(review.id)
      anns.size.should eq(2)
      anns.all? { |a| a.review_number == 1 }.should be_true
      anns.all? { |a| a.review_reviewed_at.nil? }.should be_true
    end

    it "populates reviewed_at after mark-reviewed" do
      snapshot_id = create_snapshot_for_reviews
      create_annotations_for_review(snapshot_id, 1)
      result = GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      review = result.not_nil![0]
      GalaxySnapshots::Database.mark_snapshot_review_reviewed(snapshot_id, review.number)

      anns = GalaxySnapshots::Database.list_annotations_for_review(review.id)
      anns[0].review_number.should eq(1)
      anns[0].review_reviewed_at.should_not be_nil
    end
  end

  describe "annotation snapshot_review_id field" do
    it "returns nil for annotations not assigned to a review" do
      snapshot_id = create_snapshot_for_reviews
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 2, "Unreviewed")

      ann = GalaxySnapshots::Database.get_snapshot_annotation(snapshot_id, 1)
      ann.not_nil!.snapshot_review_id.should be_nil
    end

    it "returns review id for annotations assigned to a review" do
      snapshot_id = create_snapshot_for_reviews
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 1, 2, "Will be reviewed")

      result = GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      review = result.not_nil![0]

      ann = GalaxySnapshots::Database.get_snapshot_annotation(snapshot_id, 1)
      ann.not_nil!.snapshot_review_id.should eq(review.id)
    end
  end
end
