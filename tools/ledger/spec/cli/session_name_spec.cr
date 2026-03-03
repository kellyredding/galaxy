require "../spec_helper"

describe GalaxyLedger::CLI do
  describe ".find_custom_title" do
    it "returns nil for empty path list" do
      GalaxyLedger::CLI.find_custom_title([] of Path).should be_nil
    end

    it "returns nil when no JSONL files exist on disk" do
      missing = Path.new(Dir.tempdir) / "nonexistent-#{Random.rand(100000)}.jsonl"
      GalaxyLedger::CLI.find_custom_title([missing]).should be_nil
    end

    it "returns the custom title from a single JSONL" do
      temp_file = File.tempfile("session-name-test", ".jsonl")
      temp_file.print(%({"type":"user","text":"hello"}\n))
      temp_file.print(%({"type":"custom-title","customTitle":"my-session"}\n))
      temp_file.close

      result = GalaxyLedger::CLI.find_custom_title([Path.new(temp_file.path)])
      result.should eq("my-session")

      File.delete(temp_file.path)
    end

    it "returns the last custom title when renamed multiple times" do
      temp_file = File.tempfile("session-name-test", ".jsonl")
      temp_file.print(%({"type":"custom-title","customTitle":"first-name"}\n))
      temp_file.print(%({"type":"custom-title","customTitle":"second-name"}\n))
      temp_file.close

      result = GalaxyLedger::CLI.find_custom_title([Path.new(temp_file.path)])
      result.should eq("second-name")

      File.delete(temp_file.path)
    end

    it "returns nil when JSONL has no custom-title entries" do
      temp_file = File.tempfile("session-name-test", ".jsonl")
      temp_file.print(%({"type":"user","text":"hello"}\n))
      temp_file.print(%({"type":"assistant","text":"hi"}\n))
      temp_file.close

      result = GalaxyLedger::CLI.find_custom_title([Path.new(temp_file.path)])
      result.should be_nil

      File.delete(temp_file.path)
    end

    it "skips malformed JSON lines gracefully" do
      temp_file = File.tempfile("session-name-test", ".jsonl")
      temp_file.print(%(not valid json "custom-title"\n))
      temp_file.print(%({"type":"custom-title","customTitle":"good-name"}\n))
      temp_file.close

      result = GalaxyLedger::CLI.find_custom_title([Path.new(temp_file.path)])
      result.should eq("good-name")

      File.delete(temp_file.path)
    end

    it "scans across multiple JSONL files in order" do
      temp_file1 = File.tempfile("session-name-test-1", ".jsonl")
      temp_file1.print(%({"type":"custom-title","customTitle":"from-first-file"}\n))
      temp_file1.close

      temp_file2 = File.tempfile("session-name-test-2", ".jsonl")
      temp_file2.print(%({"type":"custom-title","customTitle":"from-second-file"}\n))
      temp_file2.close

      result = GalaxyLedger::CLI.find_custom_title([
        Path.new(temp_file1.path),
        Path.new(temp_file2.path),
      ])
      result.should eq("from-second-file")

      File.delete(temp_file1.path)
      File.delete(temp_file2.path)
    end

    it "skips missing files and reads existing ones" do
      missing = Path.new(Dir.tempdir) / "nonexistent-#{Random.rand(100000)}.jsonl"

      temp_file = File.tempfile("session-name-test", ".jsonl")
      temp_file.print(%({"type":"custom-title","customTitle":"found-it"}\n))
      temp_file.close

      result = GalaxyLedger::CLI.find_custom_title([
        missing,
        Path.new(temp_file.path),
      ])
      result.should eq("found-it")

      File.delete(temp_file.path)
    end
  end
end
