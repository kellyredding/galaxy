require "../spec_helper"
require "json"

describe "CLI (galaxy-diff)", tags: "integration" do
  it "prints help when run with no args" do
    result = run_binary([] of String)
    result[:status].should eq(0)
    result[:output].should contain("galaxy-diff")
    result[:output].should contain("capture")
  end

  it "prints help with --help" do
    result = run_binary(["--help"])
    result[:status].should eq(0)
    result[:output].should contain("USAGE")
  end

  it "prints version with version subcommand" do
    result = run_binary(["version"])
    result[:status].should eq(0)
    result[:output].should contain(
      "galaxy-diff #{GalaxyDiff::VERSION}",
    )
  end

  it "prints version with --version" do
    result = run_binary(["--version"])
    result[:status].should eq(0)
    result[:output].should contain(
      "galaxy-diff #{GalaxyDiff::VERSION}",
    )
  end

  it "shows capture help with capture --help" do
    result = run_binary(["capture", "--help"])
    result[:status].should eq(0)
    result[:output].should contain("capture")
    result[:output].should contain("--from")
    result[:output].should contain("--to")
  end

  it "errors on unknown top-level command" do
    result = run_binary(["bogus"])
    result[:status].should_not eq(0)
    result[:error].should contain("Unknown command 'bogus'")
  end

  it "errors on unknown capture flag" do
    result = run_binary(["capture", "--bogus"])
    result[:status].should_not eq(0)
    result[:error].should contain("Unknown option '--bogus'")
  end

  it "captures a working-tree diff as valid JSON" do
    with_temp_repo do |repo|
      File.write(File.join(repo, "f.rb"), "v1\n")
      git_commit(repo, "init")
      File.write(File.join(repo, "f.rb"), "v2\n")

      result = run_binary(["capture"], chdir: repo)
      result[:status].should eq(0)

      # Must be a single JSON object on stdout.
      doc = GalaxyDiff::GdiffDocument.from_json(
        result[:output],
      )
      doc.version.should eq(1)
      doc.metadata.ref_from.should eq("HEAD")
      doc.metadata.ref_to.should eq("working-tree")
      doc.files.size.should eq(1)
      doc.files[0].path.should eq("f.rb")
      doc.files[0].before.should eq("v1\n")
      doc.files[0].after.should eq("v2\n")
    end
  end

  it "captures via --repo flag without requiring chdir" do
    with_temp_repo do |repo|
      File.write(File.join(repo, "x.rb"), "one\n")
      git_commit(repo, "init")
      File.write(File.join(repo, "x.rb"), "two\n")

      result = run_binary(["capture", "--repo", repo])
      result[:status].should eq(0)

      doc = GalaxyDiff::GdiffDocument.from_json(
        result[:output],
      )
      doc.files.size.should eq(1)
      doc.files[0].path.should eq("x.rb")
    end
  end

  it "handles a bad ref gracefully without crashing" do
    with_temp_repo do |repo|
      File.write(File.join(repo, "f.rb"), "v1\n")
      git_commit(repo, "init")

      result = run_binary(
        ["capture", "--from", "NONEXISTENT_REF"],
        chdir: repo,
      )
      # git writes its error to stderr; we still emit
      # valid (empty-files) JSON to stdout and exit 0.
      result[:status].should eq(0)
      doc = GalaxyDiff::GdiffDocument.from_json(
        result[:output],
      )
      doc.files.should be_empty
    end
  end
end
