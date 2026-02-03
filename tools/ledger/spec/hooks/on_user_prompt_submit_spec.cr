require "../spec_helper"

describe GalaxyLedger::Hooks::OnUserPromptSubmit do
  describe "#run" do
    it "buffers user prompts as direction entries" do
      session_id = "user-prompt-test-#{rand(100000)}"
      session_dir = GalaxyLedger::SESSIONS_DIR / session_id
      Dir.mkdir_p(session_dir)

      input = {
        "session_id"      => session_id,
        "prompt"          => "Always use trailing commas in multiline structures",
        "hook_event_name" => "UserPromptSubmit",
      }.to_json

      result = run_binary(["on-user-prompt-submit"], stdin: input)
      result[:status].should eq(0)

      entries = GalaxyLedger::Buffer.read(session_id)
      entries.size.should eq(1)
      entries.first.entry_type.should eq("direction")
      entries.first.content.should eq("Always use trailing commas in multiline structures")
      entries.first.source.should eq("user")
      entries.first.importance.should eq("medium")
    end

    it "skips empty prompts" do
      session_id = "user-prompt-test-#{rand(100000)}"
      session_dir = GalaxyLedger::SESSIONS_DIR / session_id
      Dir.mkdir_p(session_dir)

      input = {
        "session_id"      => session_id,
        "prompt"          => "",
        "hook_event_name" => "UserPromptSubmit",
      }.to_json

      result = run_binary(["on-user-prompt-submit"], stdin: input)
      result[:status].should eq(0)

      entries = GalaxyLedger::Buffer.read(session_id)
      entries.size.should eq(0)
    end

    it "skips whitespace-only prompts" do
      session_id = "user-prompt-test-#{rand(100000)}"
      session_dir = GalaxyLedger::SESSIONS_DIR / session_id
      Dir.mkdir_p(session_dir)

      input = {
        "session_id"      => session_id,
        "prompt"          => "   \n\t  ",
        "hook_event_name" => "UserPromptSubmit",
      }.to_json

      result = run_binary(["on-user-prompt-submit"], stdin: input)
      result[:status].should eq(0)

      entries = GalaxyLedger::Buffer.read(session_id)
      entries.size.should eq(0)
    end

    it "skips very short prompts (less than 10 chars)" do
      session_id = "user-prompt-test-#{rand(100000)}"
      session_dir = GalaxyLedger::SESSIONS_DIR / session_id
      Dir.mkdir_p(session_dir)

      short_prompts = ["yes", "ok", "continue", "go ahead", "sure"]
      short_prompts.each do |prompt|
        input = {
          "session_id"      => session_id,
          "prompt"          => prompt,
          "hook_event_name" => "UserPromptSubmit",
        }.to_json

        result = run_binary(["on-user-prompt-submit"], stdin: input)
        result[:status].should eq(0)
      end

      entries = GalaxyLedger::Buffer.read(session_id)
      entries.size.should eq(0)
    end

    it "accepts prompts with exactly 10 characters" do
      session_id = "user-prompt-test-#{rand(100000)}"
      session_dir = GalaxyLedger::SESSIONS_DIR / session_id
      Dir.mkdir_p(session_dir)

      input = {
        "session_id"      => session_id,
        "prompt"          => "1234567890",  # Exactly 10 chars
        "hook_event_name" => "UserPromptSubmit",
      }.to_json

      result = run_binary(["on-user-prompt-submit"], stdin: input)
      result[:status].should eq(0)

      entries = GalaxyLedger::Buffer.read(session_id)
      entries.size.should eq(1)
    end

    it "creates session folder if it doesn't exist" do
      session_id = "user-prompt-test-#{rand(100000)}"
      session_dir = GalaxyLedger::SESSIONS_DIR / session_id

      # Don't create session dir
      Dir.exists?(session_dir).should be_false

      input = {
        "session_id"      => session_id,
        "prompt"          => "Please always use descriptive variable names",
        "hook_event_name" => "UserPromptSubmit",
      }.to_json

      result = run_binary(["on-user-prompt-submit"], stdin: input)
      result[:status].should eq(0)

      # Session dir should now exist
      Dir.exists?(session_dir).should be_true

      entries = GalaxyLedger::Buffer.read(session_id)
      entries.size.should eq(1)
    end

    describe "with missing or invalid input" do
      it "handles empty input gracefully" do
        result = run_binary(["on-user-prompt-submit"], stdin: "")
        result[:status].should eq(0)
      end

      it "handles invalid JSON gracefully" do
        result = run_binary(["on-user-prompt-submit"], stdin: "not json")
        result[:status].should eq(0)
      end

      it "handles missing session_id gracefully" do
        input = {
          "prompt" => "Some user message",
        }.to_json

        result = run_binary(["on-user-prompt-submit"], stdin: input)
        result[:status].should eq(0)
      end

      it "handles missing prompt gracefully" do
        session_id = "user-prompt-test-#{rand(100000)}"

        input = {
          "session_id" => session_id,
        }.to_json

        result = run_binary(["on-user-prompt-submit"], stdin: input)
        result[:status].should eq(0)
      end
    end
  end

  describe "CLI help" do
    it "shows help with -h flag" do
      result = run_binary(["on-user-prompt-submit", "-h"])
      result[:status].should eq(0)

      result[:output].should contain("on-user-prompt-submit")
      result[:output].should contain("UserPromptSubmit")
      result[:output].should contain("USAGE")
      result[:output].should contain("prompt")
      result[:output].should contain("BEHAVIOR")
    end

    it "shows help with --help flag" do
      result = run_binary(["on-user-prompt-submit", "--help"])
      result[:status].should eq(0)
      result[:output].should contain("on-user-prompt-submit")
    end
  end
end
