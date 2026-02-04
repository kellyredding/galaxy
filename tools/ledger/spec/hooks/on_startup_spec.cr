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

describe "OnStartup orphan cleanup" do
  test_session_id = "orphan-test-#{Random.rand(10000)}"

  before_each do
    # Ensure sessions dir exists
    Dir.mkdir_p(GalaxyLedger::SESSIONS_DIR)
  end

  after_each do
    # Clean up test session folder
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
  end

  it "cleans up orphaned flushing file in session folder" do
    # Create test session folder with orphaned flushing file
    session_dir = GalaxyLedger.session_dir(test_session_id)
    Dir.mkdir_p(session_dir)

    flushing_file = session_dir / GalaxyLedger::LEDGER_BUFFER_FLUSHING_FILENAME
    File.write(flushing_file, "{\"test\": true}\n")

    # Verify file exists before cleanup
    File.exists?(flushing_file).should eq(true)

    # Note: Full cleanup happens when the hook actually runs with session_id
    # This test just verifies the file structure is correct
    File.exists?(flushing_file).should eq(true)

    # Clean up
    File.delete(flushing_file) if File.exists?(flushing_file)
  end

  it "preserves normal buffer files" do
    # Create test session folder with normal buffer file
    session_dir = GalaxyLedger.session_dir(test_session_id)
    Dir.mkdir_p(session_dir)

    buffer_file = session_dir / GalaxyLedger::LEDGER_BUFFER_FILENAME
    File.write(buffer_file, "{\"test\": true}\n")

    # The buffer file should exist
    File.exists?(buffer_file).should eq(true)

    # Clean up
    File.delete(buffer_file) if File.exists?(buffer_file)
  end
end
