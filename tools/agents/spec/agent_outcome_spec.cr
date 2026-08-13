require "./spec_helper"

# Reading a death the agent declared about itself.
#
# Every example that is not an explicit, final, api-error record must answer
# nil. `stop_agent` will not move a terminal row back, so a false positive
# here is permanent — nil is the safe answer and the default one.
describe GalaxyAgents::AgentOutcome do
  before_each do
    root = SPEC_CLAUDE_CONFIG_DIR / "projects"
    FileUtils.rm_rf(root.to_s) if Dir.exists?(root.to_s)
  end

  describe ".transcript_path" do
    it "finds a transcript nested under project and session" do
      write_transcript("find-me", [clean_record])

      path = GalaxyAgents::AgentOutcome
        .transcript_path("find-me")
      path.should_not be_nil
      path.not_nil!.should end_with(
        "subagents/agent-find-me.jsonl",
      )
    end

    it "finds nothing for an unknown agent" do
      GalaxyAgents::AgentOutcome
        .transcript_path("never-existed").should be_nil
    end

    it "refuses an empty agent id rather than globbing" do
      GalaxyAgents::AgentOutcome
        .transcript_path("").should be_nil
    end
  end

  describe ".error_death" do
    it "reads a declared death and why" do
      write_transcript("dead-1", [clean_record, error_record])

      death = GalaxyAgents::AgentOutcome
        .error_death("dead-1")
      death.should_not be_nil
      death.not_nil!.message.should eq(
        "API Error: Connection lost mid-response.",
      )
      # RFC3339 in the transcript, database shape out.
      death.not_nil!.died_at.should eq(
        "2026-08-13 19:45:10",
      )
    end

    it "ignores an agent that finished cleanly" do
      write_transcript("clean-1", [clean_record, clean_record])

      GalaxyAgents::AgentOutcome
        .error_death("clean-1").should be_nil
    end

    # An error mid-run is not a death: the agent carried on and
    # wrote afterwards. Only the LAST record decides.
    it "ignores an error the agent recovered from" do
      write_transcript(
        "recovered-1", [error_record, clean_record],
      )

      GalaxyAgents::AgentOutcome
        .error_death("recovered-1").should be_nil
    end

    it "ignores a transcript that is not there" do
      GalaxyAgents::AgentOutcome
        .error_death("absent-1").should be_nil
    end

    it "ignores an empty transcript" do
      write_transcript("empty-1", [] of String)

      GalaxyAgents::AgentOutcome
        .error_death("empty-1").should be_nil
    end

    it "ignores a trailing line that will not parse" do
      write_transcript(
        "garbage-1", [error_record, "{not json at all"],
      )

      GalaxyAgents::AgentOutcome
        .error_death("garbage-1").should be_nil
    end

    # Writing `failed` is only worth more than `abandoned` if it
    # carries a reason, so a reason is always produced.
    it "falls back to the error field with no text block" do
      write_transcript("nofield-1", [
        {
          "type"              => "assistant",
          "isApiErrorMessage" => true,
          "error"             => "overloaded_error",
          "timestamp"         => "2026-08-13T19:45:10.130Z",
        }.to_json,
      ])

      GalaxyAgents::AgentOutcome
        .error_death("nofield-1").not_nil!
        .message.should eq("API error: overloaded_error")
    end

    it "still reports a death with no usable timestamp" do
      write_transcript("notime-1", [
        error_record(timestamp: "not-a-timestamp"),
      ])

      death = GalaxyAgents::AgentOutcome
        .error_death("notime-1").not_nil!
      death.died_at.should be_nil
      death.message.should_not be_empty
    end
  end

  describe ".duration_ms" do
    it "measures from start to the declared death" do
      GalaxyAgents::AgentOutcome.duration_ms(
        started_at: "2026-08-13 19:22:24",
        died_at: "2026-08-13 19:45:10",
      ).should eq(1_366_000_i64)
    end

    it "declines rather than invent one" do
      GalaxyAgents::AgentOutcome.duration_ms(
        started_at: "2026-08-13 19:22:24", died_at: nil,
      ).should be_nil
      GalaxyAgents::AgentOutcome.duration_ms(
        started_at: "nonsense",
        died_at: "2026-08-13 19:45:10",
      ).should be_nil
    end

    # A death recorded before the start is a clock we cannot
    # trust, not a negative duration to store.
    it "declines a death that precedes the start" do
      GalaxyAgents::AgentOutcome.duration_ms(
        started_at: "2026-08-13 19:45:10",
        died_at: "2026-08-13 19:22:24",
      ).should be_nil
    end
  end
end
