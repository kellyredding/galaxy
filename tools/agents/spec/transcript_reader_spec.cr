require "./spec_helper"

describe GalaxyAgents::TranscriptReader do
  describe ".extract_prompt" do
    it "extracts from nested message.content string" do
      tmp = Path.new(Dir.tempdir) /
            "galaxy-agents-transcript-#{
  Random.rand(100000)
}"
      Dir.mkdir_p(tmp)
      path = (tmp / "transcript.jsonl").to_s

      File.write(path, %({"type":"user","message":{"role":"user","content":"Search for timeline files"}}\n{"type":"assistant","message":{"role":"assistant","content":"Found 10 files"}}\n))

      result = GalaxyAgents::TranscriptReader
        .extract_prompt(path)
      result.should eq("Search for timeline files")

      FileUtils.rm_rf(tmp.to_s)
    end

    it "extracts from content array of blocks" do
      tmp = Path.new(Dir.tempdir) /
            "galaxy-agents-transcript-blocks-#{
  Random.rand(100000)
}"
      Dir.mkdir_p(tmp)
      path = (tmp / "transcript.jsonl").to_s

      content = [
        {"type" => "text", "text" => "Find all files"},
      ]
      entry = {
        "type"    => "user",
        "message" => {
          "role"    => "user",
          "content" => content,
        },
      }
      File.write(path, entry.to_json + "\n")

      result = GalaxyAgents::TranscriptReader
        .extract_prompt(path)
      result.should eq("Find all files")

      FileUtils.rm_rf(tmp.to_s)
    end

    it "returns nil for empty file" do
      tmp = Path.new(Dir.tempdir) /
            "galaxy-agents-transcript-empty-#{
  Random.rand(100000)
}"
      Dir.mkdir_p(tmp)
      path = (tmp / "empty.jsonl").to_s
      File.write(path, "")

      result = GalaxyAgents::TranscriptReader
        .extract_prompt(path)
      result.should be_nil

      FileUtils.rm_rf(tmp.to_s)
    end

    it "returns nil for missing file" do
      result = GalaxyAgents::TranscriptReader
        .extract_prompt(
          "/tmp/nonexistent-#{Random.rand(100000)}.jsonl",
        )
      result.should be_nil
    end

    it "returns nil for malformed JSON" do
      tmp = Path.new(Dir.tempdir) /
            "galaxy-agents-transcript-bad-#{
  Random.rand(100000)
}"
      Dir.mkdir_p(tmp)
      path = (tmp / "bad.jsonl").to_s
      File.write(path, "not json\n")

      result = GalaxyAgents::TranscriptReader
        .extract_prompt(path)
      result.should be_nil

      FileUtils.rm_rf(tmp.to_s)
    end

    it "returns nil for flat structure (no message)" do
      tmp = Path.new(Dir.tempdir) /
            "galaxy-agents-transcript-flat-#{
  Random.rand(100000)
}"
      Dir.mkdir_p(tmp)
      path = (tmp / "flat.jsonl").to_s

      File.write(path, %({"type":"user","role":"user","content":"flat prompt"}\n))

      result = GalaxyAgents::TranscriptReader
        .extract_prompt(path)
      result.should be_nil

      FileUtils.rm_rf(tmp.to_s)
    end
  end
end
