require "../spec_helper"

# Helper to create a test session with PID mapping for review CLI tests.
def create_review_session_with_pid(pid : Int64) : Int64
  session_id = "rev-cli-#{pid}"
  GalaxyLedger::Database.create_session(session_id, claude_pid: pid)
end

# Helper to create a session + snapshot, returning {session_id, snapshot_db_id}
def create_session_and_snapshot_for_reviews_cli(pid : Int64) : {Int64, Int64}
  session_id = create_review_session_with_pid(pid)
  GalaxyLedger::Database.save_snapshot(session_id, "Test snapshot", "Line 1\nLine 2\nLine 3\nLine 4\nLine 5")
  snapshot = GalaxyLedger::Database.get_snapshot_by_number(session_id, 1)
  {session_id, snapshot.not_nil!.id}
end

# Helper to create annotations for CLI review tests
def create_annotations_for_review_cli(snapshot_id : Int64, count : Int32 = 3)
  count.times do |i|
    GalaxyLedger::Database.save_snapshot_annotation(
      snapshot_id, (i + 1).to_i, (i + 1).to_i, "Annotation #{i + 1}",
    )
  end
end

describe "CLI snapshot review commands", tags: "integration" do
  describe "snapshot review create" do
    it "creates a review and assigns annotations" do
      pid = 92001_i64
      _, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)
      create_annotations_for_review_cli(snapshot_id, 3)

      result = run_binary(
        ["snapshot", "review", "create",
         "--ledger-snapshot-id", snapshot_id.to_s],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["review"]["number"].as_i.should eq(1)
      parsed["review"]["ledger_snapshot_id"].as_i64.should eq(snapshot_id)
      parsed["review"]["reviewed_at"].raw.should be_nil
      parsed["annotation_count"].as_i.should eq(3)
    end

    it "fails when no unreviewed annotations exist" do
      pid = 92002_i64
      _, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)

      result = run_binary(
        ["snapshot", "review", "create",
         "--ledger-snapshot-id", snapshot_id.to_s],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("no unreviewed annotations")
    end

    it "fails after all annotations assigned to a review" do
      pid = 92003_i64
      _, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)
      create_annotations_for_review_cli(snapshot_id, 2)

      # First review takes all
      r1 = run_binary(
        ["snapshot", "review", "create",
         "--ledger-snapshot-id", snapshot_id.to_s],
      )
      r1[:status].should eq(0)

      # Second attempt fails
      r2 = run_binary(
        ["snapshot", "review", "create",
         "--ledger-snapshot-id", snapshot_id.to_s],
      )
      r2[:status].should_not eq(0)
      r2[:error].should contain("no unreviewed annotations")
    end
  end

  describe "snapshot review list" do
    it "lists reviews in human-readable format" do
      pid = 92010_i64
      _, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)
      create_annotations_for_review_cli(snapshot_id, 2)
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      result = run_binary(
        ["snapshot", "review", "list",
         "--ledger-snapshot-id", snapshot_id.to_s],
      )

      result[:status].should eq(0)
      result[:output].should contain("1 total")
      result[:output].should contain("#1")
      result[:output].should contain("2 annotations")
      result[:output].should contain("pending")
    end

    it "lists reviews in JSON format" do
      pid = 92011_i64
      _, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)
      create_annotations_for_review_cli(snapshot_id, 2)
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      result = run_binary(
        ["snapshot", "review", "list",
         "--ledger-snapshot-id", snapshot_id.to_s, "--json"],
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
      pid = 92012_i64
      _, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)
      create_annotations_for_review_cli(snapshot_id, 2)
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 4, 5, "Extra")
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      # Mark first as reviewed
      GalaxyLedger::Database.mark_snapshot_review_reviewed(snapshot_id, 1)

      result = run_binary(
        ["snapshot", "review", "list",
         "--ledger-snapshot-id", snapshot_id.to_s, "--json", "--pending"],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      reviews = parsed["reviews"].as_a
      reviews.size.should eq(1)
      reviews[0]["number"].as_i.should eq(2)
    end

    it "shows empty message when no reviews" do
      pid = 92013_i64
      _, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)

      result = run_binary(
        ["snapshot", "review", "list",
         "--ledger-snapshot-id", snapshot_id.to_s],
      )

      result[:status].should eq(0)
      result[:output].should contain("No reviews")
    end
  end

  describe "snapshot review view" do
    it "shows review in human-readable format" do
      pid = 92020_i64
      _, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)
      create_annotations_for_review_cli(snapshot_id, 2)
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      result = run_binary(
        ["snapshot", "review", "view",
         "--ledger-snapshot-id", snapshot_id.to_s, "1"],
      )

      result[:status].should eq(0)
      result[:output].should contain("Review #1")
      result[:output].should contain("pending")
      result[:output].should contain("Snapshot: #1")
      result[:output].should contain("Annotations (2)")
    end

    it "returns full context in JSON format" do
      pid = 92021_i64
      _, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)
      create_annotations_for_review_cli(snapshot_id, 2)
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      result = run_binary(
        ["snapshot", "review", "view",
         "--ledger-snapshot-id", snapshot_id.to_s, "1", "--json"],
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
      pid = 92022_i64
      _, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)

      result = run_binary(
        ["snapshot", "review", "view",
         "--ledger-snapshot-id", snapshot_id.to_s, "99"],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end

    it "errors when review number is missing" do
      pid = 92023_i64
      _, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)

      result = run_binary(
        ["snapshot", "review", "view",
         "--ledger-snapshot-id", snapshot_id.to_s],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("review number is required")
    end
  end

  describe "snapshot review mark-reviewed" do
    it "sets reviewed_at and returns updated JSON" do
      pid = 92030_i64
      _, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)
      create_annotations_for_review_cli(snapshot_id, 1)
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      result = run_binary(
        ["snapshot", "review", "mark-reviewed",
         "--ledger-snapshot-id", snapshot_id.to_s, "1"],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["review"]["number"].as_i.should eq(1)
      parsed["review"]["reviewed_at"].as_s?.should_not be_nil
    end

    it "is idempotent" do
      pid = 92031_i64
      _, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)
      create_annotations_for_review_cli(snapshot_id, 1)
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      r1 = run_binary(
        ["snapshot", "review", "mark-reviewed",
         "--ledger-snapshot-id", snapshot_id.to_s, "1"],
      )
      r2 = run_binary(
        ["snapshot", "review", "mark-reviewed",
         "--ledger-snapshot-id", snapshot_id.to_s, "1"],
      )

      r1[:status].should eq(0)
      r2[:status].should eq(0)
    end

    it "errors for nonexistent review" do
      pid = 92032_i64
      _, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)

      result = run_binary(
        ["snapshot", "review", "mark-reviewed",
         "--ledger-snapshot-id", snapshot_id.to_s, "99"],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end
  end

  describe "snapshot review has-pending" do
    it "returns true with count when unreviewed annotations exist" do
      pid = 92040_i64
      _, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)
      create_annotations_for_review_cli(snapshot_id, 3)

      result = run_binary(
        ["snapshot", "review", "has-pending",
         "--ledger-snapshot-id", snapshot_id.to_s],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["has_pending"].as_bool.should be_true
      parsed["count"].as_i.should eq(3)
      parsed["ledger_snapshot_id"].as_i64.should eq(snapshot_id)
    end

    it "returns false when all annotations are assigned" do
      pid = 92041_i64
      _, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)
      create_annotations_for_review_cli(snapshot_id, 2)
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      result = run_binary(
        ["snapshot", "review", "has-pending",
         "--ledger-snapshot-id", snapshot_id.to_s],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["has_pending"].as_bool.should be_false
      parsed["count"].as_i.should eq(0)
    end

    it "returns true after new annotation added post-review" do
      pid = 92042_i64
      _, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)
      create_annotations_for_review_cli(snapshot_id, 1)
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      # Add a new annotation after review
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 4, 5, "New one")

      result = run_binary(
        ["snapshot", "review", "has-pending",
         "--ledger-snapshot-id", snapshot_id.to_s],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["has_pending"].as_bool.should be_true
      parsed["count"].as_i.should eq(1)
    end
  end

  describe "alternative identifier resolution" do
    it "resolves --ledger-session-id + --snapshot for review commands" do
      pid = 92050_i64
      session_id = create_review_session_with_pid(pid)
      GalaxyLedger::Database.save_snapshot(session_id, "Alt resolve", "content")
      snapshot = GalaxyLedger::Database.get_snapshot_by_number(session_id, 1)
      snapshot_id = snapshot.not_nil!.id

      create_annotations_for_review_cli(snapshot_id, 2)

      # Create via alternative identifiers
      result = run_binary(
        ["snapshot", "review", "create",
         "--ledger-session-id", session_id.to_s,
         "--snapshot", "1"],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["review"]["ledger_snapshot_id"].as_i64.should eq(snapshot_id)

      # List via alternative identifiers
      list_result = run_binary(
        ["snapshot", "review", "list",
         "--ledger-session-id", session_id.to_s,
         "--snapshot", "1", "--json"],
      )

      list_result[:status].should eq(0)
      list_parsed = JSON.parse(list_result[:output])
      list_parsed["reviews"].as_a.size.should eq(1)
    end
  end

  describe "annotation JSON includes review_id" do
    it "includes ledger_snapshot_review_id in annotation JSON" do
      pid = 92060_i64
      _, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)

      # Create annotation — should have null review_id
      r1 = run_binary(
        ["snapshot", "annotation", "create",
         "--ledger-snapshot-id", snapshot_id.to_s,
         "--start-line", "1", "--end-line", "2"],
        stdin: "Test annotation",
      )
      r1[:status].should eq(0)
      parsed = JSON.parse(r1[:output])
      parsed["annotation"]["ledger_snapshot_review_id"].raw.should be_nil

      # Create review — assigns annotation
      GalaxyLedger::Database.save_snapshot_review(snapshot_id)

      # View annotation — should now have review_id
      r2 = run_binary(
        ["snapshot", "annotation", "view",
         "--ledger-snapshot-id", snapshot_id.to_s, "1"],
      )
      r2[:status].should eq(0)
      parsed2 = JSON.parse(r2[:output])
      parsed2["annotation"]["ledger_snapshot_review_id"].as_i64?.should_not be_nil
    end
  end

  describe "snapshot review help" do
    it "shows review help" do
      result = run_binary(["snapshot", "review", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("Manage snapshot reviews")
      result[:output].should contain("create")
      result[:output].should contain("list")
      result[:output].should contain("view")
      result[:output].should contain("mark-reviewed")
      result[:output].should contain("has-pending")
    end

    it "shows review create help" do
      result = run_binary(["snapshot", "review", "create", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("--ledger-snapshot-id")
      result[:output].should contain("unreviewed annotations")
    end

    it "shows review list help" do
      result = run_binary(["snapshot", "review", "list", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("--pending")
      result[:output].should contain("--json")
    end

    it "shows review view help" do
      result = run_binary(["snapshot", "review", "view", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("NUMBER")
      result[:output].should contain("--json")
    end

    it "shows review has-pending help" do
      result = run_binary(["snapshot", "review", "has-pending", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("unreviewed annotations")
    end

    it "shows review mark-reviewed help" do
      result = run_binary(["snapshot", "review", "mark-reviewed", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("NUMBER")
      result[:output].should contain("Idempotent")
    end
  end

  describe "snapshot help includes review" do
    it "shows review in snapshot command list" do
      result = run_binary(["snapshot", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("review")
      result[:output].should contain("Manage snapshot reviews")
    end
  end

  describe "end-to-end review workflow" do
    it "creates annotations, submits review, views, marks reviewed" do
      pid = 92070_i64
      session_id, snapshot_id = create_session_and_snapshot_for_reviews_cli(pid)

      # Create annotations
      create_annotations_for_review_cli(snapshot_id, 3)

      # Check has-pending — should be true
      hp1 = run_binary(
        ["snapshot", "review", "has-pending",
         "--ledger-snapshot-id", snapshot_id.to_s],
      )
      hp1[:status].should eq(0)
      JSON.parse(hp1[:output])["has_pending"].as_bool.should be_true

      # Create review
      create_result = run_binary(
        ["snapshot", "review", "create",
         "--ledger-snapshot-id", snapshot_id.to_s],
      )
      create_result[:status].should eq(0)
      JSON.parse(create_result[:output])["annotation_count"].as_i.should eq(3)

      # Check has-pending — should be false now
      hp2 = run_binary(
        ["snapshot", "review", "has-pending",
         "--ledger-snapshot-id", snapshot_id.to_s],
      )
      JSON.parse(hp2[:output])["has_pending"].as_bool.should be_false

      # List pending reviews
      list_result = run_binary(
        ["snapshot", "review", "list",
         "--ledger-snapshot-id", snapshot_id.to_s, "--json", "--pending"],
      )
      list_result[:status].should eq(0)
      reviews = JSON.parse(list_result[:output])["reviews"].as_a
      reviews.size.should eq(1)

      # View review with full context
      view_result = run_binary(
        ["snapshot", "review", "view",
         "--ledger-snapshot-id", snapshot_id.to_s, "1", "--json"],
      )
      view_result[:status].should eq(0)
      view_parsed = JSON.parse(view_result[:output])
      view_parsed["annotations"].as_a.size.should eq(3)
      view_parsed["snapshot"]["content"].as_s.should contain("Line 1")

      # Mark reviewed
      mark_result = run_binary(
        ["snapshot", "review", "mark-reviewed",
         "--ledger-snapshot-id", snapshot_id.to_s, "1"],
      )
      mark_result[:status].should eq(0)
      JSON.parse(mark_result[:output])["review"]["reviewed_at"].as_s?.should_not be_nil

      # List pending — should be empty now
      list_after = run_binary(
        ["snapshot", "review", "list",
         "--ledger-snapshot-id", snapshot_id.to_s, "--json", "--pending"],
      )
      JSON.parse(list_after[:output])["reviews"].as_a.size.should eq(0)

      # Add new annotation, create second review
      GalaxyLedger::Database.save_snapshot_annotation(snapshot_id, 4, 5, "Follow-up note")

      hp3 = run_binary(
        ["snapshot", "review", "has-pending",
         "--ledger-snapshot-id", snapshot_id.to_s],
      )
      JSON.parse(hp3[:output])["has_pending"].as_bool.should be_true

      create2 = run_binary(
        ["snapshot", "review", "create",
         "--ledger-snapshot-id", snapshot_id.to_s],
      )
      create2[:status].should eq(0)
      JSON.parse(create2[:output])["review"]["number"].as_i.should eq(2)
      JSON.parse(create2[:output])["annotation_count"].as_i.should eq(1)
    end
  end
end
