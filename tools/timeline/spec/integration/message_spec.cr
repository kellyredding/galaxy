require "../spec_helper"

# Records an event with the given detail and returns its id.
private def record_with_detail(detail : String?) : Int64
  args = [
    "record",
    "--ledger-session-id", "4242",
    "--event-type", "scrollback:reviewed",
    "--source", "spec",
    "--json",
  ]
  if detail
    args << "--detail-data-stdin"
  end
  result = run_binary(args, stdin: detail)
  result[:status].should eq(0)
  JSON.parse(result[:output])["id"].as_i64
end

describe "CLI message command", tags: "integration" do
  it "prints the stored message verbatim" do
    message = "Summary first.\n\n\n[1]\n> quoted \"line\" — ✓\nmy note"
    id = record_with_detail({message: message, note_count: 1}.to_json)

    result = run_binary(["message", id.to_s])

    result[:status].should eq(0)
    result[:output].should eq(message + "\n")
    result[:error].should be_empty
  end

  it "ends with exactly one newline" do
    id = record_with_detail({message: "ends with newlines\n\n"}.to_json)

    result = run_binary(["message", id.to_s])

    result[:status].should eq(0)
    result[:output].should eq("ends with newlines\n")
  end

  it "prints a message too large for a command argument" do
    message = (1..2000).map { |n| "line #{n} of a long review" }.join("\n")
    id = record_with_detail({message: message}.to_json)

    result = run_binary(["message", id.to_s])

    result[:status].should eq(0)
    result[:output].should eq(message + "\n")
  end

  it "errors on an event that does not exist" do
    result = run_binary(["message", "999999"])

    result[:status].should_not eq(0)
    result[:output].should be_empty
    result[:error].should contain("event #999999 not found")
  end

  it "errors on an event with no detail" do
    id = record_with_detail(nil)

    result = run_binary(["message", id.to_s])

    result[:status].should_not eq(0)
    result[:output].should be_empty
    result[:error].should contain("has no message")
  end

  it "errors on detail without a message" do
    id = record_with_detail({note_count: 3}.to_json)

    result = run_binary(["message", id.to_s])

    result[:status].should_not eq(0)
    result[:error].should contain("has no message")
    result[:error].should contain("scrollback:reviewed")
  end

  it "errors on a message that is not a string" do
    id = record_with_detail(%({"message":{"text":"nested"}}))

    result = run_binary(["message", id.to_s])

    result[:status].should_not eq(0)
    result[:error].should contain("has no message")
  end

  it "errors without an event id" do
    result = run_binary(["message"])

    result[:status].should_not eq(0)
    result[:error].should contain("event ID is required")
  end

  it "errors on an unknown option" do
    result = run_binary(["message", "--json"])

    result[:status].should_not eq(0)
    result[:error].should contain("Unknown option '--json'")
  end

  it "describes itself with --help" do
    result = run_binary(["message", "--help"])

    result[:status].should eq(0)
    result[:output].should contain("galaxy-timeline message ID")
    result[:output].should contain("plain text")
  end
end
