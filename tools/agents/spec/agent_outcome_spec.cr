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

  # Reading a cancellation the parent declared.
  #
  # `SubagentStop` never fires for one, so the parent transcript is the only
  # record that it happened. Same standard as a death the agent wrote down:
  # a marker naming this agent is proof, and every uncertain answer is nil.
  describe ".cancellation" do
    it "reads a cancellation the parent recorded" do
      write_transcript("aaa111", [clean_record])
      write_parent_transcript([
        %({"type":"user","timestamp":"2026-08-14T21:00:00.000Z"}),
        cancel_record("aaa111"),
      ])

      result = GalaxyAgents::AgentOutcome
        .cancellation("aaa111")
      result.should_not be_nil
      result.not_nil!.died_at
        .should eq("2026-08-14 21:05:00")
    end

    # The marker names one agent. A sibling cancelled in the
    # same session must not close this row.
    it "ignores a cancellation naming another agent" do
      write_transcript("aaa111", [clean_record])
      write_parent_transcript([cancel_record("bbb222")])

      GalaxyAgents::AgentOutcome
        .cancellation("aaa111").should be_nil
    end

    # A prefix is not a name. Cancelling `abcdef` must not close
    # `abc`, which a plain substring match does — and
    # `stop_agent` will not move a terminal row back.
    it "ignores a cancellation whose id merely contains this one" do
      write_transcript("abc", [clean_record])
      write_parent_transcript([cancel_record("abcdef")])

      GalaxyAgents::AgentOutcome
        .cancellation("abc").should be_nil
    end

    it "ignores a cancellation this id merely contains" do
      write_transcript("abcdef", [clean_record])
      write_parent_transcript([cancel_record("abc")])

      GalaxyAgents::AgentOutcome
        .cancellation("abcdef").should be_nil
    end

    # The suffix half of the same trap.
    it "ignores a cancellation whose id ends with this one" do
      write_transcript("cdef", [clean_record])
      write_parent_transcript([cancel_record("abcdef")])

      GalaxyAgents::AgentOutcome
        .cancellation("cdef").should be_nil
    end

    # And the real shape still matches once the guard is in.
    it "still matches the exact id among longer siblings" do
      write_transcript("abcdef", [clean_record])
      write_parent_transcript([
        cancel_record("abc"),
        cancel_record("abcdef"),
      ])

      GalaxyAgents::AgentOutcome
        .cancellation("abcdef").should_not be_nil
    end

    it "answers nil when the parent records no cancellation" do
      write_transcript("aaa111", [clean_record])
      write_parent_transcript([
        %({"type":"user","timestamp":"2026-08-14T21:00:00.000Z"}),
      ])

      GalaxyAgents::AgentOutcome
        .cancellation("aaa111").should be_nil
    end

    it "answers nil when the parent transcript is absent" do
      write_transcript("aaa111", [clean_record])

      GalaxyAgents::AgentOutcome
        .cancellation("aaa111").should be_nil
    end

    it "answers nil for an agent with no transcript" do
      write_parent_transcript([cancel_record("aaa111")])

      GalaxyAgents::AgentOutcome
        .cancellation("never-existed").should be_nil
    end

    it "answers nil for an empty agent id" do
      GalaxyAgents::AgentOutcome.cancellation("")
        .should be_nil
    end

    # A matched marker is proof the stop happened; only when is
    # in doubt. Losing the whole cancellation because its line
    # will not parse would put the row back to waiting days for
    # the liveness rule.
    it "reports a cancellation with no time when the line will not parse" do
      write_transcript("aaa111", [clean_record])
      write_parent_transcript([
        "Successfully stopped task: aaa111 (not json)",
      ])

      result = GalaxyAgents::AgentOutcome
        .cancellation("aaa111")
      result.should_not be_nil
      result.not_nil!.died_at.should be_nil
    end

    # The first stop is the one that ended it; a later line
    # mentioning the same agent cannot un-cancel it.
    it "takes the first cancellation when several match" do
      write_transcript("aaa111", [clean_record])
      write_parent_transcript([
        cancel_record(
          "aaa111", timestamp: "2026-08-14T21:05:00.000Z"),
        cancel_record(
          "aaa111", timestamp: "2026-08-14T22:00:00.000Z"),
      ])

      GalaxyAgents::AgentOutcome
        .cancellation("aaa111").not_nil!.died_at
        .should eq("2026-08-14 21:05:00")
    end
  end
end
