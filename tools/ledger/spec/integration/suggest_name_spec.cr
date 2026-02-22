require "../spec_helper"

describe "CLI Integration: suggest-name" do
  describe "help" do
    it "shows help with --help flag" do
      result = run_binary(["suggest-name", "--help"])
      result[:output].should contain("galaxy-ledger suggest-name")
      result[:output].should contain("--session")
      result[:output].should contain("--transcript-path")
      result[:status].should eq(0)
    end

    it "shows help with -h flag" do
      result = run_binary(["suggest-name", "-h"])
      result[:output].should contain("galaxy-ledger suggest-name")
      result[:status].should eq(0)
    end
  end

  describe "flag validation" do
    it "errors when --session is missing" do
      result = run_binary(["suggest-name", "--transcript-path", "/tmp/transcript.jsonl"])
      result[:error].should contain("--session is required")
      result[:status].should_not eq(0)
    end

    it "errors when --transcript-path is missing" do
      result = run_binary(["suggest-name", "--session", "test-session"])
      result[:error].should contain("--transcript-path is required")
      result[:status].should_not eq(0)
    end
  end

  describe "short-circuit behavior" do
    it "skips when name is already finalized" do
      session_id = "suggest-name-finalized-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      # Pre-set finalized state
      finalized_data = %({"attempts":1,"quality":4,"finalized":true,"status":"finalized_quality_met","exchange_count":3,"last_attempt_at":"2026-02-01T10:00:00Z"})
      GalaxyLedger::Database.update_suggested_name_with_data(ledger_session_id, "Already Named", finalized_data)

      config_json = {
        "extraction"     => {"on_stop" => false, "on_guideline_read" => false},
        "suggested_name" => {"enabled" => true},
      }.to_json
      File.write(SPEC_CONFIG_DIR / "config.json", config_json)

      transcript_file = File.tempfile("suggest-name-final", ".jsonl")
      transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "More work"}}\n|)
      transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Done."}}\n|)
      transcript_file.close

      result = run_binary([
        "suggest-name",
        "--session", session_id,
        "--transcript-path", transcript_file.path,
      ])
      result[:status].should eq(0)
      result[:error].should contain("Name suggestion complete")

      # Verify name was NOT changed
      session = GalaxyLedger::Database.get_session(session_id)
      session.not_nil!.suggested_name.should eq("Already Named")

      File.delete(transcript_file.path) if File.exists?(transcript_file.path)
    end

    it "silently skips when suggested_name is disabled in config" do
      session_id = "suggest-name-disabled-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(session_id)

      config_json = {
        "extraction"     => {"on_stop" => false, "on_guideline_read" => false},
        "suggested_name" => {"enabled" => false},
      }.to_json
      File.write(SPEC_CONFIG_DIR / "config.json", config_json)

      transcript_file = File.tempfile("suggest-name-disabled", ".jsonl")
      transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Question"}}\n|)
      transcript_file.close

      result = run_binary([
        "suggest-name",
        "--session", session_id,
        "--transcript-path", transcript_file.path,
      ])
      result[:status].should eq(0)

      session = GalaxyLedger::Database.get_session(session_id)
      session.not_nil!.suggested_name.should be_nil

      File.delete(transcript_file.path) if File.exists?(transcript_file.path)
    end

    it "errors when session identifier is unknown" do
      config_json = {
        "extraction"     => {"on_stop" => false, "on_guideline_read" => false},
        "suggested_name" => {"enabled" => true},
      }.to_json
      File.write(SPEC_CONFIG_DIR / "config.json", config_json)

      transcript_file = File.tempfile("suggest-name-unknown", ".jsonl")
      transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Question"}}\n|)
      transcript_file.close

      result = run_binary([
        "suggest-name",
        "--session", "nonexistent-id-#{Random.rand(100000)}",
        "--transcript-path", transcript_file.path,
      ])
      result[:error].should contain("no session found")
      result[:status].should_not eq(0)

      File.delete(transcript_file.path) if File.exists?(transcript_file.path)
    end

    it "does not publish event when name is already finalized" do
      session_id = "suggest-name-no-event-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      # Pre-set finalized state
      finalized_data = %({"attempts":1,"quality":4,"finalized":true,"status":"finalized_quality_met","exchange_count":3,"last_attempt_at":"2026-02-01T10:00:00Z"})
      GalaxyLedger::Database.update_suggested_name_with_data(ledger_session_id, "Already Named", finalized_data)

      config = GalaxyLedger::Config.new
      config.extraction.on_stop = false
      config.extraction.on_guideline_read = false
      config.suggested_name.enabled = true
      File.write(SPEC_CONFIG_DIR / "config.json", config.to_pretty_json)

      # Start a socket listener to detect any events
      socket_path = SPEC_GALAXY_DIR / "galaxy.sock"
      received = Channel(String?).new(1)

      server = UNIXServer.new(socket_path.to_s)
      spawn do
        begin
          client = server.accept
          line = client.gets
          received.send(line)
          client.close
        rescue Socket::Error
          # Server closed before accept — expected in timeout path
        end
      end

      begin
        sleep 10.milliseconds

        transcript_file = File.tempfile("suggest-name-event", ".jsonl")
        transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "More work"}}\n|)
        transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Done."}}\n|)
        transcript_file.close

        result = run_binary([
          "suggest-name",
          "--session", session_id,
          "--transcript-path", transcript_file.path,
        ])
        result[:status].should eq(0)
        result[:error].should contain("Name suggestion complete")

        # No event should arrive — command short-circuited before any publish
        select
        when line = received.receive
          fail "Expected no event but received: #{line}"
        when timeout(500.milliseconds)
          # Expected: no event published
        end

        File.delete(transcript_file.path) if File.exists?(transcript_file.path)
      ensure
        server.close rescue nil
        File.delete(socket_path.to_s) if File.exists?(socket_path.to_s)
      end
    end

    it "skips gracefully when transcript file does not exist" do
      session_id = "suggest-name-no-transcript-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(session_id)

      config_json = {
        "extraction"     => {"on_stop" => false, "on_guideline_read" => false},
        "suggested_name" => {"enabled" => true},
      }.to_json
      File.write(SPEC_CONFIG_DIR / "config.json", config_json)

      result = run_binary([
        "suggest-name",
        "--session", session_id,
        "--transcript-path", "/tmp/nonexistent-transcript-#{Random.rand(100000)}.jsonl",
      ])
      result[:status].should eq(0)

      session = GalaxyLedger::Database.get_session(session_id)
      session.not_nil!.suggested_name.should be_nil
    end
  end
end
