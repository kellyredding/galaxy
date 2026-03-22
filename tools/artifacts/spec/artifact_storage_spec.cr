require "./spec_helper"

describe GalaxyArtifacts::ArtifactStorage do
  describe ".file_hash" do
    it "returns SHA256 hex digest of file content" do
      path = create_test_file("hash-test.txt", "hello world")
      hash = GalaxyArtifacts::ArtifactStorage.file_hash(path)
      hash.should_not be_empty
      hash.size.should eq(64) # SHA256 hex is 64 chars
    end

    it "returns empty string for nonexistent file" do
      hash = GalaxyArtifacts::ArtifactStorage.file_hash("/tmp/nonexistent-#{Random.rand(100000)}")
      hash.should eq("")
    end
  end

  describe ".content_hash" do
    it "returns SHA256 hex digest of string content" do
      hash = GalaxyArtifacts::ArtifactStorage.content_hash("hello world")
      hash.should_not be_empty
      hash.size.should eq(64)
    end

    it "returns consistent hashes for same content" do
      h1 = GalaxyArtifacts::ArtifactStorage.content_hash("test")
      h2 = GalaxyArtifacts::ArtifactStorage.content_hash("test")
      h1.should eq(h2)
    end
  end

  describe ".file_size" do
    it "returns file size in bytes" do
      path = create_test_file("size-test.txt", "12345")
      size = GalaxyArtifacts::ArtifactStorage.file_size(path)
      size.should eq(5)
    end

    it "returns 0 for nonexistent file" do
      size = GalaxyArtifacts::ArtifactStorage.file_size("/tmp/nonexistent-#{Random.rand(100000)}")
      size.should eq(0)
    end
  end

  describe ".title_from_filename" do
    it "converts filename to title" do
      GalaxyArtifacts::ArtifactStorage.title_from_filename("quarterly-report.csv").should eq("quarterly report")
    end

    it "strips leading number prefix" do
      GalaxyArtifacts::ArtifactStorage.title_from_filename("001_data-export.json").should eq("data export")
    end

    it "converts underscores to spaces" do
      GalaxyArtifacts::ArtifactStorage.title_from_filename("my_report.pdf").should eq("my report")
    end
  end

  describe ".slugify" do
    it "produces safe filenames" do
      GalaxyArtifacts::ArtifactStorage.slugify("My Report (2024).csv").should eq("my-report-2024.csv")
    end

    it "lowercases extension" do
      GalaxyArtifacts::ArtifactStorage.slugify("Data.CSV").should eq("data.csv")
    end

    it "handles simple filenames" do
      GalaxyArtifacts::ArtifactStorage.slugify("test.txt").should eq("test.txt")
    end
  end

  describe ".store" do
    it "copies file to artifact storage" do
      source = create_test_file("store-test.csv", "name,value\nfoo,42")

      stored = GalaxyArtifacts::ArtifactStorage.store(1_i64, 1, source, "store-test.csv")
      stored.should_not be_nil
      File.exists?(stored.not_nil!).should be_true
      File.read(stored.not_nil!).should eq("name,value\nfoo,42")
    end

    it "returns nil for nonexistent source" do
      stored = GalaxyArtifacts::ArtifactStorage.store(1_i64, 1, "/tmp/nonexistent-#{Random.rand(100000)}", "fake.txt")
      stored.should be_nil
    end
  end

  describe ".store_content" do
    it "writes content to artifact storage" do
      stored = GalaxyArtifacts::ArtifactStorage.store_content(1_i64, 1, "hello world", "content.txt")
      stored.should_not be_nil
      File.exists?(stored.not_nil!).should be_true
      File.read(stored.not_nil!).should eq("hello world")
    end
  end
end
