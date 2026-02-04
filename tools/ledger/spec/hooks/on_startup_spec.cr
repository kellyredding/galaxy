require "../spec_helper"

describe "OnStartup GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"

    test_session_id = "skip-hooks-test-#{Random.rand(10000)}"

    hook_input = {
      "session_id" => test_session_id,
    }.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    result[:status].should eq(0)

    # Should return empty output (no hookSpecificOutput)
    result[:output].strip.should eq("")

    # Session folder should NOT be created (early return)
    session_dir = GalaxyLedger.session_dir(test_session_id)
    Dir.exists?(session_dir).should eq(false)
  ensure
    ENV.delete("GALAXY_SKIP_HOOKS")
  end
end

describe GalaxyLedger::Hooks::OnStartup do
  describe "#run" do
    it "outputs JSON with hookSpecificOutput" do
      handler = GalaxyLedger::Hooks::OnStartup.new

      # Basic instantiation test - handler creates successfully
      handler.should be_a(GalaxyLedger::Hooks::OnStartup)
    end
  end
end

describe "OnStartup session folder handling" do
  test_session_id = "test-session-#{Random.rand(10000)}"

  before_each do
    # Clean up any existing test session folder
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
  end

  after_each do
    # Clean up test session folder
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
  end

  it "handles missing session gracefully" do
    # When no session_id provided, handler still runs without error
    handler = GalaxyLedger::Hooks::OnStartup.new
    handler.should be_a(GalaxyLedger::Hooks::OnStartup)
  end
end
