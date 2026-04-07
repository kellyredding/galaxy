require "../spec_helper"

# Helper to create an artifact for review tests.
def create_artifact_for_reviews : Int64
  GalaxyArtifacts::Database.save_artifact(
    1_i64,
    title: "Test CSV",
    artifact_type: "csv",
    mime_type: "text/csv",
    original_filename: "test.csv",
    stored_path: "/tmp/stored/001_test.csv",
    source_path: "/tmp/test.csv",
    file_size: 100_i64,
    content_hash: "abc123",
  )
  artifact = GalaxyArtifacts::Database.get_artifact_by_number(1_i64, 1)
  artifact.not_nil!.id
end

# Helper to create annotations on an artifact for review tests.
def create_annotations_for_review(artifact_id : Int64, count : Int32 = 3)
  count.times do |i|
    GalaxyArtifacts::Database.save_annotation(
      artifact_id, "Annotation #{i + 1}",
      %({"type":"whole_file"}), "abc123",
    )
  end
end

describe GalaxyArtifacts::Database do
  # Clean database before each test
  before_each do
    db_path = GalaxyArtifacts::Database.database_path
    File.delete(db_path) if File.exists?(db_path)
  end

  describe ".save_review" do
    it "creates review with number 1 and assigns unreviewed annotations" do
      artifact_id = create_artifact_for_reviews
      create_annotations_for_review(artifact_id, 3)

      result = GalaxyArtifacts::Database.save_review(artifact_id)
      result.should_not be_nil
      review, count = result.not_nil!
      review.number.should eq(1)
      review.artifact_id.should eq(artifact_id)
      review.reviewed_at.should be_nil
      count.should eq(3)
    end

    it "returns nil when no unreviewed annotations exist" do
      artifact_id = create_artifact_for_reviews
      # No annotations at all
      result = GalaxyArtifacts::Database.save_review(artifact_id)
      result.should be_nil
    end

    it "returns nil after all annotations are assigned to a review" do
      artifact_id = create_artifact_for_reviews
      create_annotations_for_review(artifact_id, 2)

      # First review takes all annotations
      GalaxyArtifacts::Database.save_review(artifact_id)

      # Second attempt — no unreviewed annotations left
      result = GalaxyArtifacts::Database.save_review(artifact_id)
      result.should be_nil
    end

    it "assigns sequential numbers across multiple reviews" do
      artifact_id = create_artifact_for_reviews
      create_annotations_for_review(artifact_id, 2)

      r1 = GalaxyArtifacts::Database.save_review(artifact_id)
      r1.not_nil![0].number.should eq(1)

      # Add more annotations, then create another review
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "New annotation",
        %({"type":"whole_file"}), "abc123",
      )

      r2 = GalaxyArtifacts::Database.save_review(artifact_id)
      r2.not_nil![0].number.should eq(2)
      r2.not_nil![1].should eq(1) # Only 1 new annotation
    end

    it "only assigns annotations with null review_id" do
      artifact_id = create_artifact_for_reviews
      create_annotations_for_review(artifact_id, 3)

      # First review takes all 3
      r1 = GalaxyArtifacts::Database.save_review(artifact_id)
      r1.not_nil![1].should eq(3)

      # Add 1 more annotation
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "New one",
        %({"type":"whole_file"}), "abc123",
      )

      # Second review should only take the new one
      r2 = GalaxyArtifacts::Database.save_review(artifact_id)
      r2.not_nil![1].should eq(1)

      # Verify: review 1 has 3, review 2 has 1
      review1 = GalaxyArtifacts::Database.get_review(artifact_id, 1)
      review2 = GalaxyArtifacts::Database.get_review(artifact_id, 2)
      GalaxyArtifacts::Database.list_annotations_for_review(
        review1.not_nil!.id,
      ).size.should eq(3)
      GalaxyArtifacts::Database.list_annotations_for_review(
        review2.not_nil!.id,
      ).size.should eq(1)
    end

    it "returns nil for invalid artifact id" do
      result = GalaxyArtifacts::Database.save_review(0_i64)
      result.should be_nil
    end

    it "populates created_at and updated_at timestamps" do
      artifact_id = create_artifact_for_reviews
      create_annotations_for_review(artifact_id, 1)

      result = GalaxyArtifacts::Database.save_review(artifact_id)
      review = result.not_nil![0]
      review.created_at.should_not be_empty
      review.updated_at.should_not be_empty
    end
  end

  describe ".list_reviews" do
    it "lists all reviews ordered by number" do
      artifact_id = create_artifact_for_reviews
      create_annotations_for_review(artifact_id, 2)
      GalaxyArtifacts::Database.save_review(artifact_id)

      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Extra",
        %({"type":"whole_file"}), "abc123",
      )
      GalaxyArtifacts::Database.save_review(artifact_id)

      reviews = GalaxyArtifacts::Database.list_reviews(artifact_id)
      reviews.size.should eq(2)
      reviews[0].number.should eq(1)
      reviews[1].number.should eq(2)
    end

    it "filters to pending only when pending_only is true" do
      artifact_id = create_artifact_for_reviews
      create_annotations_for_review(artifact_id, 2)
      GalaxyArtifacts::Database.save_review(artifact_id)

      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Extra",
        %({"type":"whole_file"}), "abc123",
      )
      GalaxyArtifacts::Database.save_review(artifact_id)

      # Mark first review as reviewed
      GalaxyArtifacts::Database.mark_review_reviewed(artifact_id, 1)

      # All reviews
      all = GalaxyArtifacts::Database.list_reviews(artifact_id)
      all.size.should eq(2)

      # Pending only
      pending = GalaxyArtifacts::Database.list_reviews(
        artifact_id, pending_only: true)
      pending.size.should eq(1)
      pending[0].number.should eq(2)
    end

    it "returns empty array for artifact with no reviews" do
      artifact_id = create_artifact_for_reviews
      reviews = GalaxyArtifacts::Database.list_reviews(artifact_id)
      reviews.should be_empty
    end

    it "returns empty array for invalid artifact id" do
      reviews = GalaxyArtifacts::Database.list_reviews(0_i64)
      reviews.should be_empty
    end
  end

  describe ".get_review" do
    it "retrieves by artifact_id + number" do
      artifact_id = create_artifact_for_reviews
      create_annotations_for_review(artifact_id, 1)
      GalaxyArtifacts::Database.save_review(artifact_id)

      review = GalaxyArtifacts::Database.get_review(artifact_id, 1)
      review.should_not be_nil
      review.not_nil!.number.should eq(1)
      review.not_nil!.artifact_id.should eq(artifact_id)
    end

    it "returns nil for nonexistent number" do
      artifact_id = create_artifact_for_reviews
      result = GalaxyArtifacts::Database.get_review(artifact_id, 99)
      result.should be_nil
    end

    it "returns nil for invalid artifact id" do
      result = GalaxyArtifacts::Database.get_review(0_i64, 1)
      result.should be_nil
    end
  end

  describe ".mark_review_reviewed" do
    it "sets reviewed_at timestamp" do
      artifact_id = create_artifact_for_reviews
      create_annotations_for_review(artifact_id, 1)
      GalaxyArtifacts::Database.save_review(artifact_id)

      review = GalaxyArtifacts::Database.mark_review_reviewed(artifact_id, 1)
      review.should_not be_nil
      review.not_nil!.reviewed_at.should_not be_nil
    end

    it "is idempotent — calling again updates timestamp" do
      artifact_id = create_artifact_for_reviews
      create_annotations_for_review(artifact_id, 1)
      GalaxyArtifacts::Database.save_review(artifact_id)

      r1 = GalaxyArtifacts::Database.mark_review_reviewed(artifact_id, 1)
      first_reviewed_at = r1.not_nil!.reviewed_at

      sleep(1.1.seconds)

      r2 = GalaxyArtifacts::Database.mark_review_reviewed(artifact_id, 1)
      r2.not_nil!.reviewed_at.should_not eq(first_reviewed_at)
    end

    it "returns nil for nonexistent review" do
      artifact_id = create_artifact_for_reviews
      result = GalaxyArtifacts::Database.mark_review_reviewed(artifact_id, 99)
      result.should be_nil
    end

    it "returns nil for invalid artifact id" do
      result = GalaxyArtifacts::Database.mark_review_reviewed(0_i64, 1)
      result.should be_nil
    end
  end

  describe ".list_annotations_for_review" do
    it "returns annotations assigned to a specific review" do
      artifact_id = create_artifact_for_reviews
      create_annotations_for_review(artifact_id, 3)
      result = GalaxyArtifacts::Database.save_review(artifact_id)
      review = result.not_nil![0]

      annotations = GalaxyArtifacts::Database.list_annotations_for_review(review.id)
      annotations.size.should eq(3)
      annotations.all? { |a| a.artifact_review_id == review.id }.should be_true
    end

    it "returns annotations in number order" do
      artifact_id = create_artifact_for_reviews
      create_annotations_for_review(artifact_id, 3)
      GalaxyArtifacts::Database.save_review(artifact_id)

      review = GalaxyArtifacts::Database.get_review(artifact_id, 1)
      annotations = GalaxyArtifacts::Database.list_annotations_for_review(review.not_nil!.id)
      annotations[0].number.should eq(1)
      annotations[1].number.should eq(2)
      annotations[2].number.should eq(3)
    end

    it "returns empty array for nonexistent review id" do
      annotations = GalaxyArtifacts::Database.list_annotations_for_review(99999_i64)
      annotations.should be_empty
    end

    it "returns empty array for invalid review id" do
      annotations = GalaxyArtifacts::Database.list_annotations_for_review(0_i64)
      annotations.should be_empty
    end
  end

  describe "cascade delete" do
    it "deletes reviews when parent artifact is deleted" do
      artifact_id = create_artifact_for_reviews
      create_annotations_for_review(artifact_id, 2)
      GalaxyArtifacts::Database.save_review(artifact_id)

      GalaxyArtifacts::Database.list_reviews(artifact_id).size.should eq(1)

      GalaxyArtifacts::Database.delete_artifact_by_number(1_i64, 1)

      GalaxyArtifacts::Database.list_reviews(artifact_id).should be_empty
    end

    it "deletes annotations when parent artifact is deleted via cascade" do
      artifact_id = create_artifact_for_reviews
      create_annotations_for_review(artifact_id, 2)
      GalaxyArtifacts::Database.save_review(artifact_id)

      anns = GalaxyArtifacts::Database.list_annotations(artifact_id)
      anns.all? { |a| !a.artifact_review_id.nil? }.should be_true

      GalaxyArtifacts::Database.delete_artifact_by_number(1_i64, 1)
      GalaxyArtifacts::Database.list_annotations(artifact_id).should be_empty
    end
  end

  describe "annotation review fields via list_annotations_for_review" do
    it "populates review_number on assigned annotations" do
      artifact_id = create_artifact_for_reviews
      create_annotations_for_review(artifact_id, 2)
      result = GalaxyArtifacts::Database.save_review(artifact_id)
      review = result.not_nil![0]

      anns = GalaxyArtifacts::Database.list_annotations_for_review(review.id)
      anns.size.should eq(2)
      anns.all? { |a| a.review_number == 1 }.should be_true
      anns.all? { |a| a.review_reviewed_at.nil? }.should be_true
    end

    it "populates reviewed_at after mark-reviewed" do
      artifact_id = create_artifact_for_reviews
      create_annotations_for_review(artifact_id, 1)
      result = GalaxyArtifacts::Database.save_review(artifact_id)
      review = result.not_nil![0]
      GalaxyArtifacts::Database.mark_review_reviewed(
        artifact_id, review.number,
      )

      anns = GalaxyArtifacts::Database.list_annotations_for_review(review.id)
      anns[0].review_number.should eq(1)
      anns[0].review_reviewed_at.should_not be_nil
    end
  end

  describe "annotation artifact_review_id field" do
    it "returns nil for annotations not assigned to a review" do
      artifact_id = create_artifact_for_reviews
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Unreviewed",
        %({"type":"whole_file"}), "abc123",
      )

      ann = GalaxyArtifacts::Database.get_annotation(artifact_id, 1)
      ann.not_nil!.artifact_review_id.should be_nil
    end

    it "returns review id for annotations assigned to a review" do
      artifact_id = create_artifact_for_reviews
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Will be reviewed",
        %({"type":"whole_file"}), "abc123",
      )

      result = GalaxyArtifacts::Database.save_review(artifact_id)
      review = result.not_nil![0]

      ann = GalaxyArtifacts::Database.get_annotation(artifact_id, 1)
      ann.not_nil!.artifact_review_id.should eq(review.id)
    end
  end
end
