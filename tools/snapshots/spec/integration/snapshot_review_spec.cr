require "../spec_helper"

# Helper to create a snapshot and return its DB primary key ID.
def create_snapshot_for_review_cli : Int64
  GalaxySnapshots::Database.save_snapshot(1_i64, "Test snapshot", "Line 1\nLine 2\nLine 3\nLine 4\nLine 5")
  snapshot = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
  flush_wal
  snapshot.not_nil!.id
end

# Helper to create annotations for CLI review tests
def create_annotations_for_review_cli(snapshot_id : Int64, count : Int32 = 3)
  count.times do |i|
    GalaxySnapshots::Database.save_snapshot_annotation(
      snapshot_id, (i + 1).to_i, (i + 1).to_i, "Annotation #{i + 1}",
    )
  end
  flush_wal
end

describe "CLI snapshot review commands", tags: "integration" do
  describe "review create" do
    it "creates a review and assigns annotations" do
      snapshot_id = create_snapshot_for_review_cli
      create_annotations_for_review_cli(snapshot_id, 3)

      result = run_binary(
        ["review", "create",
         "--snapshot-id", snapshot_id.to_s],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["review"]["number"].as_i.should eq(1)
      parsed["review"]["snapshot_id"].as_i64.should eq(snapshot_id)
      parsed["review"]["reviewed_at"].raw.should be_nil
      parsed["annotation_count"].as_i.should eq(3)
    end

    it "fails when no unreviewed annotations exist" do
      snapshot_id = create_snapshot_for_review_cli

      result = run_binary(
        ["review", "create",
         "--snapshot-id", snapshot_id.to_s],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("no unreviewed annotations")
    end

    it "fails after all annotations assigned to a review" do
      snapshot_id = create_snapshot_for_review_cli
      create_annotations_for_review_cli(snapshot_id, 2)

      # First review takes all
      r1 = run_binary(
        ["review", "create",
         "--snapshot-id", snapshot_id.to_s],
      )
      r1[:status].should eq(0)

      # Second attempt fails
      r2 = run_binary(
        ["review", "create",
         "--snapshot-id", snapshot_id.to_s],
      )
      r2[:status].should_not eq(0)
      r2[:error].should contain("no unreviewed annotations")
    end
  end

  describe "review list" do
    it "lists reviews in human-readable format" do
      snapshot_id = create_snapshot_for_review_cli
      create_annotations_for_review_cli(snapshot_id, 2)
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      flush_wal

      result = run_binary(
        ["review", "list",
         "--snapshot-id", snapshot_id.to_s],
      )

      result[:status].should eq(0)
      result[:output].should contain("1 total")
      result[:output].should contain("#1")
      result[:output].should contain("2 annotations")
      result[:output].should contain("pending")
    end

    it "lists reviews in JSON format" do
      snapshot_id = create_snapshot_for_review_cli
      create_annotations_for_review_cli(snapshot_id, 2)
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      flush_wal

      result = run_binary(
        ["review", "list",
         "--snapshot-id", snapshot_id.to_s, "--json"],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      reviews = parsed["reviews"].as_a
      reviews.size.should eq(1)
      reviews[0]["number"].as_i.should eq(1)
      reviews[0]["annotation_count"].as_i.should eq(2)
      reviews[0]["reviewed_at"].raw.should be_nil
    end

    it "filters to pending with --pending flag" do
      snapshot_id = create_snapshot_for_review_cli
      create_annotations_for_review_cli(snapshot_id, 2)
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)

      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 4, 5, "Extra")
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)

      # Mark first as reviewed
      GalaxySnapshots::Database.mark_snapshot_review_reviewed(snapshot_id, 1)
      flush_wal

      result = run_binary(
        ["review", "list",
         "--snapshot-id", snapshot_id.to_s, "--json", "--pending"],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      reviews = parsed["reviews"].as_a
      reviews.size.should eq(1)
      reviews[0]["number"].as_i.should eq(2)
    end

    it "shows empty message when no reviews" do
      snapshot_id = create_snapshot_for_review_cli

      result = run_binary(
        ["review", "list",
         "--snapshot-id", snapshot_id.to_s],
      )

      result[:status].should eq(0)
      result[:output].should contain("No reviews")
    end
  end

  describe "review view" do
    it "shows review in human-readable format" do
      snapshot_id = create_snapshot_for_review_cli
      create_annotations_for_review_cli(snapshot_id, 2)
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      flush_wal

      result = run_binary(
        ["review", "view",
         "--snapshot-id", snapshot_id.to_s, "1"],
      )

      result[:status].should eq(0)
      result[:output].should contain("Review #1")
      result[:output].should contain("pending")
      result[:output].should contain("Snapshot: #1")
      result[:output].should contain("Annotations (2)")
    end

    it "returns full context in JSON format" do
      snapshot_id = create_snapshot_for_review_cli
      create_annotations_for_review_cli(snapshot_id, 2)
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      flush_wal

      result = run_binary(
        ["review", "view",
         "--snapshot-id", snapshot_id.to_s, "1", "--json"],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])

      # Review section
      parsed["review"]["number"].as_i.should eq(1)

      # Snapshot section with full content
      parsed["snapshot"]["id"].as_i64.should eq(snapshot_id)
      parsed["snapshot"]["title"].as_s.should eq("Test snapshot")
      parsed["snapshot"]["content"].as_s.should contain("Line 1")

      # Annotations section
      annotations = parsed["annotations"].as_a
      annotations.size.should eq(2)
      annotations[0]["content"].as_s.should eq("Annotation 1")
    end

    it "errors for nonexistent review number" do
      snapshot_id = create_snapshot_for_review_cli

      result = run_binary(
        ["review", "view",
         "--snapshot-id", snapshot_id.to_s, "99"],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end

    it "errors when review number is missing" do
      snapshot_id = create_snapshot_for_review_cli

      result = run_binary(
        ["review", "view",
         "--snapshot-id", snapshot_id.to_s],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("review number is required")
    end
  end

  describe "review mark-reviewed" do
    it "sets reviewed_at and returns updated JSON" do
      snapshot_id = create_snapshot_for_review_cli
      create_annotations_for_review_cli(snapshot_id, 1)
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      flush_wal

      result = run_binary(
        ["review", "mark-reviewed",
         "--snapshot-id", snapshot_id.to_s, "1"],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["review"]["number"].as_i.should eq(1)
      parsed["review"]["reviewed_at"].as_s?.should_not be_nil
    end

    it "is idempotent" do
      snapshot_id = create_snapshot_for_review_cli
      create_annotations_for_review_cli(snapshot_id, 1)
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      flush_wal

      r1 = run_binary(
        ["review", "mark-reviewed",
         "--snapshot-id", snapshot_id.to_s, "1"],
      )
      r2 = run_binary(
        ["review", "mark-reviewed",
         "--snapshot-id", snapshot_id.to_s, "1"],
      )

      r1[:status].should eq(0)
      r2[:status].should eq(0)
    end

    it "errors for nonexistent review" do
      snapshot_id = create_snapshot_for_review_cli

      result = run_binary(
        ["review", "mark-reviewed",
         "--snapshot-id", snapshot_id.to_s, "99"],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end
  end

  describe "review has-pending" do
    it "returns true with count when unreviewed annotations exist" do
      snapshot_id = create_snapshot_for_review_cli
      create_annotations_for_review_cli(snapshot_id, 3)

      result = run_binary(
        ["review", "has-pending",
         "--snapshot-id", snapshot_id.to_s],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["has_pending"].as_bool.should be_true
      parsed["count"].as_i.should eq(3)
      parsed["snapshot_id"].as_i64.should eq(snapshot_id)
    end

    it "returns false when all annotations are assigned" do
      snapshot_id = create_snapshot_for_review_cli
      create_annotations_for_review_cli(snapshot_id, 2)
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      flush_wal

      result = run_binary(
        ["review", "has-pending",
         "--snapshot-id", snapshot_id.to_s],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["has_pending"].as_bool.should be_false
      parsed["count"].as_i.should eq(0)
    end

    it "returns true after new annotation added post-review" do
      snapshot_id = create_snapshot_for_review_cli
      create_annotations_for_review_cli(snapshot_id, 1)
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)

      # Add a new annotation after review
      GalaxySnapshots::Database.save_snapshot_annotation(snapshot_id, 4, 5, "New one")
      flush_wal

      result = run_binary(
        ["review", "has-pending",
         "--snapshot-id", snapshot_id.to_s],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["has_pending"].as_bool.should be_true
      parsed["count"].as_i.should eq(1)
    end
  end

  describe "alternative identifier resolution" do
    it "resolves --ledger-session-id + --snapshot for review commands" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "Alt resolve", "content")
      snapshot = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
      snapshot_id = snapshot.not_nil!.id

      create_annotations_for_review_cli(snapshot_id, 2)

      # Create via alternative identifiers
      result = run_binary(
        ["review", "create",
         "--ledger-session-id", "1",
         "--snapshot", "1"],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["review"]["snapshot_id"].as_i64.should eq(snapshot_id)

      # List via alternative identifiers
      list_result = run_binary(
        ["review", "list",
         "--ledger-session-id", "1",
         "--snapshot", "1", "--json"],
      )

      list_result[:status].should eq(0)
      list_parsed = JSON.parse(list_result[:output])
      list_parsed["reviews"].as_a.size.should eq(1)
    end
  end

  describe "annotation JSON review fields" do
    it "includes review_number and review_reviewed_at in annotation JSON" do
      snapshot_id = create_snapshot_for_review_cli

      # Create annotation — should have null review fields
      r1 = run_binary([
        "annotation", "create",
        "--snapshot-id", snapshot_id.to_s,
        "--start-line", "1", "--end-line", "2",
      ], stdin: "Test annotation")
      r1[:status].should eq(0)
      parsed = JSON.parse(r1[:output])
      parsed["annotation"]["review_number"].raw.should be_nil
      parsed["annotation"]["review_reviewed_at"].raw.should be_nil

      # Create review — assigns annotation
      GalaxySnapshots::Database.save_snapshot_review(snapshot_id)
      flush_wal

      # View annotation — should now have review fields
      r2 = run_binary([
        "annotation", "view",
        "--snapshot-id", snapshot_id.to_s, "1",
      ])
      r2[:status].should eq(0)
      parsed2 = JSON.parse(r2[:output])
      parsed2["annotation"]["review_number"].as_i.should eq(1)
      parsed2["annotation"]["review_reviewed_at"].raw.should be_nil

      # Mark reviewed and check again
      GalaxySnapshots::Database.mark_snapshot_review_reviewed(snapshot_id, 1)
      flush_wal

      r3 = run_binary([
        "annotation", "view",
        "--snapshot-id", snapshot_id.to_s, "1",
      ])
      r3[:status].should eq(0)
      parsed3 = JSON.parse(r3[:output])
      parsed3["annotation"]["review_number"].as_i.should eq(1)
      parsed3["annotation"]["review_reviewed_at"].as_s?.should_not be_nil
    end
  end

  describe "review help" do
    it "shows review help" do
      result = run_binary(["review", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("Manage snapshot reviews")
      result[:output].should contain("create")
      result[:output].should contain("list")
      result[:output].should contain("view")
      result[:output].should contain("mark-reviewed")
      result[:output].should contain("has-pending")
    end

    it "shows review create help" do
      result = run_binary(["review", "create", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("--snapshot-id")
      result[:output].should contain("unreviewed annotations")
    end

    it "shows review list help" do
      result = run_binary(["review", "list", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("--pending")
      result[:output].should contain("--json")
    end

    it "shows review view help" do
      result = run_binary(["review", "view", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("NUMBER")
      result[:output].should contain("--json")
    end

    it "shows review has-pending help" do
      result = run_binary(["review", "has-pending", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("unreviewed annotations")
    end

    it "shows review mark-reviewed help" do
      result = run_binary(["review", "mark-reviewed", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("NUMBER")
      result[:output].should contain("Idempotent")
    end
  end

  describe "end-to-end review workflow" do
    it "creates annotations, submits review, views, marks reviewed" do
      snapshot_id = create_snapshot_for_review_cli

      # Create annotations
      create_annotations_for_review_cli(snapshot_id, 3)

      # Check has-pending — should be true
      hp1 = run_binary(
        ["review", "has-pending",
         "--snapshot-id", snapshot_id.to_s],
      )
      hp1[:status].should eq(0)
      JSON.parse(hp1[:output])["has_pending"].as_bool.should be_true

      # Create review
      create_result = run_binary(
        ["review", "create",
         "--snapshot-id", snapshot_id.to_s],
      )
      create_result[:status].should eq(0)
      JSON.parse(create_result[:output])["annotation_count"].as_i.should eq(3)

      # Check has-pending — should be false now
      hp2 = run_binary(
        ["review", "has-pending",
         "--snapshot-id", snapshot_id.to_s],
      )
      JSON.parse(hp2[:output])["has_pending"].as_bool.should be_false

      # List pending reviews
      list_result = run_binary(
        ["review", "list",
         "--snapshot-id", snapshot_id.to_s, "--json", "--pending"],
      )
      list_result[:status].should eq(0)
      reviews = JSON.parse(list_result[:output])["reviews"].as_a
      reviews.size.should eq(1)

      # View review with full context
      view_result = run_binary(
        ["review", "view",
         "--snapshot-id", snapshot_id.to_s, "1", "--json"],
      )
      view_result[:status].should eq(0)
      view_parsed = JSON.parse(view_result[:output])
      view_parsed["annotations"].as_a.size.should eq(3)
      view_parsed["snapshot"]["content"].as_s.should contain("Line 1")

      # Mark reviewed
      mark_result = run_binary(
        ["review", "mark-reviewed",
         "--snapshot-id", snapshot_id.to_s, "1"],
      )
      mark_result[:status].should eq(0)
      JSON.parse(mark_result[:output])["review"]["reviewed_at"].as_s?.should_not be_nil

      # List pending — should be empty now
      list_after = run_binary(
        ["review", "list",
         "--snapshot-id", snapshot_id.to_s, "--json", "--pending"],
      )
      JSON.parse(list_after[:output])["reviews"].as_a.size.should eq(0)
    end
  end
end
