require "../spec_helper"

# Helper to create an artifact for annotation tests.
def create_artifact_for_annotations : Int64
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

describe GalaxyArtifacts::Database do
  # Clean database before each test
  before_each do
    db_path = GalaxyArtifacts::Database.database_path
    File.delete(db_path) if File.exists?(db_path)
  end

  describe ".save_annotation" do
    it "saves and returns annotation with number 1" do
      artifact_id = create_artifact_for_annotations
      result = GalaxyArtifacts::Database.save_annotation(
        artifact_id,
        "Test note",
        %({"type":"line_range","start_line":1,"end_line":3}),
        "abc123",
      )
      result.should_not be_nil
      ann = result.not_nil!
      ann.number.should eq(1)
      ann.content.should eq("Test note")
      ann.content_hash.should eq("abc123")
      ann.stale.should be_false
      ann.artifact_id.should eq(artifact_id)
    end

    it "increments numbers sequentially within the same artifact" do
      artifact_id = create_artifact_for_annotations

      a1 = GalaxyArtifacts::Database.save_annotation(
        artifact_id, "First",
        %({"type":"line_range","start_line":1,"end_line":2}),
        "abc123",
      )
      a2 = GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Second",
        %({"type":"line_range","start_line":3,"end_line":4}),
        "abc123",
      )
      a3 = GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Third",
        %({"type":"line_range","start_line":5,"end_line":5}),
        "abc123",
      )

      a1.not_nil!.number.should eq(1)
      a2.not_nil!.number.should eq(2)
      a3.not_nil!.number.should eq(3)
    end

    it "starts numbering at 1 for a new artifact" do
      GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "A", artifact_type: "text",
        mime_type: "text/plain",
        original_filename: "a.txt", stored_path: "",
        source_path: "/tmp/a.txt",
        file_size: 10_i64, content_hash: "h1",
      )
      GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "B", artifact_type: "text",
        mime_type: "text/plain",
        original_filename: "b.txt", stored_path: "",
        source_path: "/tmp/b.txt",
        file_size: 10_i64, content_hash: "h2",
      )
      art_a = GalaxyArtifacts::Database.get_artifact_by_number(1_i64, 1)
      art_b = GalaxyArtifacts::Database.get_artifact_by_number(1_i64, 2)

      GalaxyArtifacts::Database.save_annotation(
        art_a.not_nil!.id, "On A",
        %({"type":"whole_file"}), "h1",
      )
      GalaxyArtifacts::Database.save_annotation(
        art_a.not_nil!.id, "Another on A",
        %({"type":"whole_file"}), "h1",
      )

      ann_b = GalaxyArtifacts::Database.save_annotation(
        art_b.not_nil!.id, "On B",
        %({"type":"whole_file"}), "h2",
      )
      ann_b.not_nil!.number.should eq(1)
    end

    it "stores anchor_data and content_hash correctly" do
      artifact_id = create_artifact_for_annotations
      anchor = %({"type":"row_range","start_row":10,"end_row":22})
      result = GalaxyArtifacts::Database.save_annotation(
        artifact_id,
        "Multi-line\nannotation content",
        anchor,
        "hash_v1",
      )
      ann = result.not_nil!
      ann.anchor_data.should eq(anchor)
      ann.content_hash.should eq("hash_v1")
      ann.content.should eq("Multi-line\nannotation content")
    end

    it "returns nil for invalid artifact id" do
      result = GalaxyArtifacts::Database.save_annotation(
        0_i64, "Bad", %({"type":"whole_file"}), "",
      )
      result.should be_nil
    end

    it "populates created_at and updated_at timestamps" do
      artifact_id = create_artifact_for_annotations
      result = GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Timestamped",
        %({"type":"whole_file"}), "abc123",
      )
      ann = result.not_nil!
      ann.created_at.should_not be_empty
      ann.updated_at.should_not be_empty
    end
  end

  describe ".list_annotations" do
    it "returns annotations in number order" do
      artifact_id = create_artifact_for_annotations
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "First",
        %({"type":"line_range","start_line":1,"end_line":2}),
        "abc123",
      )
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Second",
        %({"type":"line_range","start_line":3,"end_line":4}),
        "abc123",
      )
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Third",
        %({"type":"line_range","start_line":5,"end_line":5}),
        "abc123",
      )

      annotations = GalaxyArtifacts::Database.list_annotations(artifact_id)
      annotations.size.should eq(3)
      annotations[0].number.should eq(1)
      annotations[1].number.should eq(2)
      annotations[2].number.should eq(3)
    end

    it "returns empty array for artifact with no annotations" do
      artifact_id = create_artifact_for_annotations
      annotations = GalaxyArtifacts::Database.list_annotations(artifact_id)
      annotations.should be_empty
    end

    it "returns empty array for invalid artifact id" do
      annotations = GalaxyArtifacts::Database.list_annotations(0_i64)
      annotations.should be_empty
    end

    it "only returns annotations for the specified artifact" do
      GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "A", artifact_type: "text",
        mime_type: "text/plain",
        original_filename: "a.txt", stored_path: "",
        source_path: "/tmp/a.txt",
        file_size: 10_i64, content_hash: "h1",
      )
      GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "B", artifact_type: "text",
        mime_type: "text/plain",
        original_filename: "b.txt", stored_path: "",
        source_path: "/tmp/b.txt",
        file_size: 10_i64, content_hash: "h2",
      )
      art_a = GalaxyArtifacts::Database.get_artifact_by_number(1_i64, 1)
      art_b = GalaxyArtifacts::Database.get_artifact_by_number(1_i64, 2)

      GalaxyArtifacts::Database.save_annotation(
        art_a.not_nil!.id, "On A",
        %({"type":"whole_file"}), "h1",
      )
      GalaxyArtifacts::Database.save_annotation(
        art_b.not_nil!.id, "On B",
        %({"type":"whole_file"}), "h2",
      )

      a_anns = GalaxyArtifacts::Database.list_annotations(art_a.not_nil!.id)
      a_anns.size.should eq(1)
      a_anns[0].content.should eq("On A")
    end
  end

  describe ".get_annotation" do
    it "returns annotation by artifact id and number" do
      artifact_id = create_artifact_for_annotations
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Target annotation",
        %({"type":"line_range","start_line":1,"end_line":3}),
        "abc123",
      )

      result = GalaxyArtifacts::Database.get_annotation(artifact_id, 1)
      result.should_not be_nil
      ann = result.not_nil!
      ann.content.should eq("Target annotation")
      ann.number.should eq(1)
      ann.artifact_id.should eq(artifact_id)
    end

    it "returns nil for non-existent number" do
      artifact_id = create_artifact_for_annotations
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Only one",
        %({"type":"whole_file"}), "abc123",
      )

      result = GalaxyArtifacts::Database.get_annotation(artifact_id, 99)
      result.should be_nil
    end

    it "returns nil for invalid artifact id" do
      result = GalaxyArtifacts::Database.get_annotation(0_i64, 1)
      result.should be_nil
    end

    it "does not return annotation from a different artifact" do
      GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "A", artifact_type: "text",
        mime_type: "text/plain",
        original_filename: "a.txt", stored_path: "",
        source_path: "/tmp/a.txt",
        file_size: 10_i64, content_hash: "h1",
      )
      GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "B", artifact_type: "text",
        mime_type: "text/plain",
        original_filename: "b.txt", stored_path: "",
        source_path: "/tmp/b.txt",
        file_size: 10_i64, content_hash: "h2",
      )
      art_a = GalaxyArtifacts::Database.get_artifact_by_number(1_i64, 1)
      art_b = GalaxyArtifacts::Database.get_artifact_by_number(1_i64, 2)

      GalaxyArtifacts::Database.save_annotation(
        art_a.not_nil!.id, "On A only",
        %({"type":"whole_file"}), "h1",
      )

      result = GalaxyArtifacts::Database.get_annotation(art_b.not_nil!.id, 1)
      result.should be_nil
    end
  end

  describe ".update_annotation" do
    it "updates content and returns the updated annotation" do
      artifact_id = create_artifact_for_annotations
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Original content",
        %({"type":"line_range","start_line":1,"end_line":3}),
        "abc123",
      )

      updated = GalaxyArtifacts::Database.update_annotation(artifact_id, 1, "Updated content")
      updated.should_not be_nil
      updated.not_nil!.content.should eq("Updated content")
      updated.not_nil!.number.should eq(1)
    end

    it "updates updated_at timestamp" do
      artifact_id = create_artifact_for_annotations
      created = GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Original",
        %({"type":"whole_file"}), "abc123",
      )
      original_updated_at = created.not_nil!.updated_at

      sleep(1.1.seconds)

      updated = GalaxyArtifacts::Database.update_annotation(artifact_id, 1, "Changed")
      updated.not_nil!.updated_at.should_not eq(original_updated_at)
    end

    it "does not change anchor_data or content_hash" do
      artifact_id = create_artifact_for_annotations
      anchor = %({"type":"line_range","start_line":5,"end_line":10})
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Original", anchor, "hash_v1",
      )

      updated = GalaxyArtifacts::Database.update_annotation(artifact_id, 1, "New content")
      updated.not_nil!.anchor_data.should eq(anchor)
      updated.not_nil!.content_hash.should eq("hash_v1")
    end

    it "returns nil for non-existent annotation" do
      artifact_id = create_artifact_for_annotations
      updated = GalaxyArtifacts::Database.update_annotation(artifact_id, 99, "No target")
      updated.should be_nil
    end

    it "returns nil for invalid artifact id" do
      updated = GalaxyArtifacts::Database.update_annotation(0_i64, 1, "Bad")
      updated.should be_nil
    end
  end

  describe ".delete_annotation" do
    it "deletes and returns true" do
      artifact_id = create_artifact_for_annotations
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "To delete",
        %({"type":"whole_file"}), "abc123",
      )

      result = GalaxyArtifacts::Database.delete_annotation(artifact_id, 1)
      result.should be_true

      # Verify it's gone
      GalaxyArtifacts::Database.get_annotation(artifact_id, 1).should be_nil
    end

    it "returns false for non-existent number" do
      artifact_id = create_artifact_for_annotations
      result = GalaxyArtifacts::Database.delete_annotation(artifact_id, 99)
      result.should be_false
    end

    it "returns false for invalid artifact id" do
      result = GalaxyArtifacts::Database.delete_annotation(0_i64, 1)
      result.should be_false
    end
  end

  describe ".mark_annotations_stale" do
    it "marks non-stale annotations as stale" do
      artifact_id = create_artifact_for_annotations
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "First",
        %({"type":"whole_file"}), "abc123",
      )
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Second",
        %({"type":"whole_file"}), "abc123",
      )

      count = GalaxyArtifacts::Database.mark_annotations_stale(artifact_id)
      count.should eq(2)

      anns = GalaxyArtifacts::Database.list_annotations(artifact_id)
      anns.all?(&.stale).should be_true
    end

    it "does not double-mark already stale annotations" do
      artifact_id = create_artifact_for_annotations
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "First",
        %({"type":"whole_file"}), "abc123",
      )

      GalaxyArtifacts::Database.mark_annotations_stale(artifact_id)
      count = GalaxyArtifacts::Database.mark_annotations_stale(artifact_id)
      count.should eq(0)
    end

    it "returns 0 for artifact with no annotations" do
      artifact_id = create_artifact_for_annotations
      count = GalaxyArtifacts::Database.mark_annotations_stale(artifact_id)
      count.should eq(0)
    end

    it "returns 0 for invalid artifact id" do
      count = GalaxyArtifacts::Database.mark_annotations_stale(0_i64)
      count.should eq(0)
    end
  end

  describe ".count_unreviewed_annotations" do
    it "returns correct count of unreviewed annotations" do
      artifact_id = create_artifact_for_annotations
      3.times do |i|
        GalaxyArtifacts::Database.save_annotation(
          artifact_id, "Ann #{i + 1}",
          %({"type":"whole_file"}), "abc123",
        )
      end

      count = GalaxyArtifacts::Database.count_unreviewed_annotations(artifact_id)
      count.should eq(3)
    end

    it "returns 0 when all are assigned to reviews" do
      artifact_id = create_artifact_for_annotations
      2.times do |i|
        GalaxyArtifacts::Database.save_annotation(
          artifact_id, "Ann #{i + 1}",
          %({"type":"whole_file"}), "abc123",
        )
      end
      GalaxyArtifacts::Database.save_review(artifact_id)

      count = GalaxyArtifacts::Database.count_unreviewed_annotations(artifact_id)
      count.should eq(0)
    end

    it "does not count stale annotations" do
      artifact_id = create_artifact_for_annotations
      2.times do |i|
        GalaxyArtifacts::Database.save_annotation(
          artifact_id, "Ann #{i + 1}",
          %({"type":"whole_file"}), "abc123",
        )
      end
      GalaxyArtifacts::Database.mark_annotations_stale(artifact_id)
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Fresh",
        %({"type":"whole_file"}), "abc123",
      )

      count = GalaxyArtifacts::Database.count_unreviewed_annotations(artifact_id)
      count.should eq(1)
    end

    it "returns 0 for artifact with no annotations" do
      artifact_id = create_artifact_for_annotations
      count = GalaxyArtifacts::Database.count_unreviewed_annotations(artifact_id)
      count.should eq(0)
    end

    it "returns 0 for invalid artifact id" do
      count = GalaxyArtifacts::Database.count_unreviewed_annotations(0_i64)
      count.should eq(0)
    end
  end

  describe "cascade delete" do
    it "deletes annotations when parent artifact is deleted" do
      artifact_id = create_artifact_for_annotations
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Will be cascaded",
        %({"type":"whole_file"}), "abc123",
      )
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Also cascaded",
        %({"type":"whole_file"}), "abc123",
      )

      GalaxyArtifacts::Database.list_annotations(artifact_id).size.should eq(2)

      GalaxyArtifacts::Database.delete_artifact_by_number(1_i64, 1)

      GalaxyArtifacts::Database.list_annotations(artifact_id).should be_empty
    end
  end

  describe "review fields on annotations" do
    it "returns nil review fields for unreviewed annotations" do
      artifact_id = create_artifact_for_annotations
      result = GalaxyArtifacts::Database.save_annotation(
        artifact_id, "test note",
        %({"type":"whole_file"}), "abc123",
      )
      result.should_not be_nil
      a = result.not_nil!
      a.review_number.should be_nil
      a.review_reviewed_at.should be_nil
      a.artifact_review_id.should be_nil
    end

    it "returns review fields via list after review assignment" do
      artifact_id = create_artifact_for_annotations
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "note",
        %({"type":"whole_file"}), "abc123",
      )
      GalaxyArtifacts::Database.save_review(artifact_id)

      anns = GalaxyArtifacts::Database.list_annotations(artifact_id)
      anns.size.should eq(1)
      anns[0].review_number.should eq(1)
      anns[0].review_reviewed_at.should be_nil
      anns[0].artifact_review_id.should_not be_nil
    end

    it "returns review fields via get after review assignment" do
      artifact_id = create_artifact_for_annotations
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "note",
        %({"type":"whole_file"}), "abc123",
      )
      GalaxyArtifacts::Database.save_review(artifact_id)

      ann = GalaxyArtifacts::Database.get_annotation(artifact_id, 1)
      ann.should_not be_nil
      ann.not_nil!.review_number.should eq(1)
      ann.not_nil!.review_reviewed_at.should be_nil
    end

    it "returns review fields via update after review assignment" do
      artifact_id = create_artifact_for_annotations
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "original",
        %({"type":"whole_file"}), "abc123",
      )
      GalaxyArtifacts::Database.save_review(artifact_id)

      updated = GalaxyArtifacts::Database.update_annotation(
        artifact_id, 1, "changed",
      )
      updated.should_not be_nil
      updated.not_nil!.review_number.should eq(1)
      updated.not_nil!.review_reviewed_at.should be_nil
    end

    it "populates reviewed_at after mark-reviewed" do
      artifact_id = create_artifact_for_annotations
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "note",
        %({"type":"whole_file"}), "abc123",
      )
      result = GalaxyArtifacts::Database.save_review(artifact_id)
      review = result.not_nil![0]
      GalaxyArtifacts::Database.mark_review_reviewed(
        artifact_id, review.number,
      )

      anns = GalaxyArtifacts::Database.list_annotations(artifact_id)
      anns[0].review_number.should eq(1)
      anns[0].review_reviewed_at.should_not be_nil
    end
  end

  describe "number gap behavior" do
    it "assigns MAX+1 after deletion (does not reuse numbers)" do
      artifact_id = create_artifact_for_annotations
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "First",
        %({"type":"whole_file"}), "abc123",
      )
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Second",
        %({"type":"whole_file"}), "abc123",
      )
      GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Third",
        %({"type":"whole_file"}), "abc123",
      )

      # Delete #2
      GalaxyArtifacts::Database.delete_annotation(artifact_id, 2)

      # Next annotation should be #4, not #2
      a4 = GalaxyArtifacts::Database.save_annotation(
        artifact_id, "Fourth",
        %({"type":"whole_file"}), "abc123",
      )
      a4.not_nil!.number.should eq(4)
    end
  end
end
