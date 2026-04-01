require "../spec_helper"

describe GalaxyArtifacts::Database do
  # Clean database before each test
  before_each do
    db_path = GalaxyArtifacts::Database.database_path
    File.delete(db_path) if File.exists?(db_path)
  end

  describe ".save_artifact" do
    it "inserts a new artifact and returns number 1" do
      result = GalaxyArtifacts::Database.save_artifact(
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
      result.action.should eq(GalaxyArtifacts::Database::SaveArtifactAction::Insert)
      result.number.should eq(1)
    end

    it "increments numbers sequentially within the same session" do
      r1 = GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "First", artifact_type: "text", mime_type: "text/plain",
        original_filename: "a.txt", stored_path: "", source_path: "/tmp/a.txt",
        file_size: 10_i64, content_hash: "h1",
      )
      r2 = GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "Second", artifact_type: "text", mime_type: "text/plain",
        original_filename: "b.txt", stored_path: "", source_path: "/tmp/b.txt",
        file_size: 20_i64, content_hash: "h2",
      )
      r3 = GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "Third", artifact_type: "text", mime_type: "text/plain",
        original_filename: "c.txt", stored_path: "", source_path: "/tmp/c.txt",
        file_size: 30_i64, content_hash: "h3",
      )

      r1.number.should eq(1)
      r2.number.should eq(2)
      r3.number.should eq(3)
    end

    it "starts numbering at 1 for a new session" do
      GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "A", artifact_type: "text", mime_type: "text/plain",
        original_filename: "a.txt", stored_path: "", source_path: "/tmp/a.txt",
        file_size: 10_i64, content_hash: "h1",
      )

      r = GalaxyArtifacts::Database.save_artifact(
        2_i64, title: "B", artifact_type: "text", mime_type: "text/plain",
        original_filename: "b.txt", stored_path: "", source_path: "/tmp/b.txt",
        file_size: 10_i64, content_hash: "h2",
      )
      r.number.should eq(1)
    end

    it "returns enrichment when same source_path and same content_hash" do
      GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "Original", artifact_type: "csv", mime_type: "text/csv",
        original_filename: "test.csv", stored_path: "/stored/001_test.csv",
        source_path: "/tmp/test.csv", file_size: 100_i64, content_hash: "same_hash",
      )

      r = GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "A longer title now", artifact_type: "csv", mime_type: "text/csv",
        original_filename: "test.csv", stored_path: "/stored/001_test.csv",
        source_path: "/tmp/test.csv", file_size: 100_i64, content_hash: "same_hash",
        description: "new desc",
      )
      r.action.should eq(GalaxyArtifacts::Database::SaveArtifactAction::Enrichment)
      r.number.should eq(1)

      # Title should have been updated (longer)
      art = GalaxyArtifacts::Database.get_artifact_by_number(1_i64, 1)
      art.should_not be_nil
      art.not_nil!.title.should eq("A longer title now")
      art.not_nil!.description.should eq("new desc")
    end

    it "returns version_update with previous state" do
      GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "Original", artifact_type: "csv", mime_type: "text/csv",
        original_filename: "test.csv", stored_path: "/stored/001_test.csv",
        source_path: "/tmp/test.csv", file_size: 100_i64, content_hash: "hash_v1",
      )

      r = GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "Original", artifact_type: "csv", mime_type: "text/csv",
        original_filename: "test.csv", stored_path: "/stored/001_test.csv",
        source_path: "/tmp/test.csv", file_size: 200_i64, content_hash: "hash_v2",
      )
      r.action.should eq(GalaxyArtifacts::Database::SaveArtifactAction::VersionUpdate)
      r.number.should eq(1)
      r.previous_content_hash.should eq("hash_v1")
      r.previous_file_size.should eq(100_i64)
    end

    it "inserts new when source_path is nil" do
      r1 = GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "No source 1", artifact_type: "text", mime_type: "text/plain",
        original_filename: "a.txt", stored_path: "", source_path: nil,
        file_size: 10_i64, content_hash: "h1",
      )
      r2 = GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "No source 2", artifact_type: "text", mime_type: "text/plain",
        original_filename: "b.txt", stored_path: "", source_path: nil,
        file_size: 10_i64, content_hash: "h1",
      )
      r1.action.should eq(GalaxyArtifacts::Database::SaveArtifactAction::Insert)
      r2.action.should eq(GalaxyArtifacts::Database::SaveArtifactAction::Insert)
      r1.number.should eq(1)
      r2.number.should eq(2)
    end

    it "returns failed for invalid session id" do
      result = GalaxyArtifacts::Database.save_artifact(
        0_i64, title: "Bad", artifact_type: "text", mime_type: "text/plain",
        original_filename: "a.txt", stored_path: "", source_path: nil,
        file_size: 0_i64, content_hash: "",
      )
      result.action.should eq(GalaxyArtifacts::Database::SaveArtifactAction::Failed)
    end
  end

  describe ".list_artifacts" do
    it "returns artifacts in number order" do
      GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "First", artifact_type: "text", mime_type: "text/plain",
        original_filename: "a.txt", stored_path: "", source_path: "/tmp/a.txt",
        file_size: 10_i64, content_hash: "h1",
      )
      GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "Second", artifact_type: "csv", mime_type: "text/csv",
        original_filename: "b.csv", stored_path: "", source_path: "/tmp/b.csv",
        file_size: 20_i64, content_hash: "h2",
      )

      artifacts = GalaxyArtifacts::Database.list_artifacts(1_i64)
      artifacts.size.should eq(2)
      artifacts[0].number.should eq(1)
      artifacts[0].title.should eq("First")
      artifacts[1].number.should eq(2)
      artifacts[1].title.should eq("Second")
    end

    it "respects limit" do
      3.times do |i|
        GalaxyArtifacts::Database.save_artifact(
          1_i64, title: "Art #{i}", artifact_type: "text", mime_type: "text/plain",
          original_filename: "#{i}.txt", stored_path: "", source_path: "/tmp/#{i}.txt",
          file_size: 10_i64, content_hash: "h#{i}",
        )
      end

      artifacts = GalaxyArtifacts::Database.list_artifacts(1_i64, limit: 2)
      artifacts.size.should eq(2)
    end

    it "returns empty array for session with no artifacts" do
      artifacts = GalaxyArtifacts::Database.list_artifacts(999_i64)
      artifacts.should be_empty
    end

    it "returns empty array for invalid session" do
      artifacts = GalaxyArtifacts::Database.list_artifacts(0_i64)
      artifacts.should be_empty
    end
  end

  describe ".get_artifact_by_number" do
    it "retrieves an artifact by session and number" do
      GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "My CSV", artifact_type: "csv", mime_type: "text/csv",
        original_filename: "data.csv", stored_path: "/stored/001_data.csv",
        source_path: "/tmp/data.csv", file_size: 500_i64, content_hash: "h1",
        description: "Test data",
      )

      art = GalaxyArtifacts::Database.get_artifact_by_number(1_i64, 1)
      art.should_not be_nil
      a = art.not_nil!
      a.title.should eq("My CSV")
      a.artifact_type.should eq("csv")
      a.mime_type.should eq("text/csv")
      a.original_filename.should eq("data.csv")
      a.file_size.should eq(500)
      a.description.should eq("Test data")
    end

    it "returns nil when not found" do
      art = GalaxyArtifacts::Database.get_artifact_by_number(1_i64, 99)
      art.should be_nil
    end

    it "returns nil for invalid session" do
      art = GalaxyArtifacts::Database.get_artifact_by_number(0_i64, 1)
      art.should be_nil
    end
  end

  describe ".delete_artifact_by_number" do
    it "deletes an artifact and its stored file" do
      # Create a temp file to act as stored artifact
      stored_dir = SPEC_DATA_DIR / "artifacts" / "1"
      Dir.mkdir_p(stored_dir)
      stored_file = (stored_dir / "001_test.csv").to_s
      File.write(stored_file, "content")

      GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "Delete me", artifact_type: "csv", mime_type: "text/csv",
        original_filename: "test.csv", stored_path: stored_file,
        source_path: "/tmp/test.csv", file_size: 7_i64, content_hash: "h1",
      )

      result = GalaxyArtifacts::Database.delete_artifact_by_number(1_i64, 1)
      result.should be_true
      File.exists?(stored_file).should be_false
      # Session dir should be removed since it's now empty
      Dir.exists?(stored_dir).should be_false
    end

    it "returns false when not found" do
      result = GalaxyArtifacts::Database.delete_artifact_by_number(1_i64, 99)
      result.should be_false
    end
  end

  describe ".session_artifact_count" do
    it "returns the count of artifacts for a session" do
      GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "A", artifact_type: "text", mime_type: "text/plain",
        original_filename: "a.txt", stored_path: "", source_path: "/tmp/a.txt",
        file_size: 10_i64, content_hash: "h1",
      )
      GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "B", artifact_type: "text", mime_type: "text/plain",
        original_filename: "b.txt", stored_path: "", source_path: "/tmp/b.txt",
        file_size: 10_i64, content_hash: "h2",
      )

      GalaxyArtifacts::Database.session_artifact_count(1_i64).should eq(2)
    end

    it "returns 0 for empty session" do
      GalaxyArtifacts::Database.session_artifact_count(999_i64).should eq(0)
    end

    it "returns 0 for invalid session" do
      GalaxyArtifacts::Database.session_artifact_count(0_i64).should eq(0)
    end
  end

  describe ".update_artifact_stored_path" do
    it "updates the stored path" do
      GalaxyArtifacts::Database.save_artifact(
        1_i64, title: "Update path", artifact_type: "text", mime_type: "text/plain",
        original_filename: "a.txt", stored_path: "/old/path",
        source_path: "/tmp/a.txt", file_size: 10_i64, content_hash: "h1",
      )

      GalaxyArtifacts::Database.update_artifact_stored_path(1_i64, 1, "/new/path")

      art = GalaxyArtifacts::Database.get_artifact_by_number(1_i64, 1)
      art.should_not be_nil
      art.not_nil!.stored_path.should eq("/new/path")
    end
  end
end
