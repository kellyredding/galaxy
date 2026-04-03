require "../spec_helper"

describe "CLI help and version", tags: "integration" do
  it "shows help with no arguments" do
    result = run_binary([] of String)

    result[:status].should eq(0)
    result[:output].should contain("galaxy-timeline")
    result[:output].should contain("COMMANDS")
    result[:output].should contain("record")
    result[:output].should contain("list")
    result[:output].should contain("show")
    result[:output].should contain("update")
    result[:output].should contain("delete")
    result[:output].should contain("stats")
    result[:output].should contain("backup")
  end

  it "shows help with --help" do
    result = run_binary(["--help"])

    result[:status].should eq(0)
    result[:output].should contain("galaxy-timeline")
  end

  it "shows help with help command" do
    result = run_binary(["help"])

    result[:status].should eq(0)
    result[:output].should contain("galaxy-timeline")
  end

  it "shows version with version command" do
    result = run_binary(["version"])

    result[:status].should eq(0)
    result[:output].should contain("galaxy-timeline 0.1.2")
  end

  it "shows version with --version" do
    result = run_binary(["--version"])

    result[:status].should eq(0)
    result[:output].should contain("galaxy-timeline 0.1.2")
  end

  it "shows version with -v" do
    result = run_binary(["-v"])

    result[:status].should eq(0)
    result[:output].should contain("galaxy-timeline 0.1.2")
  end

  it "shows subcommand help with --help flag" do
    ["record", "list", "show", "update", "delete", "stats", "backup"].each do |cmd|
      result = run_binary([cmd, "--help"])

      result[:status].should eq(0)
      result[:output].should contain(cmd)
    end
  end

  it "errors on unknown command" do
    result = run_binary(["nonexistent"])

    result[:status].should_not eq(0)
    result[:error].should contain("Unknown command")
  end

  it "record help mentions --json flag" do
    result = run_binary(["record", "--help"])

    result[:status].should eq(0)
    result[:output].should contain("--json")
  end

  it "record help mentions --duration-identifier flag" do
    result = run_binary(["record", "--help"])

    result[:status].should eq(0)
    result[:output].should contain("--duration-identifier")
    result[:output].should contain("duration events")
  end

  it "update help mentions --detail-data-stdin flag" do
    result = run_binary(["update", "--help"])

    result[:status].should eq(0)
    result[:output].should contain("--detail-data-stdin")
  end

  it "list help mentions --limit flag" do
    result = run_binary(["list", "--help"])

    result[:status].should eq(0)
    result[:output].should contain("--limit")
  end

  it "list help mentions --reverse flag" do
    result = run_binary(["list", "--help"])

    result[:status].should eq(0)
    result[:output].should contain("--reverse")
  end

  it "list help mentions comma-separated event types" do
    result = run_binary(["list", "--help"])

    result[:status].should eq(0)
    result[:output].should contain("comma-")
  end
end
