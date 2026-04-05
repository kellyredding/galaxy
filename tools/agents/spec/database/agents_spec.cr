require "../spec_helper"

describe GalaxyAgents::Database do
  before_each do
    db_path = GalaxyAgents::Database.database_path
    File.delete(db_path) if File.exists?(db_path)
  end

  describe ".start_agent" do
    it "inserts a new running agent" do
      result = GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore", "Find files",
      )
      result.should_not be_nil

      agent = GalaxyAgents::Database.get_agent(
        1_i64, "abc123",
      )
      agent.should_not be_nil
      a = agent.not_nil!
      a.agent_id.should eq("abc123")
      a.agent_type.should eq("Explore")
      a.status.should eq("running")
      a.description.should eq("Find files")
    end

    it "upserts duplicate agent_id and returns id" do
      r1 = GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore", "First desc",
      )
      r1.should_not be_nil

      r2 = GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore", "Updated desc",
      )
      r2.should_not be_nil
      r2.should eq(r1)
    end

    it "updates description on duplicate start" do
      GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore", "First desc",
      )
      GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore", "Updated desc",
      )

      agent = GalaxyAgents::Database.get_agent(
        1_i64, "abc123",
      )
      agent.not_nil!.description.should eq(
        "Updated desc",
      )
    end

    it "keeps status running on duplicate start" do
      GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore", "First desc",
      )
      GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore", "Updated desc",
      )

      agent = GalaxyAgents::Database.get_agent(
        1_i64, "abc123",
      )
      agent.not_nil!.status.should eq("running")
    end

    it "preserves other fields on duplicate start" do
      GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore", "First desc",
      )
      original = GalaxyAgents::Database.get_agent(
        1_i64, "abc123",
      ).not_nil!

      GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore", "Updated desc",
      )
      updated = GalaxyAgents::Database.get_agent(
        1_i64, "abc123",
      ).not_nil!

      updated.agent_type.should eq(
        original.agent_type,
      )
      updated.started_at.should eq(
        original.started_at,
      )
    end

    it "returns nil for invalid session" do
      result = GalaxyAgents::Database.start_agent(
        0_i64, "abc123", "Explore",
      )
      result.should be_nil
    end

    it "allows same agent_id in different sessions" do
      r1 = GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore",
      )
      r2 = GalaxyAgents::Database.start_agent(
        2_i64, "abc123", "Explore",
      )
      r1.should_not be_nil
      r2.should_not be_nil
    end
  end

  describe ".stop_agent" do
    it "updates a running agent to stopped" do
      GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore",
      )

      result = GalaxyAgents::Database.stop_agent(
        1_i64, "abc123",
        status: "stopped",
        prompt: "Search for files",
        last_message: "Found 15 files",
        transcript_path: "/tmp/transcript.jsonl",
        duration_ms: 12_450_i64,
      )
      result.should be_true

      agent = GalaxyAgents::Database.get_agent(
        1_i64, "abc123",
      )
      agent.should_not be_nil
      a = agent.not_nil!
      a.status.should eq("stopped")
      a.prompt.should eq("Search for files")
      a.last_message.should eq("Found 15 files")
      a.transcript_path.should eq(
        "/tmp/transcript.jsonl",
      )
      a.duration_ms.should eq(12_450_i64)
      a.completed_at.should_not be_nil
    end

    it "updates a running agent to failed" do
      GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore",
      )

      result = GalaxyAgents::Database.stop_agent(
        1_i64, "abc123",
        status: "failed",
        duration_ms: 3_200_i64,
      )
      result.should be_true

      agent = GalaxyAgents::Database.get_agent(
        1_i64, "abc123",
      )
      agent.should_not be_nil
      agent.not_nil!.status.should eq("failed")
    end

    it "returns false if agent not found" do
      result = GalaxyAgents::Database.stop_agent(
        1_i64, "nonexistent",
        status: "stopped",
      )
      result.should be_false
    end

    it "returns true on already-stopped agent" do
      GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore",
      )
      GalaxyAgents::Database.stop_agent(
        1_i64, "abc123",
        status: "stopped",
        last_message: "First msg",
      )

      result = GalaxyAgents::Database.stop_agent(
        1_i64, "abc123", status: "stopped")
      result.should be_true
    end

    it "updates non-blank fields on stopped agent" do
      GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore",
      )
      GalaxyAgents::Database.stop_agent(
        1_i64, "abc123",
        status: "stopped",
        last_message: "First msg",
      )

      GalaxyAgents::Database.stop_agent(
        1_i64, "abc123",
        status: "stopped",
        prompt: "New prompt",
        last_message: "Second msg",
      )

      a = GalaxyAgents::Database.get_agent(
        1_i64, "abc123",
      ).not_nil!
      a.prompt.should eq("New prompt")
      a.last_message.should eq("Second msg")
    end

    it "does not blank existing values on stop" do
      GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore",
      )
      GalaxyAgents::Database.stop_agent(
        1_i64, "abc123",
        status: "stopped",
        prompt: "Original prompt",
        last_message: "Original msg",
        transcript_path: "/tmp/t.jsonl",
      )

      # Second stop with blank fields
      GalaxyAgents::Database.stop_agent(
        1_i64, "abc123",
        status: "stopped",
        prompt: nil,
        last_message: nil,
        transcript_path: nil,
      )

      a = GalaxyAgents::Database.get_agent(
        1_i64, "abc123",
      ).not_nil!
      a.prompt.should eq("Original prompt")
      a.last_message.should eq("Original msg")
      a.transcript_path.should eq("/tmp/t.jsonl")
    end

    it "does not change status on idempotent stop" do
      GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore",
      )
      GalaxyAgents::Database.stop_agent(
        1_i64, "abc123", status: "stopped")

      GalaxyAgents::Database.stop_agent(
        1_i64, "abc123", status: "failed")

      a = GalaxyAgents::Database.get_agent(
        1_i64, "abc123",
      ).not_nil!
      a.status.should eq("stopped")
    end

    it "returns true on already-failed agent" do
      GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore",
      )
      GalaxyAgents::Database.stop_agent(
        1_i64, "abc123", status: "failed")

      result = GalaxyAgents::Database.stop_agent(
        1_i64, "abc123",
        status: "stopped",
        prompt: "New prompt",
      )
      result.should be_true

      a = GalaxyAgents::Database.get_agent(
        1_i64, "abc123",
      ).not_nil!
      a.status.should eq("failed")
      a.prompt.should eq("New prompt")
    end

    it "returns true on already-abandoned agent" do
      GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore",
      )
      GalaxyAgents::Database.abandon_running(1_i64)

      result = GalaxyAgents::Database.stop_agent(
        1_i64, "abc123",
        status: "stopped",
        last_message: "Late msg",
      )
      result.should be_true

      a = GalaxyAgents::Database.get_agent(
        1_i64, "abc123",
      ).not_nil!
      a.status.should eq("abandoned")
      a.last_message.should eq("Late msg")
    end

    it "returns false on non-existent agent" do
      result = GalaxyAgents::Database.stop_agent(
        1_i64, "nonexistent",
        status: "stopped",
      )
      result.should be_false
    end
  end

  describe ".abandon_running" do
    it "marks all running agents as abandoned" do
      GalaxyAgents::Database.start_agent(
        1_i64, "a1", "Explore",
      )
      GalaxyAgents::Database.start_agent(
        1_i64, "a2", "general-purpose",
      )
      # Stop one so it shouldn't be abandoned
      GalaxyAgents::Database.stop_agent(
        1_i64, "a2", status: "stopped")
      GalaxyAgents::Database.start_agent(
        1_i64, "a3", "Explore",
      )

      abandoned = GalaxyAgents::Database.abandon_running(
        1_i64,
      )
      abandoned.size.should eq(2)

      ids = abandoned.map(&.agent_id).sort
      ids.should eq(["a1", "a3"])

      # Verify in DB
      a1 = GalaxyAgents::Database.get_agent(
        1_i64, "a1",
      )
      a1.not_nil!.status.should eq("abandoned")

      a2 = GalaxyAgents::Database.get_agent(
        1_i64, "a2",
      )
      a2.not_nil!.status.should eq("stopped")

      a3 = GalaxyAgents::Database.get_agent(
        1_i64, "a3",
      )
      a3.not_nil!.status.should eq("abandoned")
    end

    it "returns empty array when no running agents" do
      abandoned = GalaxyAgents::Database.abandon_running(
        1_i64,
      )
      abandoned.should be_empty
    end

    it "returns empty for invalid session" do
      abandoned = GalaxyAgents::Database.abandon_running(
        0_i64,
      )
      abandoned.should be_empty
    end
  end

  describe ".list_agents" do
    it "returns agents ordered by started_at" do
      GalaxyAgents::Database.start_agent(
        1_i64, "a1", "Explore", "First",
      )
      GalaxyAgents::Database.start_agent(
        1_i64, "a2", "general-purpose", "Second",
      )

      agents = GalaxyAgents::Database.list_agents(1_i64)
      agents.size.should eq(2)
      agents[0].agent_id.should eq("a1")
      agents[1].agent_id.should eq("a2")
    end

    it "respects limit" do
      3.times do |i|
        GalaxyAgents::Database.start_agent(
          1_i64, "a#{i}", "Explore",
        )
      end

      agents = GalaxyAgents::Database.list_agents(
        1_i64, limit: 2)
      agents.size.should eq(2)
    end

    it "returns all agents when no limit given" do
      60.times do |i|
        GalaxyAgents::Database.start_agent(
          1_i64, "a#{i}", "Explore",
        )
      end

      agents = GalaxyAgents::Database.list_agents(
        1_i64,
      )
      agents.size.should eq(60)
    end

    it "returns empty for no agents" do
      agents = GalaxyAgents::Database.list_agents(
        999_i64,
      )
      agents.should be_empty
    end

    it "returns empty for invalid session" do
      agents = GalaxyAgents::Database.list_agents(
        0_i64,
      )
      agents.should be_empty
    end
  end

  describe ".get_agent" do
    it "retrieves an agent by session and agent_id" do
      GalaxyAgents::Database.start_agent(
        1_i64, "abc123", "Explore", "Find files",
      )

      agent = GalaxyAgents::Database.get_agent(
        1_i64, "abc123",
      )
      agent.should_not be_nil
      a = agent.not_nil!
      a.agent_type.should eq("Explore")
      a.description.should eq("Find files")
    end

    it "returns nil when not found" do
      agent = GalaxyAgents::Database.get_agent(
        1_i64, "nonexistent",
      )
      agent.should be_nil
    end

    it "returns nil for invalid session" do
      agent = GalaxyAgents::Database.get_agent(
        0_i64, "abc123",
      )
      agent.should be_nil
    end
  end

  describe ".agent_count" do
    it "returns count of agents for a session" do
      GalaxyAgents::Database.start_agent(
        1_i64, "a1", "Explore",
      )
      GalaxyAgents::Database.start_agent(
        1_i64, "a2", "Explore",
      )

      count = GalaxyAgents::Database.agent_count(1_i64)
      count.should eq(2)
    end

    it "returns 0 for empty session" do
      count = GalaxyAgents::Database.agent_count(
        999_i64,
      )
      count.should eq(0)
    end
  end

  describe ".running_count" do
    it "returns count of running agents" do
      GalaxyAgents::Database.start_agent(
        1_i64, "a1", "Explore",
      )
      GalaxyAgents::Database.start_agent(
        1_i64, "a2", "Explore",
      )
      GalaxyAgents::Database.stop_agent(
        1_i64, "a2", status: "stopped")

      count = GalaxyAgents::Database.running_count(
        1_i64,
      )
      count.should eq(1)
    end

    it "returns 0 when no running agents" do
      count = GalaxyAgents::Database.running_count(
        999_i64,
      )
      count.should eq(0)
    end
  end

  describe ".status_counts" do
    it "returns counts grouped by status" do
      GalaxyAgents::Database.start_agent(
        1_i64, "a1", "Explore",
      )
      GalaxyAgents::Database.start_agent(
        1_i64, "a2", "Explore",
      )
      GalaxyAgents::Database.stop_agent(
        1_i64, "a2", status: "stopped")
      GalaxyAgents::Database.start_agent(
        1_i64, "a3", "Explore",
      )
      GalaxyAgents::Database.stop_agent(
        1_i64, "a3", status: "failed")

      counts = GalaxyAgents::Database.status_counts(
        1_i64,
      )
      counts["running"].should eq(1)
      counts["stopped"].should eq(1)
      counts["failed"].should eq(1)
      counts["abandoned"].should eq(0)
    end
  end
end
