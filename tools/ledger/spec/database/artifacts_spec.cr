require "../spec_helper"

describe GalaxyLedger::Database do
  # Clean database before each test
  before_each do
    db_path = GalaxyLedger::Database.database_path
    File.delete(db_path) if File.exists?(db_path)
  end

  describe ".save_artifact" do
    it "inserts and returns number 1 for first artifact in a session" do
      session_id = GalaxyLedger::Database.create_session("art-test-1")
      result = GalaxyLedger::Database.save_artifact(
        session_id,
        title: "Test CSV",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "data.csv",
        stored_path: "/tmp/stored/001_data.csv",
        source_path: "/tmp/data.csv",
        file_size: 1024_i64,
        content_hash: "abc123",
      )
      result.action.should eq(GalaxyLedger::Database::SaveArtifactAction::Insert)
      result.number.should eq(1)
    end

    it "increments numbers sequentially within the same session" do
      session_id = GalaxyLedger::Database.create_session("art-test-2")

      r1 = GalaxyLedger::Database.save_artifact(
        session_id,
        title: "First",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "a.csv",
        stored_path: "/tmp/1",
        source_path: "/tmp/a.csv",
        file_size: 100_i64,
        content_hash: "h1",
      )
      r2 = GalaxyLedger::Database.save_artifact(
        session_id,
        title: "Second",
        artifact_type: "pdf",
        mime_type: "application/pdf",
        original_filename: "b.pdf",
        stored_path: "/tmp/2",
        source_path: "/tmp/b.pdf",
        file_size: 200_i64,
        content_hash: "h2",
      )
      r3 = GalaxyLedger::Database.save_artifact(
        session_id,
        title: "Third",
        artifact_type: "image",
        mime_type: "image/png",
        original_filename: "c.png",
        stored_path: "/tmp/3",
        source_path: "/tmp/c.png",
        file_size: 300_i64,
        content_hash: "h3",
      )

      r1.action.should eq(GalaxyLedger::Database::SaveArtifactAction::Insert)
      r2.action.should eq(GalaxyLedger::Database::SaveArtifactAction::Insert)
      r3.action.should eq(GalaxyLedger::Database::SaveArtifactAction::Insert)
      r1.number.should eq(1)
      r2.number.should eq(2)
      r3.number.should eq(3)
    end

    it "starts numbering at 1 for a new session" do
      session_a = GalaxyLedger::Database.create_session("art-session-a")
      session_b = GalaxyLedger::Database.create_session("art-session-b")

      GalaxyLedger::Database.save_artifact(
        session_a,
        title: "A first",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "a1.csv",
        stored_path: "/tmp/a1",
        source_path: "/tmp/a1.csv",
        file_size: 100_i64,
        content_hash: "ha1",
      )

      r_b = GalaxyLedger::Database.save_artifact(
        session_b,
        title: "B first",
        artifact_type: "pdf",
        mime_type: "application/pdf",
        original_filename: "b1.pdf",
        stored_path: "/tmp/b1",
        source_path: "/tmp/b1.pdf",
        file_size: 200_i64,
        content_hash: "hb1",
      )
      r_b.number.should eq(1)
    end

    it "stores optional description and metadata" do
      session_id = GalaxyLedger::Database.create_session("art-test-meta")
      GalaxyLedger::Database.save_artifact(
        session_id,
        title: "With extras",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "data.csv",
        stored_path: "/tmp/stored",
        source_path: "/tmp/data.csv",
        file_size: 100_i64,
        content_hash: "h1",
        description: "Monthly revenue data",
        metadata: %({"source": "manual"}),
      )

      artifact = GalaxyLedger::Database.get_artifact_by_number(session_id, 1)
      artifact.should_not be_nil
      artifact.not_nil!.description.should eq("Monthly revenue data")
      artifact.not_nil!.metadata.should eq(%({"source": "manual"}))
    end

    it "returns Failed for invalid session id" do
      result = GalaxyLedger::Database.save_artifact(
        0_i64,
        title: "Bad",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "bad.csv",
        stored_path: "/tmp/bad",
        source_path: "/tmp/bad.csv",
        file_size: 0_i64,
        content_hash: "h0",
      )
      result.action.should eq(GalaxyLedger::Database::SaveArtifactAction::Failed)
      result.number.should eq(0)
    end
  end

  describe ".save_artifact dedup" do
    it "enriches when same source_path and same content_hash" do
      session_id = GalaxyLedger::Database.create_session("art-dedup-enrich")

      # First save — insert
      r1 = GalaxyLedger::Database.save_artifact(
        session_id,
        title: "data",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "report.csv",
        stored_path: "/stored/001_report.csv",
        source_path: "/tmp/report.csv",
        file_size: 500_i64,
        content_hash: "same_hash",
      )
      r1.action.should eq(GalaxyLedger::Database::SaveArtifactAction::Insert)
      r1.number.should eq(1)

      # Second save — same source_path, same hash, richer title
      r2 = GalaxyLedger::Database.save_artifact(
        session_id,
        title: "Quarterly Revenue Report",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "report.csv",
        stored_path: "",
        source_path: "/tmp/report.csv",
        file_size: 500_i64,
        content_hash: "same_hash",
        description: "Q4 revenue breakdown by region",
      )
      r2.action.should eq(GalaxyLedger::Database::SaveArtifactAction::Enrichment)
      r2.number.should eq(1) # Same number — no duplicate created

      # Verify the title was updated (longer = richer)
      artifact = GalaxyLedger::Database.get_artifact_by_number(session_id, 1)
      artifact.should_not be_nil
      artifact.not_nil!.title.should eq("Quarterly Revenue Report")
      artifact.not_nil!.description.should eq("Q4 revenue breakdown by region")

      # Verify only 1 artifact exists
      GalaxyLedger::Database.session_artifact_count(session_id).should eq(1)
    end

    it "does not overwrite title with shorter one on enrichment" do
      session_id = GalaxyLedger::Database.create_session("art-dedup-title-keep")

      GalaxyLedger::Database.save_artifact(
        session_id,
        title: "Detailed Monthly Analysis Report",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "report.csv",
        stored_path: "/stored/001_report.csv",
        source_path: "/tmp/report.csv",
        file_size: 500_i64,
        content_hash: "same_hash",
      )

      # Enrichment with shorter title — should keep original
      GalaxyLedger::Database.save_artifact(
        session_id,
        title: "report",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "report.csv",
        stored_path: "",
        source_path: "/tmp/report.csv",
        file_size: 500_i64,
        content_hash: "same_hash",
      )

      artifact = GalaxyLedger::Database.get_artifact_by_number(session_id, 1)
      artifact.not_nil!.title.should eq("Detailed Monthly Analysis Report")
    end

    it "version-updates when same source_path but different content_hash" do
      session_id = GalaxyLedger::Database.create_session("art-dedup-version")

      # First save
      r1 = GalaxyLedger::Database.save_artifact(
        session_id,
        title: "data",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "export.csv",
        stored_path: "/stored/001_export.csv",
        source_path: "/tmp/export.csv",
        file_size: 500_i64,
        content_hash: "hash_v1",
      )
      r1.action.should eq(GalaxyLedger::Database::SaveArtifactAction::Insert)
      r1.number.should eq(1)

      # Second save — same source_path, different hash (file was modified)
      r2 = GalaxyLedger::Database.save_artifact(
        session_id,
        title: "Updated Data Export",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "export.csv",
        stored_path: "",
        source_path: "/tmp/export.csv",
        file_size: 750_i64,
        content_hash: "hash_v2",
      )
      r2.action.should eq(GalaxyLedger::Database::SaveArtifactAction::VersionUpdate)
      r2.number.should eq(1) # Same number

      # Verify fields updated
      artifact = GalaxyLedger::Database.get_artifact_by_number(session_id, 1)
      artifact.should_not be_nil
      a = artifact.not_nil!
      a.title.should eq("Updated Data Export")
      a.file_size.should eq(750_i64)
      a.content_hash.should eq("hash_v2")

      # Still only 1 artifact
      GalaxyLedger::Database.session_artifact_count(session_id).should eq(1)
    end

    it "inserts new artifact for different source_path" do
      session_id = GalaxyLedger::Database.create_session("art-dedup-diff-path")

      r1 = GalaxyLedger::Database.save_artifact(
        session_id,
        title: "First file",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "a.csv",
        stored_path: "/stored/1",
        source_path: "/tmp/a.csv",
        file_size: 100_i64,
        content_hash: "h1",
      )
      r2 = GalaxyLedger::Database.save_artifact(
        session_id,
        title: "Second file",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "b.csv",
        stored_path: "/stored/2",
        source_path: "/tmp/b.csv",
        file_size: 200_i64,
        content_hash: "h2",
      )

      r1.action.should eq(GalaxyLedger::Database::SaveArtifactAction::Insert)
      r2.action.should eq(GalaxyLedger::Database::SaveArtifactAction::Insert)
      r1.number.should eq(1)
      r2.number.should eq(2)
      GalaxyLedger::Database.session_artifact_count(session_id).should eq(2)
    end

    it "always inserts when source_path is nil" do
      session_id = GalaxyLedger::Database.create_session("art-dedup-nil-path")

      r1 = GalaxyLedger::Database.save_artifact(
        session_id,
        title: "No path 1",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "a.csv",
        stored_path: "/stored/1",
        source_path: nil,
        file_size: 100_i64,
        content_hash: "h1",
      )
      r2 = GalaxyLedger::Database.save_artifact(
        session_id,
        title: "No path 2",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "b.csv",
        stored_path: "/stored/2",
        source_path: nil,
        file_size: 200_i64,
        content_hash: "h1", # Same hash, but nil path — should still insert
      )

      r1.action.should eq(GalaxyLedger::Database::SaveArtifactAction::Insert)
      r2.action.should eq(GalaxyLedger::Database::SaveArtifactAction::Insert)
      r1.number.should eq(1)
      r2.number.should eq(2)
      GalaxyLedger::Database.session_artifact_count(session_id).should eq(2)
    end

    it "dedup is scoped to session — same source_path in different sessions are separate" do
      session_a = GalaxyLedger::Database.create_session("art-dedup-scope-a")
      session_b = GalaxyLedger::Database.create_session("art-dedup-scope-b")

      r_a = GalaxyLedger::Database.save_artifact(
        session_a,
        title: "Session A file",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "shared.csv",
        stored_path: "/stored/a",
        source_path: "/tmp/shared.csv",
        file_size: 100_i64,
        content_hash: "h1",
      )
      r_b = GalaxyLedger::Database.save_artifact(
        session_b,
        title: "Session B file",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "shared.csv",
        stored_path: "/stored/b",
        source_path: "/tmp/shared.csv",
        file_size: 100_i64,
        content_hash: "h1",
      )

      r_a.action.should eq(GalaxyLedger::Database::SaveArtifactAction::Insert)
      r_b.action.should eq(GalaxyLedger::Database::SaveArtifactAction::Insert)
      r_a.number.should eq(1)
      r_b.number.should eq(1)
    end

    it "preserves existing description on enrichment when new description is nil" do
      session_id = GalaxyLedger::Database.create_session("art-dedup-desc-nil")

      GalaxyLedger::Database.save_artifact(
        session_id,
        title: "data",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "report.csv",
        stored_path: "/stored/001_report.csv",
        source_path: "/tmp/report.csv",
        file_size: 500_i64,
        content_hash: "same_hash",
        description: "Original description",
      )

      # Enrichment without description — should keep original
      GalaxyLedger::Database.save_artifact(
        session_id,
        title: "Longer Title For Report",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "report.csv",
        stored_path: "",
        source_path: "/tmp/report.csv",
        file_size: 500_i64,
        content_hash: "same_hash",
      )

      artifact = GalaxyLedger::Database.get_artifact_by_number(session_id, 1)
      artifact.not_nil!.description.should eq("Original description")
    end
  end

  describe ".list_artifacts" do
    it "returns artifacts in number order" do
      session_id = GalaxyLedger::Database.create_session("art-list-1")
      GalaxyLedger::Database.save_artifact(session_id, title: "First", artifact_type: "csv", mime_type: "text/csv", original_filename: "a.csv", stored_path: "/1", source_path: "/a.csv", file_size: 100_i64, content_hash: "h1")
      GalaxyLedger::Database.save_artifact(session_id, title: "Second", artifact_type: "pdf", mime_type: "application/pdf", original_filename: "b.pdf", stored_path: "/2", source_path: "/b.pdf", file_size: 200_i64, content_hash: "h2")
      GalaxyLedger::Database.save_artifact(session_id, title: "Third", artifact_type: "image", mime_type: "image/png", original_filename: "c.png", stored_path: "/3", source_path: "/c.png", file_size: 300_i64, content_hash: "h3")

      artifacts = GalaxyLedger::Database.list_artifacts(session_id)
      artifacts.size.should eq(3)
      artifacts[0].number.should eq(1)
      artifacts[0].title.should eq("First")
      artifacts[1].number.should eq(2)
      artifacts[2].number.should eq(3)
    end

    it "respects limit" do
      session_id = GalaxyLedger::Database.create_session("art-list-limit")
      GalaxyLedger::Database.save_artifact(session_id, title: "A", artifact_type: "csv", mime_type: "text/csv", original_filename: "a.csv", stored_path: "/1", source_path: "/a", file_size: 1_i64, content_hash: "h1")
      GalaxyLedger::Database.save_artifact(session_id, title: "B", artifact_type: "csv", mime_type: "text/csv", original_filename: "b.csv", stored_path: "/2", source_path: "/b", file_size: 1_i64, content_hash: "h2")
      GalaxyLedger::Database.save_artifact(session_id, title: "C", artifact_type: "csv", mime_type: "text/csv", original_filename: "c.csv", stored_path: "/3", source_path: "/c", file_size: 1_i64, content_hash: "h3")

      artifacts = GalaxyLedger::Database.list_artifacts(session_id, limit: 2)
      artifacts.size.should eq(2)
    end

    it "returns empty array for session with no artifacts" do
      session_id = GalaxyLedger::Database.create_session("art-list-empty")
      artifacts = GalaxyLedger::Database.list_artifacts(session_id)
      artifacts.should be_empty
    end

    it "returns empty array for invalid session id" do
      artifacts = GalaxyLedger::Database.list_artifacts(0_i64)
      artifacts.should be_empty
    end

    it "only returns artifacts for the specified session" do
      session_a = GalaxyLedger::Database.create_session("art-list-a")
      session_b = GalaxyLedger::Database.create_session("art-list-b")

      GalaxyLedger::Database.save_artifact(session_a, title: "A art", artifact_type: "csv", mime_type: "text/csv", original_filename: "a.csv", stored_path: "/a", source_path: "/a", file_size: 1_i64, content_hash: "ha")
      GalaxyLedger::Database.save_artifact(session_b, title: "B art", artifact_type: "csv", mime_type: "text/csv", original_filename: "b.csv", stored_path: "/b", source_path: "/b", file_size: 1_i64, content_hash: "hb")

      a_arts = GalaxyLedger::Database.list_artifacts(session_a)
      a_arts.size.should eq(1)
      a_arts[0].title.should eq("A art")
    end
  end

  describe ".get_artifact_by_number" do
    it "returns artifact by session and number" do
      session_id = GalaxyLedger::Database.create_session("art-get-1")
      GalaxyLedger::Database.save_artifact(session_id, title: "Target", artifact_type: "csv", mime_type: "text/csv", original_filename: "target.csv", stored_path: "/stored", source_path: "/original.csv", file_size: 512_i64, content_hash: "htarget")

      artifact = GalaxyLedger::Database.get_artifact_by_number(session_id, 1)
      artifact.should_not be_nil
      a = artifact.not_nil!
      a.title.should eq("Target")
      a.artifact_type.should eq("csv")
      a.mime_type.should eq("text/csv")
      a.original_filename.should eq("target.csv")
      a.stored_path.should eq("/stored")
      a.source_path.should eq("/original.csv")
      a.file_size.should eq(512_i64)
      a.content_hash.should eq("htarget")
      a.number.should eq(1)
      a.ledger_session_id.should eq(session_id)
    end

    it "returns nil for non-existent number" do
      session_id = GalaxyLedger::Database.create_session("art-get-miss")
      GalaxyLedger::Database.save_artifact(session_id, title: "Only one", artifact_type: "csv", mime_type: "text/csv", original_filename: "a.csv", stored_path: "/a", source_path: "/a", file_size: 1_i64, content_hash: "h1")

      artifact = GalaxyLedger::Database.get_artifact_by_number(session_id, 99)
      artifact.should be_nil
    end

    it "returns nil for invalid session id" do
      artifact = GalaxyLedger::Database.get_artifact_by_number(0_i64, 1)
      artifact.should be_nil
    end

    it "does not return artifact from different session" do
      session_a = GalaxyLedger::Database.create_session("art-get-a")
      session_b = GalaxyLedger::Database.create_session("art-get-b")
      GalaxyLedger::Database.save_artifact(session_a, title: "A only", artifact_type: "csv", mime_type: "text/csv", original_filename: "a.csv", stored_path: "/a", source_path: "/a", file_size: 1_i64, content_hash: "ha")

      artifact = GalaxyLedger::Database.get_artifact_by_number(session_b, 1)
      artifact.should be_nil
    end
  end

  describe ".delete_artifact_by_number" do
    it "deletes record and returns true" do
      session_id = GalaxyLedger::Database.create_session("art-del-1")

      # Create a real stored file so delete can clean it up
      session_dir = GalaxyLedger::ArtifactStorage::ARTIFACTS_DIR / session_id.to_s
      Dir.mkdir_p(session_dir)
      stored_file = (session_dir / "001_test.csv").to_s
      File.write(stored_file, "data")

      GalaxyLedger::Database.save_artifact(session_id, title: "To delete", artifact_type: "csv", mime_type: "text/csv", original_filename: "test.csv", stored_path: stored_file, source_path: "/tmp/test.csv", file_size: 4_i64, content_hash: "hd")

      result = GalaxyLedger::Database.delete_artifact_by_number(session_id, 1)
      result.should be_true

      # Verify DB record gone
      artifact = GalaxyLedger::Database.get_artifact_by_number(session_id, 1)
      artifact.should be_nil

      # Verify file deleted
      File.exists?(stored_file).should be_false
    end

    it "returns false for non-existent number" do
      session_id = GalaxyLedger::Database.create_session("art-del-miss")
      result = GalaxyLedger::Database.delete_artifact_by_number(session_id, 99)
      result.should be_false
    end

    it "returns false for invalid session id" do
      result = GalaxyLedger::Database.delete_artifact_by_number(0_i64, 1)
      result.should be_false
    end
  end

  describe ".session_artifact_count" do
    it "returns correct count" do
      session_id = GalaxyLedger::Database.create_session("art-count-1")
      GalaxyLedger::Database.save_artifact(session_id, title: "A", artifact_type: "csv", mime_type: "text/csv", original_filename: "a.csv", stored_path: "/a", source_path: "/a", file_size: 1_i64, content_hash: "h1")
      GalaxyLedger::Database.save_artifact(session_id, title: "B", artifact_type: "pdf", mime_type: "application/pdf", original_filename: "b.pdf", stored_path: "/b", source_path: "/b", file_size: 2_i64, content_hash: "h2")

      GalaxyLedger::Database.session_artifact_count(session_id).should eq(2)
    end

    it "returns 0 for session with no artifacts" do
      session_id = GalaxyLedger::Database.create_session("art-count-empty")
      GalaxyLedger::Database.session_artifact_count(session_id).should eq(0)
    end

    it "returns 0 for invalid session id" do
      GalaxyLedger::Database.session_artifact_count(0_i64).should eq(0)
    end
  end

  describe ".update_artifact_stored_path" do
    it "updates the stored_path for an artifact" do
      session_id = GalaxyLedger::Database.create_session("art-update-path")
      GalaxyLedger::Database.save_artifact(session_id, title: "Update me", artifact_type: "csv", mime_type: "text/csv", original_filename: "a.csv", stored_path: "", source_path: "/a.csv", file_size: 100_i64, content_hash: "hu")

      GalaxyLedger::Database.update_artifact_stored_path(session_id, 1, "/new/stored/path.csv")

      artifact = GalaxyLedger::Database.get_artifact_by_number(session_id, 1)
      artifact.should_not be_nil
      artifact.not_nil!.stored_path.should eq("/new/stored/path.csv")
    end
  end

  describe "cascade delete" do
    it "deletes artifacts when session is deleted" do
      session_id = GalaxyLedger::Database.create_session("art-cascade")
      GalaxyLedger::Database.save_artifact(session_id, title: "Will cascade", artifact_type: "csv", mime_type: "text/csv", original_filename: "a.csv", stored_path: "/a", source_path: "/a", file_size: 1_i64, content_hash: "hc1")
      GalaxyLedger::Database.save_artifact(session_id, title: "Also cascade", artifact_type: "pdf", mime_type: "application/pdf", original_filename: "b.pdf", stored_path: "/b", source_path: "/b", file_size: 2_i64, content_hash: "hc2")

      # Verify they exist
      GalaxyLedger::Database.session_artifact_count(session_id).should eq(2)

      # Delete the session
      GalaxyLedger::Database.delete_session(session_id)

      # Artifacts should be gone
      GalaxyLedger::Database.open do |db|
        count = db.scalar(
          "SELECT COUNT(*) FROM ledger_artifacts WHERE ledger_session_id = ?",
          session_id,
        ).as(Int64)
        count.should eq(0)
      end
    end
  end

  describe "Artifact struct" do
    it "has all expected fields" do
      session_id = GalaxyLedger::Database.create_session("art-struct")
      GalaxyLedger::Database.save_artifact(
        session_id,
        title: "Full struct",
        artifact_type: "csv",
        mime_type: "text/csv",
        original_filename: "full.csv",
        stored_path: "/stored/full.csv",
        source_path: "/original/full.csv",
        file_size: 1024_i64,
        content_hash: "abc123def456",
        description: "A test artifact",
        metadata: %({"key": "val"}),
      )

      artifact = GalaxyLedger::Database.get_artifact_by_number(session_id, 1)
      artifact.should_not be_nil
      a = artifact.not_nil!

      a.id.should be > 0
      a.ledger_session_id.should eq(session_id)
      a.number.should eq(1)
      a.created_at.should_not be_empty
      a.updated_at.should_not be_empty
      a.title.should eq("Full struct")
      a.artifact_type.should eq("csv")
      a.mime_type.should eq("text/csv")
      a.original_filename.should eq("full.csv")
      a.stored_path.should eq("/stored/full.csv")
      a.source_path.should eq("/original/full.csv")
      a.file_size.should eq(1024_i64)
      a.content_hash.should eq("abc123def456")
      a.description.should eq("A test artifact")
      a.metadata.should eq(%({"key": "val"}))
    end
  end

  describe "SaveArtifactResult struct" do
    it "exposes action and number" do
      result = GalaxyLedger::Database::SaveArtifactResult.new(
        GalaxyLedger::Database::SaveArtifactAction::Insert, 1,
      )
      result.action.should eq(GalaxyLedger::Database::SaveArtifactAction::Insert)
      result.number.should eq(1)
      result.action.insert?.should be_true
      result.action.failed?.should be_false
    end

    it "reports enrichment action correctly" do
      result = GalaxyLedger::Database::SaveArtifactResult.new(
        GalaxyLedger::Database::SaveArtifactAction::Enrichment, 3,
      )
      result.action.enrichment?.should be_true
      result.number.should eq(3)
    end

    it "reports version_update action correctly" do
      result = GalaxyLedger::Database::SaveArtifactResult.new(
        GalaxyLedger::Database::SaveArtifactAction::VersionUpdate, 2,
      )
      result.action.version_update?.should be_true
      result.number.should eq(2)
    end

    it "reports failed action correctly" do
      result = GalaxyLedger::Database::SaveArtifactResult.new(
        GalaxyLedger::Database::SaveArtifactAction::Failed, 0,
      )
      result.action.failed?.should be_true
      result.number.should eq(0)
    end
  end
end
