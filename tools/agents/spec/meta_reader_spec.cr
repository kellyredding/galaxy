require "./spec_helper"

describe GalaxyAgents::MetaReader do
  describe ".derive_meta_path" do
    it "derives path from parent transcript" do
      result = GalaxyAgents::MetaReader.derive_meta_path(
        "/tmp/sessions/transcript.jsonl",
        "abc123",
      )
      result.should eq(
        "/tmp/sessions/transcript" \
        "/subagents/agent-abc123.meta.json",
      )
    end

    it "returns nil for non-jsonl path" do
      result = GalaxyAgents::MetaReader.derive_meta_path(
        "/tmp/sessions/transcript.json",
        "abc123",
      )
      result.should be_nil
    end

    it "returns nil for empty path" do
      result = GalaxyAgents::MetaReader.derive_meta_path(
        "",
        "abc123",
      )
      result.should be_nil
    end
  end

  describe ".read_description" do
    it "reads description from valid .meta.json" do
      tmp = Path.new(Dir.tempdir) /
            "galaxy-agents-meta-#{Random.rand(100000)}"
      # derive_meta_path strips .jsonl, so
      # transcript.jsonl -> transcript/subagents/
      Dir.mkdir_p(
        tmp / "transcript" / "subagents",
      )
      File.write(
        tmp / "transcript.jsonl", "{}\n",
      )
      File.write(
        tmp / "transcript" / "subagents" /
        "agent-abc123.meta.json",
        %({"agentType":"Explore","description":"Find timeline refs"}),
      )

      result = GalaxyAgents::MetaReader.read_description(
        (tmp / "transcript.jsonl").to_s,
        "abc123",
      )
      result.should eq("Find timeline refs")

      FileUtils.rm_rf(tmp.to_s)
    end

    it "returns nil for missing file" do
      result = GalaxyAgents::MetaReader.read_description(
        "/tmp/nonexistent/transcript.jsonl",
        "abc123",
        attempts: 1,
      )
      result.should be_nil
    end

    it "retries until the sidecar is written" do
      tmp = Path.new(Dir.tempdir) /
            "galaxy-agents-meta-race-#{
  Random.rand(100000)
}"
      Dir.mkdir_p(
        tmp / "transcript" / "subagents",
      )
      File.write(
        tmp / "transcript.jsonl", "{}\n",
      )
      meta = tmp / "transcript" / "subagents" /
             "agent-abc123.meta.json"

      # Land the sidecar after the first look has already
      # missed it, the way Claude Code writes it just after
      # SubagentStart fires.
      spawn do
        sleep(30.milliseconds)
        File.write(
          meta,
          %({"description":"Late arrival"}),
        )
      end

      result = GalaxyAgents::MetaReader.read_description(
        (tmp / "transcript.jsonl").to_s,
        "abc123",
      )
      result.should eq("Late arrival")

      FileUtils.rm_rf(tmp.to_s)
    end

    it "gives up once the retry budget is spent" do
      result = GalaxyAgents::MetaReader.read_description(
        "/tmp/nonexistent/transcript.jsonl",
        "abc123",
        attempts: 3,
        delay: 1.millisecond,
      )
      result.should be_nil
    end

    it "returns nil for malformed JSON" do
      tmp = Path.new(Dir.tempdir) /
            "galaxy-agents-meta-bad-#{Random.rand(100000)}"
      Dir.mkdir_p(
        tmp / "transcript" / "subagents",
      )
      File.write(
        tmp / "transcript.jsonl", "{}\n",
      )
      File.write(
        tmp / "transcript" / "subagents" /
        "agent-abc123.meta.json",
        "not json",
      )

      result = GalaxyAgents::MetaReader.read_description(
        (tmp / "transcript.jsonl").to_s,
        "abc123",
        attempts: 1,
      )
      result.should be_nil

      FileUtils.rm_rf(tmp.to_s)
    end

    it "returns nil when description key missing" do
      tmp = Path.new(Dir.tempdir) /
            "galaxy-agents-meta-nokey-#{
  Random.rand(100000)
}"
      Dir.mkdir_p(
        tmp / "transcript" / "subagents",
      )
      File.write(
        tmp / "transcript.jsonl", "{}\n",
      )
      File.write(
        tmp / "transcript" / "subagents" /
        "agent-abc123.meta.json",
        %({"agentType":"Explore"}),
      )

      result = GalaxyAgents::MetaReader.read_description(
        (tmp / "transcript.jsonl").to_s,
        "abc123",
        attempts: 1,
      )
      result.should be_nil

      FileUtils.rm_rf(tmp.to_s)
    end
  end
end
