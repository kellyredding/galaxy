require "../spec_helper"

# Helper to save an artifact for review integration tests.
def save_artifact_for_rev_integration : Int64
  source = create_test_file("rev-test.csv", "name,value\nfoo,42")
  run_binary([
    "save", "--ledger-session-id", "1",
    "--source-path", source, "--title", "Review test",
    "--artifact-type", "csv", "--mime-type", "text/csv",
  ])
  flush_wal
  artifact = GalaxyArtifacts::Database.get_artifact_by_number(1_i64, 1)
  artifact.not_nil!.id
end

# Helper to create annotations via CLI.
def create_annotation_via_cli(artifact_id : Int64, content : String)
  run_binary(
    ["annotation", "create", "--artifact-id", artifact_id.to_s],
    stdin: %({"anchor_data":{"type":"whole_file"},"content":"#{content}"}),
  )
end

describe "CLI review commands", tags: "integration" do
  describe "review create" do
    it "creates a review batching unreviewed annotations" do
      artifact_id = save_artifact_for_rev_integration
      create_annotation_via_cli(artifact_id, "Note 1")
      create_annotation_via_cli(artifact_id, "Note 2")
      create_annotation_via_cli(artifact_id, "Note 3")

      result = run_binary(
        ["review", "create", "--artifact-id", artifact_id.to_s],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["review"]["number"].as_i.should eq(1)
      parsed["annotation_count"].as_i.should eq(3)
    end

    it "errors when no unreviewed annotations" do
      artifact_id = save_artifact_for_rev_integration

      result = run_binary(
        ["review", "create", "--artifact-id", artifact_id.to_s],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("no unreviewed annotations")
    end

    it "errors after all annotations are reviewed" do
      artifact_id = save_artifact_for_rev_integration
      create_annotation_via_cli(artifact_id, "Only one")

      run_binary(
        ["review", "create", "--artifact-id", artifact_id.to_s],
      )

      result = run_binary(
        ["review", "create", "--artifact-id", artifact_id.to_s],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("no unreviewed annotations")
    end

    it "only batches new annotations in second review" do
      artifact_id = save_artifact_for_rev_integration
      create_annotation_via_cli(artifact_id, "Batch 1a")
      create_annotation_via_cli(artifact_id, "Batch 1b")

      r1 = run_binary(
        ["review", "create", "--artifact-id", artifact_id.to_s],
      )
      JSON.parse(r1[:output])["annotation_count"].as_i.should eq(2)

      create_annotation_via_cli(artifact_id, "Batch 2a")

      r2 = run_binary(
        ["review", "create", "--artifact-id", artifact_id.to_s],
      )
      parsed = JSON.parse(r2[:output])
      parsed["review"]["number"].as_i.should eq(2)
      parsed["annotation_count"].as_i.should eq(1)
    end
  end

  describe "review list" do
    it "lists reviews in human-readable format" do
      artifact_id = save_artifact_for_rev_integration
      create_annotation_via_cli(artifact_id, "Note")

      run_binary(
        ["review", "create", "--artifact-id", artifact_id.to_s],
      )

      result = run_binary(
        ["review", "list", "--artifact-id", artifact_id.to_s],
      )

      result[:status].should eq(0)
      result[:output].should contain("1 total")
      result[:output].should contain("#1")
      result[:output].should contain("pending")
    end

    it "lists reviews in JSON format" do
      artifact_id = save_artifact_for_rev_integration
      create_annotation_via_cli(artifact_id, "Note")

      run_binary(
        ["review", "create", "--artifact-id", artifact_id.to_s],
      )

      result = run_binary(
        ["review", "list", "--artifact-id", artifact_id.to_s, "--json"],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      reviews = parsed["reviews"].as_a
      reviews.size.should eq(1)
      reviews[0]["number"].as_i.should eq(1)
      reviews[0]["annotation_count"].as_i.should eq(1)
    end

    it "filters with --pending flag" do
      artifact_id = save_artifact_for_rev_integration
      create_annotation_via_cli(artifact_id, "Note 1")

      run_binary(
        ["review", "create", "--artifact-id", artifact_id.to_s],
      )

      # Mark as reviewed
      run_binary(
        ["review", "mark-reviewed", "--artifact-id", artifact_id.to_s, "1"],
      )

      result = run_binary(
        ["review", "list", "--artifact-id", artifact_id.to_s, "--pending"],
      )

      result[:status].should eq(0)
      result[:output].should contain("No pending reviews")
    end

    it "shows empty message when no reviews" do
      artifact_id = save_artifact_for_rev_integration

      result = run_binary(
        ["review", "list", "--artifact-id", artifact_id.to_s],
      )

      result[:status].should eq(0)
      result[:output].should contain("No reviews")
    end
  end

  describe "review view" do
    it "shows review with annotations" do
      artifact_id = save_artifact_for_rev_integration
      create_annotation_via_cli(artifact_id, "View this")

      run_binary(
        ["review", "create", "--artifact-id", artifact_id.to_s],
      )

      result = run_binary(
        ["review", "view", "--artifact-id", artifact_id.to_s, "1"],
      )

      result[:status].should eq(0)
      result[:output].should contain("Review #1")
      result[:output].should contain("pending")
      result[:output].should contain("View this")
    end

    it "shows review in JSON format with artifact context" do
      artifact_id = save_artifact_for_rev_integration
      create_annotation_via_cli(artifact_id, "JSON view")

      run_binary(
        ["review", "create", "--artifact-id", artifact_id.to_s],
      )

      result = run_binary(
        ["review", "view", "--artifact-id", artifact_id.to_s, "1", "--json"],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["review"]["number"].as_i.should eq(1)
      parsed["artifact"]["title"].as_s.should eq("Review test")
      parsed["annotations"].as_a.size.should eq(1)
      parsed["annotations"][0]["content"].as_s.should eq("JSON view")
    end

    it "errors when review not found" do
      artifact_id = save_artifact_for_rev_integration

      result = run_binary(
        ["review", "view", "--artifact-id", artifact_id.to_s, "99"],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end

    it "errors when number not provided" do
      artifact_id = save_artifact_for_rev_integration

      result = run_binary(
        ["review", "view", "--artifact-id", artifact_id.to_s],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("review number is required")
    end
  end

  describe "review mark-reviewed" do
    it "marks review as reviewed" do
      artifact_id = save_artifact_for_rev_integration
      create_annotation_via_cli(artifact_id, "Note")

      run_binary(
        ["review", "create", "--artifact-id", artifact_id.to_s],
      )

      result = run_binary(
        ["review", "mark-reviewed", "--artifact-id", artifact_id.to_s, "1"],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["review"]["reviewed_at"].as_s?.should_not be_nil
    end

    it "errors when review not found" do
      artifact_id = save_artifact_for_rev_integration

      result = run_binary(
        ["review", "mark-reviewed", "--artifact-id", artifact_id.to_s, "99"],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end
  end

  describe "review has-pending" do
    it "returns true when unreviewed annotations exist" do
      artifact_id = save_artifact_for_rev_integration
      create_annotation_via_cli(artifact_id, "Pending")

      result = run_binary(
        ["review", "has-pending", "--artifact-id", artifact_id.to_s],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["has_pending"].as_bool.should be_true
      parsed["count"].as_i.should eq(1)
    end

    it "returns false after all annotations are reviewed" do
      artifact_id = save_artifact_for_rev_integration
      create_annotation_via_cli(artifact_id, "Will review")

      run_binary(
        ["review", "create", "--artifact-id", artifact_id.to_s],
      )

      result = run_binary(
        ["review", "has-pending", "--artifact-id", artifact_id.to_s],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["has_pending"].as_bool.should be_false
      parsed["count"].as_i.should eq(0)
    end

    it "returns false when no annotations at all" do
      artifact_id = save_artifact_for_rev_integration

      result = run_binary(
        ["review", "has-pending", "--artifact-id", artifact_id.to_s],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["has_pending"].as_bool.should be_false
      parsed["count"].as_i.should eq(0)
    end
  end

  describe "review help" do
    it "shows review help" do
      result = run_binary(["review", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("review")
      result[:output].should contain("create")
      result[:output].should contain("list")
      result[:output].should contain("view")
      result[:output].should contain("mark-reviewed")
      result[:output].should contain("has-pending")
    end
  end

  describe "end-to-end workflow" do
    it "full annotation-review lifecycle" do
      artifact_id = save_artifact_for_rev_integration

      # Create 3 annotations
      create_annotation_via_cli(artifact_id, "Fix error handling")
      create_annotation_via_cli(artifact_id, "Add logging")
      create_annotation_via_cli(artifact_id, "Refactor loop")

      # has-pending should be true with count 3
      pending = run_binary(
        ["review", "has-pending", "--artifact-id", artifact_id.to_s],
      )
      JSON.parse(pending[:output])["count"].as_i.should eq(3)

      # Create review — batches all 3
      review = run_binary(
        ["review", "create", "--artifact-id", artifact_id.to_s],
      )
      JSON.parse(review[:output])["annotation_count"].as_i.should eq(3)

      # has-pending should now be false
      pending = run_binary(
        ["review", "has-pending", "--artifact-id", artifact_id.to_s],
      )
      JSON.parse(pending[:output])["has_pending"].as_bool.should be_false

      # Create new annotation
      create_annotation_via_cli(artifact_id, "New finding")

      # has-pending should be true again with count 1
      pending = run_binary(
        ["review", "has-pending", "--artifact-id", artifact_id.to_s],
      )
      parsed = JSON.parse(pending[:output])
      parsed["has_pending"].as_bool.should be_true
      parsed["count"].as_i.should eq(1)

      # Mark review as reviewed
      mark = run_binary(
        ["review", "mark-reviewed", "--artifact-id", artifact_id.to_s, "1"],
      )
      JSON.parse(mark[:output])["review"]["reviewed_at"].as_s?.should_not be_nil

      # View review with annotations
      view = run_binary(
        ["review", "view", "--artifact-id", artifact_id.to_s, "1", "--json"],
      )
      view_parsed = JSON.parse(view[:output])
      view_parsed["annotations"].as_a.size.should eq(3)
    end
  end
end
