require "./spec_helper"

describe GalaxyArtifacts::TimelinePublisher do
  describe ".artifact_created" do
    it "does not raise when timeline binary is missing" do
      # Override to a non-existent path
      ENV["GALAXY_TIMELINE_BIN"] = "/nonexistent/bin"

      # Should silently rescue — no exception
      GalaxyArtifacts::TimelinePublisher.artifact_created(
        1_i64,
        number: 1,
        title: "Test",
        artifact_type: "csv",
        source_path: "/tmp/test.csv",
        file_size: 100_i64,
        content_hash: "abc123",
      )

      # Restore
      ENV["GALAXY_TIMELINE_BIN"] = SPEC_TIMELINE_NOOP.to_s
    end
  end

  describe ".artifact_updated" do
    it "does not raise when timeline binary is missing" do
      ENV["GALAXY_TIMELINE_BIN"] = "/nonexistent/bin"

      GalaxyArtifacts::TimelinePublisher.artifact_updated(
        1_i64,
        number: 1,
        title: "Test",
        artifact_type: "csv",
        source_path: "/tmp/test.csv",
        file_size: 200_i64,
        content_hash: "def456",
        previous_file_size: 100_i64,
        previous_content_hash: "abc123",
      )

      ENV["GALAXY_TIMELINE_BIN"] = SPEC_TIMELINE_NOOP.to_s
    end
  end

  describe ".artifact_deleted" do
    it "does not raise when timeline binary is missing" do
      ENV["GALAXY_TIMELINE_BIN"] = "/nonexistent/bin"

      GalaxyArtifacts::TimelinePublisher.artifact_deleted(
        1_i64,
        number: 1,
        title: "Test",
        artifact_type: "csv",
      )

      ENV["GALAXY_TIMELINE_BIN"] = SPEC_TIMELINE_NOOP.to_s
    end
  end
end
