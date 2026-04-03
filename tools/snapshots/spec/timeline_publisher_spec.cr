require "./spec_helper"

describe GalaxySnapshots::TimelinePublisher do
  describe ".snapshot_created" do
    it "does not raise when timeline binary missing" do
      ENV["GALAXY_TIMELINE_BIN"] = "/nonexistent/bin"

      GalaxySnapshots::TimelinePublisher
        .snapshot_created(
          1_i64,
          snapshot_number: 1,
          title: "Test snapshot",
          exchange_count: 5,
          char_count: 1234,
        )

      ENV["GALAXY_TIMELINE_BIN"] =
        SPEC_TIMELINE_NOOP.to_s
    end
  end

  describe ".annotation_created" do
    it "does not raise when timeline binary missing" do
      ENV["GALAXY_TIMELINE_BIN"] = "/nonexistent/bin"

      GalaxySnapshots::TimelinePublisher
        .annotation_created(
          1_i64,
          snapshot_id: 42_i64,
          snapshot_number: 1,
          snapshot_title: "Test snapshot",
          annotation_number: 1,
          start_line: 5,
          end_line: 10,
          content: "This is a test annotation",
        )

      ENV["GALAXY_TIMELINE_BIN"] =
        SPEC_TIMELINE_NOOP.to_s
    end
  end

  describe ".annotation_updated" do
    it "does not raise when timeline binary missing" do
      ENV["GALAXY_TIMELINE_BIN"] = "/nonexistent/bin"

      GalaxySnapshots::TimelinePublisher
        .annotation_updated(
          1_i64,
          snapshot_id: 42_i64,
          snapshot_number: 1,
          snapshot_title: "Test snapshot",
          annotation_number: 1,
          content: "Updated annotation text",
        )

      ENV["GALAXY_TIMELINE_BIN"] =
        SPEC_TIMELINE_NOOP.to_s
    end
  end

  describe ".annotation_deleted" do
    it "does not raise when timeline binary missing" do
      ENV["GALAXY_TIMELINE_BIN"] = "/nonexistent/bin"

      GalaxySnapshots::TimelinePublisher
        .annotation_deleted(
          1_i64,
          snapshot_id: 42_i64,
          snapshot_number: 1,
          snapshot_title: "Test snapshot",
          annotation_number: 3,
          content: "Deleted annotation text",
        )

      ENV["GALAXY_TIMELINE_BIN"] =
        SPEC_TIMELINE_NOOP.to_s
    end
  end

  describe ".review_created" do
    it "does not raise when timeline binary missing" do
      ENV["GALAXY_TIMELINE_BIN"] = "/nonexistent/bin"

      GalaxySnapshots::TimelinePublisher
        .review_created(
          1_i64,
          snapshot_id: 42_i64,
          snapshot_number: 1,
          snapshot_title: "Test snapshot",
          review_number: 1,
          annotation_count: 3,
        )

      ENV["GALAXY_TIMELINE_BIN"] =
        SPEC_TIMELINE_NOOP.to_s
    end
  end
end
