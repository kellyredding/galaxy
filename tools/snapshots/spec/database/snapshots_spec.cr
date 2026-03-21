require "../spec_helper"

describe GalaxySnapshots::Database do
  # Clean database before each test
  before_each do
    db_path = GalaxySnapshots::Database.database_path
    File.delete(db_path) if File.exists?(db_path)
  end

  describe ".save_snapshot" do
    it "saves and returns number 1 for first snapshot in a session" do
      number = GalaxySnapshots::Database.save_snapshot(
        1_i64,
        "Test snapshot",
        "## Exchange 1\n\n### User\nHello\n\n### Assistant\nHi there!",
      )
      number.should eq(1)
    end

    it "increments numbers sequentially within the same session" do
      n1 = GalaxySnapshots::Database.save_snapshot(1_i64, "First", "content 1")
      n2 = GalaxySnapshots::Database.save_snapshot(1_i64, "Second", "content 2")
      n3 = GalaxySnapshots::Database.save_snapshot(1_i64, "Third", "content 3")

      n1.should eq(1)
      n2.should eq(2)
      n3.should eq(3)
    end

    it "starts numbering at 1 for a new session" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "A first", "content a1")
      GalaxySnapshots::Database.save_snapshot(1_i64, "A second", "content a2")

      n_b = GalaxySnapshots::Database.save_snapshot(2_i64, "B first", "content b1")
      n_b.should eq(1)
    end

    it "computes char_count from content size" do
      content = "Hello, world! This is a test."
      GalaxySnapshots::Database.save_snapshot(1_i64, "Chars test", content)

      snapshot = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
      snapshot.should_not be_nil
      snapshot.not_nil!.char_count.should eq(content.size)
    end

    it "stores exchange_count" do
      GalaxySnapshots::Database.save_snapshot(
        1_i64,
        "Multi exchange",
        "content here",
        exchange_count: 3,
      )

      snapshot = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
      snapshot.should_not be_nil
      snapshot.not_nil!.exchange_count.should eq(3)
    end

    it "stores optional metadata" do
      metadata = %({"source": "manual"})
      GalaxySnapshots::Database.save_snapshot(
        1_i64,
        "With metadata",
        "content",
        metadata: metadata,
      )

      snapshot = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
      snapshot.should_not be_nil
      snapshot.not_nil!.metadata.should eq(metadata)
    end

    it "returns 0 for invalid session id" do
      number = GalaxySnapshots::Database.save_snapshot(0_i64, "Bad", "content")
      number.should eq(0)
    end
  end

  describe ".list_snapshots" do
    it "returns snapshots in number order" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "First", "content 1")
      GalaxySnapshots::Database.save_snapshot(1_i64, "Second", "content 2")
      GalaxySnapshots::Database.save_snapshot(1_i64, "Third", "content 3")

      snapshots = GalaxySnapshots::Database.list_snapshots(1_i64)
      snapshots.size.should eq(3)
      snapshots[0].number.should eq(1)
      snapshots[0].title.should eq("First")
      snapshots[1].number.should eq(2)
      snapshots[2].number.should eq(3)
    end

    it "respects limit" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "A", "a")
      GalaxySnapshots::Database.save_snapshot(1_i64, "B", "b")
      GalaxySnapshots::Database.save_snapshot(1_i64, "C", "c")

      snapshots = GalaxySnapshots::Database.list_snapshots(1_i64, limit: 2)
      snapshots.size.should eq(2)
    end

    it "returns empty array for session with no snapshots" do
      snapshots = GalaxySnapshots::Database.list_snapshots(1_i64)
      snapshots.should be_empty
    end

    it "returns empty array for invalid session id" do
      snapshots = GalaxySnapshots::Database.list_snapshots(0_i64)
      snapshots.should be_empty
    end

    it "only returns snapshots for the specified session" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "A snap", "content a")
      GalaxySnapshots::Database.save_snapshot(2_i64, "B snap", "content b")

      a_snaps = GalaxySnapshots::Database.list_snapshots(1_i64)
      a_snaps.size.should eq(1)
      a_snaps[0].title.should eq("A snap")
    end
  end

  describe ".get_snapshot_by_number" do
    it "returns snapshot by session and number" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "Target", "the content")

      snapshot = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
      snapshot.should_not be_nil
      s = snapshot.not_nil!
      s.title.should eq("Target")
      s.content.should eq("the content")
      s.number.should eq(1)
      s.ledger_session_id.should eq(1_i64)
    end

    it "returns nil for non-existent number" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "Only one", "content")

      snapshot = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 99)
      snapshot.should be_nil
    end

    it "returns nil for invalid session id" do
      snapshot = GalaxySnapshots::Database.get_snapshot_by_number(0_i64, 1)
      snapshot.should be_nil
    end

    it "does not return snapshot from different session" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "A only", "content")

      snapshot = GalaxySnapshots::Database.get_snapshot_by_number(2_i64, 1)
      snapshot.should be_nil
    end
  end

  describe ".delete_snapshot_by_number" do
    it "deletes and returns true" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "To delete", "content")

      result = GalaxySnapshots::Database.delete_snapshot_by_number(1_i64, 1)
      result.should be_true

      # Verify it's gone
      snapshot = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
      snapshot.should be_nil
    end

    it "returns false for non-existent number" do
      result = GalaxySnapshots::Database.delete_snapshot_by_number(1_i64, 99)
      result.should be_false
    end

    it "returns false for invalid session id" do
      result = GalaxySnapshots::Database.delete_snapshot_by_number(0_i64, 1)
      result.should be_false
    end
  end

  describe ".session_snapshot_stats" do
    it "returns correct count and total chars" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "A", "hello")   # 5 chars
      GalaxySnapshots::Database.save_snapshot(1_i64, "B", "world!!") # 7 chars

      stats = GalaxySnapshots::Database.session_snapshot_stats(1_i64)
      stats[:count].should eq(2)
      stats[:total_chars].should eq(12)
    end

    it "returns zeros for session with no snapshots" do
      stats = GalaxySnapshots::Database.session_snapshot_stats(1_i64)
      stats[:count].should eq(0)
      stats[:total_chars].should eq(0)
    end

    it "returns zeros for invalid session id" do
      stats = GalaxySnapshots::Database.session_snapshot_stats(0_i64)
      stats[:count].should eq(0)
      stats[:total_chars].should eq(0)
    end
  end

  describe "Snapshot struct" do
    it "has all expected fields" do
      GalaxySnapshots::Database.save_snapshot(
        1_i64, "Full struct", "full content",
        exchange_count: 2, metadata: %({"key": "val"}),
      )

      snapshot = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
      snapshot.should_not be_nil
      s = snapshot.not_nil!

      s.id.should be > 0
      s.ledger_session_id.should eq(1_i64)
      s.number.should eq(1)
      s.created_at.should_not be_empty
      s.updated_at.should_not be_empty
      s.title.should eq("Full struct")
      s.content.should eq("full content")
      s.exchange_count.should eq(2)
      s.char_count.should eq("full content".size)
      s.metadata.should eq(%({"key": "val"}))
    end
  end

  describe ".get_snapshot_by_id" do
    it "returns snapshot by primary key ID" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "By ID test", "content here")
      by_number = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1)
      snapshot_id = by_number.not_nil!.id

      result = GalaxySnapshots::Database.get_snapshot_by_id(snapshot_id)
      result.should_not be_nil
      s = result.not_nil!
      s.id.should eq(snapshot_id)
      s.title.should eq("By ID test")
      s.content.should eq("content here")
      s.ledger_session_id.should eq(1_i64)
    end

    it "returns nil for nonexistent ID" do
      result = GalaxySnapshots::Database.get_snapshot_by_id(99999_i64)
      result.should be_nil
    end

    it "returns nil for invalid ID (0)" do
      result = GalaxySnapshots::Database.get_snapshot_by_id(0_i64)
      result.should be_nil
    end

    it "returns nil for negative ID" do
      result = GalaxySnapshots::Database.get_snapshot_by_id(-1_i64)
      result.should be_nil
    end
  end

  describe ".list_snapshots_with_counts" do
    it "returns snapshots with review counts" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "S1", "content1")
      GalaxySnapshots::Database.save_snapshot(1_i64, "S2", "content2")

      snap1 = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1).not_nil!

      # Create annotations and a review for snap1
      GalaxySnapshots::Database.save_snapshot_annotation(snap1.id, 1, 1, "note")
      GalaxySnapshots::Database.save_snapshot_review(snap1.id)

      items = GalaxySnapshots::Database.list_snapshots_with_counts(1_i64)
      items.size.should eq(2)
      items[0].number.should eq(1)
      items[0].review_count.should eq(1)
      items[1].number.should eq(2)
      items[1].review_count.should eq(0)
    end

    it "returns empty for nonexistent session" do
      items = GalaxySnapshots::Database.list_snapshots_with_counts(99999_i64)
      items.should be_empty
    end

    it "counts multiple reviews per snapshot" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "Multi", "content")
      snap = GalaxySnapshots::Database.get_snapshot_by_number(1_i64, 1).not_nil!

      # Two rounds of annotations -> two reviews
      GalaxySnapshots::Database.save_snapshot_annotation(snap.id, 1, 1, "a")
      GalaxySnapshots::Database.save_snapshot_review(snap.id)
      GalaxySnapshots::Database.save_snapshot_annotation(snap.id, 2, 2, "b")
      GalaxySnapshots::Database.save_snapshot_review(snap.id)

      items = GalaxySnapshots::Database.list_snapshots_with_counts(1_i64)
      items[0].review_count.should eq(2)
    end

    it "returns empty array for invalid session id" do
      items = GalaxySnapshots::Database.list_snapshots_with_counts(0_i64)
      items.should be_empty
    end

    it "respects limit parameter" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "A", "a")
      GalaxySnapshots::Database.save_snapshot(1_i64, "B", "b")
      GalaxySnapshots::Database.save_snapshot(1_i64, "C", "c")

      items = GalaxySnapshots::Database.list_snapshots_with_counts(1_i64, limit: 2)
      items.size.should eq(2)
    end

    it "returns correct fields on SnapshotListItem" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "Field test", "the content", exchange_count: 5)

      items = GalaxySnapshots::Database.list_snapshots_with_counts(1_i64)
      items.size.should eq(1)
      item = items[0]
      item.id.should be > 0
      item.ledger_session_id.should eq(1_i64)
      item.number.should eq(1)
      item.title.should eq("Field test")
      item.exchange_count.should eq(5)
      item.char_count.should eq("the content".size)
      item.review_count.should eq(0)
      item.created_at.should_not be_empty
    end

    it "only returns snapshots for the specified session" do
      GalaxySnapshots::Database.save_snapshot(1_i64, "A snap", "content a")
      GalaxySnapshots::Database.save_snapshot(2_i64, "B snap", "content b")

      a_items = GalaxySnapshots::Database.list_snapshots_with_counts(1_i64)
      a_items.size.should eq(1)
      a_items[0].title.should eq("A snap")
    end
  end
end
