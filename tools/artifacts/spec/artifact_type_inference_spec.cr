require "./spec_helper"

# Unit tests for the save-time artifact_type inference
# helpers. Integration-level assertions (full CLI
# round-trip) live in cli_save_stdin_spec.cr and
# cli_save_source_spec.cr.

describe "GalaxyArtifacts::CLI" do
  describe ".artifact_type_from_extension" do
    it "maps markdown extensions to markdown" do
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "notes.md",
      ).should eq("markdown")
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "notes.markdown",
      ).should eq("markdown")
    end

    it "maps html extensions to html" do
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "page.html",
      ).should eq("html")
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "page.htm",
      ).should eq("html")
    end

    it "maps csv and tsv to table" do
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "data.csv",
      ).should eq("table")
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "data.tsv",
      ).should eq("table")
    end

    it "maps mermaid extensions to mermaid" do
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "diagram.mmd",
      ).should eq("mermaid")
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "diagram.mermaid",
      ).should eq("mermaid")
    end

    it "maps jsonl and json to json" do
      # Transcript promotion happens in
      # default_artifact_type via content sniff —
      # pure extension lookup returns json for both.
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "transcript.jsonl",
      ).should eq("json")
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "settings.json",
      ).should eq("json")
    end

    it "maps yaml/yml/toml/ini/conf to config" do
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "ci.yaml",
      ).should eq("config")
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "ci.yml",
      ).should eq("config")
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "Cargo.toml",
      ).should eq("config")
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "app.ini",
      ).should eq("config")
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "nginx.conf",
      ).should eq("config")
    end

    it "maps gdiff to diff" do
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "changes.gdiff",
      ).should eq("diff")
    end

    it "maps image extensions to image" do
      ["png", "jpg", "jpeg",
       "gif", "svg", "webp"].each do |ext|
        GalaxyArtifacts::CLI.artifact_type_from_extension(
          "asset.#{ext}",
        ).should eq("image")
      end
    end

    it "maps pdf to pdf" do
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "doc.pdf",
      ).should eq("pdf")
    end

    it "maps txt to text" do
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "notes.txt",
      ).should eq("text")
    end

    it "defaults unknown extensions to code" do
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "src.rb",
      ).should eq("code")
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "main.swift",
      ).should eq("code")
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "impl.cr",
      ).should eq("code")
    end

    it "defaults empty or extensionless names to code" do
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "Makefile",
      ).should eq("code")
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "",
      ).should eq("code")
    end

    it "is case-insensitive" do
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "README.MD",
      ).should eq("markdown")
      GalaxyArtifacts::CLI.artifact_type_from_extension(
        "IMAGE.PNG",
      ).should eq("image")
    end
  end

  describe ".is_agent_transcript_file?" do
    tmp_dir = Path.new(Dir.tempdir) /
              "galaxy-artifacts-test-transcript"
    before_each do
      Dir.mkdir_p(tmp_dir) unless Dir.exists?(tmp_dir)
    end
    after_each do
      FileUtils.rm_rf(tmp_dir.to_s) \
        if Dir.exists?(tmp_dir)
    end

    it "returns true for a valid agent transcript first line" do
      path = (tmp_dir / "t.jsonl").to_s
      File.write(path,
        %({"agentId":"a1","message":{"role":"user",) +
        %("content":"hi"}}\n) +
        %({"agentId":"a1","message":{"role":"assistant",) +
        %("content":"hello"}}\n))
      GalaxyArtifacts::CLI.is_agent_transcript_file?(
        path,
      ).should be_true
    end

    it "returns false when agentId is missing" do
      path = (tmp_dir / "t.jsonl").to_s
      File.write(path,
        %({"message":{"role":"user",) +
        %("content":"hi"}}\n))
      GalaxyArtifacts::CLI.is_agent_transcript_file?(
        path,
      ).should be_false
    end

    it "returns false when message is missing" do
      path = (tmp_dir / "t.jsonl").to_s
      File.write(path,
        %({"agentId":"a1","content":"hi"}\n))
      GalaxyArtifacts::CLI.is_agent_transcript_file?(
        path,
      ).should be_false
    end

    it "returns false when message.role is missing" do
      path = (tmp_dir / "t.jsonl").to_s
      File.write(path,
        %({"agentId":"a1","message":{"content":"hi"}}\n))
      GalaxyArtifacts::CLI.is_agent_transcript_file?(
        path,
      ).should be_false
    end

    it "returns false when agentId is not a string" do
      path = (tmp_dir / "t.jsonl").to_s
      File.write(path,
        %({"agentId":42,"message":{"role":"user"}}\n))
      GalaxyArtifacts::CLI.is_agent_transcript_file?(
        path,
      ).should be_false
    end

    it "returns false on invalid JSON first line" do
      path = (tmp_dir / "t.jsonl").to_s
      File.write(path, "not json at all\n")
      GalaxyArtifacts::CLI.is_agent_transcript_file?(
        path,
      ).should be_false
    end

    it "returns false on empty file" do
      path = (tmp_dir / "t.jsonl").to_s
      File.write(path, "")
      GalaxyArtifacts::CLI.is_agent_transcript_file?(
        path,
      ).should be_false
    end

    it "returns false on missing file" do
      path = (tmp_dir / "does-not-exist.jsonl").to_s
      GalaxyArtifacts::CLI.is_agent_transcript_file?(
        path,
      ).should be_false
    end
  end

  describe ".default_artifact_type" do
    tmp_dir = Path.new(Dir.tempdir) /
              "galaxy-artifacts-test-default"
    before_each do
      Dir.mkdir_p(tmp_dir) unless Dir.exists?(tmp_dir)
    end
    after_each do
      FileUtils.rm_rf(tmp_dir.to_s) \
        if Dir.exists?(tmp_dir)
    end

    it "returns pure extension type when no sniff applies" do
      path = (tmp_dir / "x.md").to_s
      File.write(path, "# hello")
      GalaxyArtifacts::CLI.default_artifact_type(
        "x.md", path,
      ).should eq("markdown")
    end

    it "promotes .jsonl to transcript when content matches" do
      path = (tmp_dir / "x.jsonl").to_s
      File.write(path,
        %({"agentId":"a1","message":{"role":"user"}}\n))
      GalaxyArtifacts::CLI.default_artifact_type(
        "x.jsonl", path,
      ).should eq("transcript")
    end

    it "keeps .jsonl as json when sniff fails" do
      path = (tmp_dir / "x.jsonl").to_s
      File.write(path, %({"just":"json-lines"}\n))
      GalaxyArtifacts::CLI.default_artifact_type(
        "x.jsonl", path,
      ).should eq("json")
    end

    it "keeps .json as json even with agentId-shaped content" do
      # Same structural shape in a .json file should
      # stay json — transcript promotion is scoped
      # to .jsonl only.
      path = (tmp_dir / "x.json").to_s
      File.write(path,
        %({"agentId":"a1","message":{"role":"user"}}))
      GalaxyArtifacts::CLI.default_artifact_type(
        "x.json", path,
      ).should eq("json")
    end
  end
end
