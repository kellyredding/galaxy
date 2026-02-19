require "./spec_helper"

describe GalaxyLedger::ArtifactStorage do
  describe ".slugify" do
    it "lowercases and preserves extension" do
      GalaxyLedger::ArtifactStorage.slugify("Report.CSV").should eq("report.csv")
    end

    it "replaces spaces with hyphens" do
      GalaxyLedger::ArtifactStorage.slugify("my report.md").should eq("my-report.md")
    end

    it "replaces unsafe chars with hyphens" do
      GalaxyLedger::ArtifactStorage.slugify("data (copy).csv").should eq("data-copy.csv")
    end

    it "collapses multiple hyphens" do
      GalaxyLedger::ArtifactStorage.slugify("data---export.csv").should eq("data-export.csv")
    end

    it "handles simple filenames" do
      GalaxyLedger::ArtifactStorage.slugify("report.pdf").should eq("report.pdf")
    end

    it "strips leading/trailing hyphens from base" do
      GalaxyLedger::ArtifactStorage.slugify("-report-.pdf").should eq("report.pdf")
    end
  end

  describe ".title_from_filename" do
    it "strips extension and converts hyphens to spaces" do
      GalaxyLedger::ArtifactStorage.title_from_filename("quarterly-report.csv").should eq("quarterly report")
    end

    it "strips leading number prefix" do
      GalaxyLedger::ArtifactStorage.title_from_filename("001_data-export.json").should eq("data export")
    end

    it "converts underscores to spaces" do
      GalaxyLedger::ArtifactStorage.title_from_filename("user_data_export.csv").should eq("user data export")
    end

    it "handles simple names" do
      GalaxyLedger::ArtifactStorage.title_from_filename("report.pdf").should eq("report")
    end
  end

  describe ".content_hash" do
    it "returns consistent SHA256 hash" do
      hash1 = GalaxyLedger::ArtifactStorage.content_hash("hello world")
      hash2 = GalaxyLedger::ArtifactStorage.content_hash("hello world")
      hash1.should eq(hash2)
      hash1.size.should eq(64) # SHA256 hex string length
    end

    it "returns different hashes for different content" do
      hash1 = GalaxyLedger::ArtifactStorage.content_hash("hello")
      hash2 = GalaxyLedger::ArtifactStorage.content_hash("world")
      hash1.should_not eq(hash2)
    end
  end

  describe ".store_content" do
    it "writes content to artifact storage directory" do
      session_id = 99999_i64
      content = "id,name,value\n1,foo,100\n2,bar,200"

      stored_path = GalaxyLedger::ArtifactStorage.store_content(
        session_id, 1, content, "export.csv",
      )

      stored_path.should_not be_nil
      sp = stored_path.not_nil!
      File.exists?(sp).should be_true
      File.read(sp).should eq(content)
      File.basename(sp).should eq("001_export.csv")

      # Cleanup
      File.delete(sp) if File.exists?(sp)
      session_dir = Path.new(sp).parent
      Dir.delete(session_dir) if Dir.exists?(session_dir) && Dir.empty?(session_dir)
    end

    it "creates numbered filename" do
      session_id = 99998_i64
      stored_path = GalaxyLedger::ArtifactStorage.store_content(
        session_id, 12, "data", "report.md",
      )

      stored_path.should_not be_nil
      File.basename(stored_path.not_nil!).should eq("012_report.md")

      # Cleanup
      sp = stored_path.not_nil!
      File.delete(sp) if File.exists?(sp)
      session_dir = Path.new(sp).parent
      Dir.delete(session_dir) if Dir.exists?(session_dir) && Dir.empty?(session_dir)
    end
  end

  describe ".store" do
    it "copies source file to artifact storage" do
      # Create a temp source file
      source_path = File.tempname("artifact-test", ".csv")
      File.write(source_path, "a,b,c\n1,2,3")

      session_id = 99997_i64
      stored_path = GalaxyLedger::ArtifactStorage.store(
        session_id, 1, source_path, "data.csv",
      )

      stored_path.should_not be_nil
      sp = stored_path.not_nil!
      File.exists?(sp).should be_true
      File.read(sp).should eq("a,b,c\n1,2,3")

      # Original still exists
      File.exists?(source_path).should be_true

      # Cleanup
      File.delete(source_path)
      File.delete(sp) if File.exists?(sp)
      session_dir = Path.new(sp).parent
      Dir.delete(session_dir) if Dir.exists?(session_dir) && Dir.empty?(session_dir)
    end

    it "returns nil for non-existent source" do
      stored_path = GalaxyLedger::ArtifactStorage.store(
        99996_i64, 1, "/nonexistent/file.csv", "file.csv",
      )
      stored_path.should be_nil
    end
  end

  describe ".file_size" do
    it "returns correct file size" do
      path = File.tempname("size-test", ".txt")
      File.write(path, "hello world") # 11 bytes

      GalaxyLedger::ArtifactStorage.file_size(path).should eq(11_i64)

      File.delete(path)
    end

    it "returns 0 for non-existent file" do
      GalaxyLedger::ArtifactStorage.file_size("/nonexistent/file.txt").should eq(0_i64)
    end
  end

  describe ".file_hash" do
    it "returns SHA256 hash of file content" do
      path = File.tempname("hash-test", ".txt")
      File.write(path, "hello world")

      hash = GalaxyLedger::ArtifactStorage.file_hash(path)
      hash.should eq(GalaxyLedger::ArtifactStorage.content_hash("hello world"))
      hash.size.should eq(64)

      File.delete(path)
    end

    it "returns empty string for non-existent file" do
      GalaxyLedger::ArtifactStorage.file_hash("/nonexistent/file.txt").should eq("")
    end
  end
end
