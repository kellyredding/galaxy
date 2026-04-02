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
      )
      result.should be_nil

      FileUtils.rm_rf(tmp.to_s)
    end
  end
end
