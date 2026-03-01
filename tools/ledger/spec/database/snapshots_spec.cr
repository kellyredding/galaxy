require "../spec_helper"

describe GalaxyLedger::Database do
  # Clean database before each test
  before_each do
    db_path = GalaxyLedger::Database.database_path
    File.delete(db_path) if File.exists?(db_path)
  end

  describe ".save_snapshot" do
    it "saves and returns number 1 for first snapshot in a session" do
      session_id = GalaxyLedger::Database.create_session("snap-test-1")
      number = GalaxyLedger::Database.save_snapshot(
        session_id,
        "Test snapshot",
        "## Exchange 1\n\n### User\nHello\n\n### Assistant\nHi there!",
      )
      number.should eq(1)
    end

    it "increments numbers sequentially within the same session" do
      session_id = GalaxyLedger::Database.create_session("snap-test-2")

      n1 = GalaxyLedger::Database.save_snapshot(session_id, "First", "content 1")
      n2 = GalaxyLedger::Database.save_snapshot(session_id, "Second", "content 2")
      n3 = GalaxyLedger::Database.save_snapshot(session_id, "Third", "content 3")

      n1.should eq(1)
      n2.should eq(2)
      n3.should eq(3)
    end

    it "starts numbering at 1 for a new session" do
      session_a = GalaxyLedger::Database.create_session("snap-session-a")
      session_b = GalaxyLedger::Database.create_session("snap-session-b")

      GalaxyLedger::Database.save_snapshot(session_a, "A first", "content a1")
      GalaxyLedger::Database.save_snapshot(session_a, "A second", "content a2")

      n_b = GalaxyLedger::Database.save_snapshot(session_b, "B first", "content b1")
      n_b.should eq(1)
    end

    it "computes char_count from content size" do
      session_id = GalaxyLedger::Database.create_session("snap-test-chars")
      content = "Hello, world! This is a test."
      GalaxyLedger::Database.save_snapshot(session_id, "Chars test", content)

      snapshot = GalaxyLedger::Database.get_snapshot_by_number(session_id, 1)
      snapshot.should_not be_nil
      snapshot.not_nil!.char_count.should eq(content.size)
    end

    it "stores exchange_count" do
      session_id = GalaxyLedger::Database.create_session("snap-test-exchanges")
      GalaxyLedger::Database.save_snapshot(
        session_id,
        "Multi exchange",
        "content here",
        exchange_count: 3,
      )

      snapshot = GalaxyLedger::Database.get_snapshot_by_number(session_id, 1)
      snapshot.should_not be_nil
      snapshot.not_nil!.exchange_count.should eq(3)
    end

    it "stores optional metadata" do
      session_id = GalaxyLedger::Database.create_session("snap-test-meta")
      metadata = %({"source": "manual"})
      GalaxyLedger::Database.save_snapshot(
        session_id,
        "With metadata",
        "content",
        metadata: metadata,
      )

      snapshot = GalaxyLedger::Database.get_snapshot_by_number(session_id, 1)
      snapshot.should_not be_nil
      snapshot.not_nil!.metadata.should eq(metadata)
    end

    it "returns 0 for invalid session id" do
      number = GalaxyLedger::Database.save_snapshot(0_i64, "Bad", "content")
      number.should eq(0)
    end
  end

  describe ".list_snapshots" do
    it "returns snapshots in number order" do
      session_id = GalaxyLedger::Database.create_session("snap-list-1")
      GalaxyLedger::Database.save_snapshot(session_id, "First", "content 1")
      GalaxyLedger::Database.save_snapshot(session_id, "Second", "content 2")
      GalaxyLedger::Database.save_snapshot(session_id, "Third", "content 3")

      snapshots = GalaxyLedger::Database.list_snapshots(session_id)
      snapshots.size.should eq(3)
      snapshots[0].number.should eq(1)
      snapshots[0].title.should eq("First")
      snapshots[1].number.should eq(2)
      snapshots[2].number.should eq(3)
    end

    it "respects limit" do
      session_id = GalaxyLedger::Database.create_session("snap-list-limit")
      GalaxyLedger::Database.save_snapshot(session_id, "A", "a")
      GalaxyLedger::Database.save_snapshot(session_id, "B", "b")
      GalaxyLedger::Database.save_snapshot(session_id, "C", "c")

      snapshots = GalaxyLedger::Database.list_snapshots(session_id, limit: 2)
      snapshots.size.should eq(2)
    end

    it "returns empty array for session with no snapshots" do
      session_id = GalaxyLedger::Database.create_session("snap-list-empty")
      snapshots = GalaxyLedger::Database.list_snapshots(session_id)
      snapshots.should be_empty
    end

    it "returns empty array for invalid session id" do
      snapshots = GalaxyLedger::Database.list_snapshots(0_i64)
      snapshots.should be_empty
    end

    it "only returns snapshots for the specified session" do
      session_a = GalaxyLedger::Database.create_session("snap-list-a")
      session_b = GalaxyLedger::Database.create_session("snap-list-b")

      GalaxyLedger::Database.save_snapshot(session_a, "A snap", "content a")
      GalaxyLedger::Database.save_snapshot(session_b, "B snap", "content b")

      a_snaps = GalaxyLedger::Database.list_snapshots(session_a)
      a_snaps.size.should eq(1)
      a_snaps[0].title.should eq("A snap")
    end
  end

  describe ".get_snapshot_by_number" do
    it "returns snapshot by session and number" do
      session_id = GalaxyLedger::Database.create_session("snap-get-1")
      GalaxyLedger::Database.save_snapshot(session_id, "Target", "the content")

      snapshot = GalaxyLedger::Database.get_snapshot_by_number(session_id, 1)
      snapshot.should_not be_nil
      s = snapshot.not_nil!
      s.title.should eq("Target")
      s.content.should eq("the content")
      s.number.should eq(1)
      s.ledger_session_id.should eq(session_id)
    end

    it "returns nil for non-existent number" do
      session_id = GalaxyLedger::Database.create_session("snap-get-miss")
      GalaxyLedger::Database.save_snapshot(session_id, "Only one", "content")

      snapshot = GalaxyLedger::Database.get_snapshot_by_number(session_id, 99)
      snapshot.should be_nil
    end

    it "returns nil for invalid session id" do
      snapshot = GalaxyLedger::Database.get_snapshot_by_number(0_i64, 1)
      snapshot.should be_nil
    end

    it "does not return snapshot from different session" do
      session_a = GalaxyLedger::Database.create_session("snap-get-a")
      session_b = GalaxyLedger::Database.create_session("snap-get-b")
      GalaxyLedger::Database.save_snapshot(session_a, "A only", "content")

      snapshot = GalaxyLedger::Database.get_snapshot_by_number(session_b, 1)
      snapshot.should be_nil
    end
  end

  describe ".delete_snapshot_by_number" do
    it "deletes and returns true" do
      session_id = GalaxyLedger::Database.create_session("snap-del-1")
      GalaxyLedger::Database.save_snapshot(session_id, "To delete", "content")

      result = GalaxyLedger::Database.delete_snapshot_by_number(session_id, 1)
      result.should be_true

      # Verify it's gone
      snapshot = GalaxyLedger::Database.get_snapshot_by_number(session_id, 1)
      snapshot.should be_nil
    end

    it "returns false for non-existent number" do
      session_id = GalaxyLedger::Database.create_session("snap-del-miss")
      result = GalaxyLedger::Database.delete_snapshot_by_number(session_id, 99)
      result.should be_false
    end

    it "returns false for invalid session id" do
      result = GalaxyLedger::Database.delete_snapshot_by_number(0_i64, 1)
      result.should be_false
    end
  end

  describe ".session_snapshot_stats" do
    it "returns correct count and total chars" do
      session_id = GalaxyLedger::Database.create_session("snap-stats-1")
      GalaxyLedger::Database.save_snapshot(session_id, "A", "hello")   # 5 chars
      GalaxyLedger::Database.save_snapshot(session_id, "B", "world!!") # 7 chars

      stats = GalaxyLedger::Database.session_snapshot_stats(session_id)
      stats[:count].should eq(2)
      stats[:total_chars].should eq(12)
    end

    it "returns zeros for session with no snapshots" do
      session_id = GalaxyLedger::Database.create_session("snap-stats-empty")
      stats = GalaxyLedger::Database.session_snapshot_stats(session_id)
      stats[:count].should eq(0)
      stats[:total_chars].should eq(0)
    end

    it "returns zeros for invalid session id" do
      stats = GalaxyLedger::Database.session_snapshot_stats(0_i64)
      stats[:count].should eq(0)
      stats[:total_chars].should eq(0)
    end
  end

  describe "cascade delete" do
    it "deletes snapshots when session is deleted" do
      session_id = GalaxyLedger::Database.create_session("snap-cascade")
      GalaxyLedger::Database.save_snapshot(session_id, "Will cascade", "content")
      GalaxyLedger::Database.save_snapshot(session_id, "Also cascade", "more content")

      # Verify they exist
      stats = GalaxyLedger::Database.session_snapshot_stats(session_id)
      stats[:count].should eq(2)

      # Delete the session
      GalaxyLedger::Database.delete_session(session_id)

      # Snapshots should be gone — query directly since session is deleted
      GalaxyLedger::Database.open do |db|
        count = db.scalar(
          "SELECT COUNT(*) FROM ledger_snapshots WHERE ledger_session_id = ?",
          session_id,
        ).as(Int64)
        count.should eq(0)
      end
    end
  end

  describe "Snapshot struct" do
    it "has all expected fields" do
      session_id = GalaxyLedger::Database.create_session("snap-struct")
      GalaxyLedger::Database.save_snapshot(
        session_id, "Full struct", "full content",
        exchange_count: 2, metadata: %({"key": "val"}),
      )

      snapshot = GalaxyLedger::Database.get_snapshot_by_number(session_id, 1)
      snapshot.should_not be_nil
      s = snapshot.not_nil!

      s.id.should be > 0
      s.ledger_session_id.should eq(session_id)
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
      session_id = GalaxyLedger::Database.create_session("snap-byid-1")
      GalaxyLedger::Database.save_snapshot(session_id, "By ID test", "content here")
      by_number = GalaxyLedger::Database.get_snapshot_by_number(session_id, 1)
      snapshot_id = by_number.not_nil!.id

      result = GalaxyLedger::Database.get_snapshot_by_id(snapshot_id)
      result.should_not be_nil
      s = result.not_nil!
      s.id.should eq(snapshot_id)
      s.title.should eq("By ID test")
      s.content.should eq("content here")
      s.ledger_session_id.should eq(session_id)
    end

    it "returns nil for nonexistent ID" do
      result = GalaxyLedger::Database.get_snapshot_by_id(99999_i64)
      result.should be_nil
    end

    it "returns nil for invalid ID (0)" do
      result = GalaxyLedger::Database.get_snapshot_by_id(0_i64)
      result.should be_nil
    end

    it "returns nil for negative ID" do
      result = GalaxyLedger::Database.get_snapshot_by_id(-1_i64)
      result.should be_nil
    end
  end

  describe ".list_snapshots_with_counts" do
    it "returns snapshots with review counts" do
      session_id = GalaxyLedger::Database.create_session("list-counts-1")
      GalaxyLedger::Database.save_snapshot(session_id, "S1", "content1")
      GalaxyLedger::Database.save_snapshot(session_id, "S2", "content2")

      snap1 = GalaxyLedger::Database.get_snapshot_by_number(session_id, 1).not_nil!

      # Create annotations and a review for snap1
      GalaxyLedger::Database.save_snapshot_annotation(snap1.id, 1, 1, "note")
      GalaxyLedger::Database.save_snapshot_review(snap1.id)

      items = GalaxyLedger::Database.list_snapshots_with_counts(session_id)
      items.size.should eq(2)
      items[0].number.should eq(1)
      items[0].review_count.should eq(1)
      items[1].number.should eq(2)
      items[1].review_count.should eq(0)
    end

    it "returns empty for nonexistent session" do
      items = GalaxyLedger::Database.list_snapshots_with_counts(99999_i64)
      items.should be_empty
    end

    it "counts multiple reviews per snapshot" do
      session_id = GalaxyLedger::Database.create_session("list-counts-2")
      GalaxyLedger::Database.save_snapshot(session_id, "Multi", "content")
      snap = GalaxyLedger::Database.get_snapshot_by_number(session_id, 1).not_nil!

      # Two rounds of annotations → two reviews
      GalaxyLedger::Database.save_snapshot_annotation(snap.id, 1, 1, "a")
      GalaxyLedger::Database.save_snapshot_review(snap.id)
      GalaxyLedger::Database.save_snapshot_annotation(snap.id, 2, 2, "b")
      GalaxyLedger::Database.save_snapshot_review(snap.id)

      items = GalaxyLedger::Database.list_snapshots_with_counts(session_id)
      items[0].review_count.should eq(2)
    end

    it "returns empty array for invalid session id" do
      items = GalaxyLedger::Database.list_snapshots_with_counts(0_i64)
      items.should be_empty
    end

    it "respects limit parameter" do
      session_id = GalaxyLedger::Database.create_session("list-counts-limit")
      GalaxyLedger::Database.save_snapshot(session_id, "A", "a")
      GalaxyLedger::Database.save_snapshot(session_id, "B", "b")
      GalaxyLedger::Database.save_snapshot(session_id, "C", "c")

      items = GalaxyLedger::Database.list_snapshots_with_counts(session_id, limit: 2)
      items.size.should eq(2)
    end

    it "returns correct fields on SnapshotListItem" do
      session_id = GalaxyLedger::Database.create_session("list-counts-fields")
      GalaxyLedger::Database.save_snapshot(session_id, "Field test", "the content", exchange_count: 5)

      items = GalaxyLedger::Database.list_snapshots_with_counts(session_id)
      items.size.should eq(1)
      item = items[0]
      item.id.should be > 0
      item.ledger_session_id.should eq(session_id)
      item.number.should eq(1)
      item.title.should eq("Field test")
      item.exchange_count.should eq(5)
      item.char_count.should eq("the content".size)
      item.review_count.should eq(0)
      item.created_at.should_not be_empty
    end

    it "only returns snapshots for the specified session" do
      session_a = GalaxyLedger::Database.create_session("list-counts-a")
      session_b = GalaxyLedger::Database.create_session("list-counts-b")

      GalaxyLedger::Database.save_snapshot(session_a, "A snap", "content a")
      GalaxyLedger::Database.save_snapshot(session_b, "B snap", "content b")

      a_items = GalaxyLedger::Database.list_snapshots_with_counts(session_a)
      a_items.size.should eq(1)
      a_items[0].title.should eq("A snap")
    end
  end
end
