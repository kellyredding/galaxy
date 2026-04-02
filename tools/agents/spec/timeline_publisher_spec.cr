require "./spec_helper"

describe GalaxyAgents::TimelinePublisher do
  describe ".agent_started" do
    it "does not raise when timeline binary missing" do
      ENV["GALAXY_TIMELINE_BIN"] = "/nonexistent/bin"

      GalaxyAgents::TimelinePublisher.agent_started(
        1_i64,
        agent_id: "abc123",
        agent_type: "Explore",
        description: "Find files",
      )

      ENV["GALAXY_TIMELINE_BIN"] = SPEC_TIMELINE_NOOP.to_s
    end
  end

  describe ".agent_stopped" do
    it "does not raise when timeline binary missing" do
      ENV["GALAXY_TIMELINE_BIN"] = "/nonexistent/bin"

      GalaxyAgents::TimelinePublisher.agent_stopped(
        1_i64,
        agent_id: "abc123",
        agent_type: "Explore",
        duration_ms: 12_450_i64,
        prompt: "Search for files",
        last_message: "Found 15 files",
      )

      ENV["GALAXY_TIMELINE_BIN"] = SPEC_TIMELINE_NOOP.to_s
    end
  end

  describe ".agent_failed" do
    it "does not raise when timeline binary missing" do
      ENV["GALAXY_TIMELINE_BIN"] = "/nonexistent/bin"

      GalaxyAgents::TimelinePublisher.agent_failed(
        1_i64,
        agent_id: "abc123",
        agent_type: "Explore",
        duration_ms: 3_200_i64,
        prompt: "Search for files",
        last_message: nil,
      )

      ENV["GALAXY_TIMELINE_BIN"] = SPEC_TIMELINE_NOOP.to_s
    end
  end

  describe ".agent_abandoned" do
    it "does not raise when timeline binary missing" do
      ENV["GALAXY_TIMELINE_BIN"] = "/nonexistent/bin"

      GalaxyAgents::TimelinePublisher.agent_abandoned(
        1_i64,
        agent_id: "abc123",
        agent_type: "Explore",
      )

      ENV["GALAXY_TIMELINE_BIN"] = SPEC_TIMELINE_NOOP.to_s
    end
  end
end
