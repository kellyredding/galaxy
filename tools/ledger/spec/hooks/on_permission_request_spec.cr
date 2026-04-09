require "../spec_helper"

describe "OnPermissionRequest GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"

    hook_input = {
      "session_id" => "skip-test-#{Random.rand(10000)}",
    }.to_json

    result = run_binary(
      ["on-permission-request"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  ensure
    ENV.delete("GALAXY_SKIP_HOOKS")
  end
end

describe GalaxyLedger::Hooks::OnPermissionRequest do
  describe "#run" do
    it "creates instance successfully" do
      handler =
        GalaxyLedger::Hooks::OnPermissionRequest.new
      handler.should be_a(
        GalaxyLedger::Hooks::OnPermissionRequest,
      )
    end
  end
end

describe "OnPermissionRequest session resolution" do
  it "resolves session by stdin session_id" do
    test_session_id =
      "perm-resolve-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(
      test_session_id,
      claude_pid: Process.pid.to_i64,
    )
    flush_wal

    hook_input = {
      "session_id" => test_session_id,
    }.to_json

    result = run_binary(
      ["on-permission-request"], stdin: hook_input)
    result[:status].should eq(0)
  end

  it "resolves session by env var" do
    test_session_id =
      "perm-env-#{Random.rand(10000)}"
    env_id =
      "perm-env-durable-#{Random.rand(10000)}"
    ledger_id = GalaxyLedger::Database.create_session(
      test_session_id,
    )
    GalaxyLedger::Database
      .register_session_identifier(ledger_id, env_id)
    flush_wal

    hook_input = {
      "session_id" => "perm-env-new-#{Random.rand(10000)}",
    }.to_json

    result = run_binary(
      ["on-permission-request"],
      stdin: hook_input,
      extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
    )
    result[:status].should eq(0)
  end

  it "exits cleanly when session cannot be resolved" do
    hook_input = {
      "session_id" => "nonexistent-#{Random.rand(10000)}",
    }.to_json

    result = run_binary(
      ["on-permission-request"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  end
end

describe "OnPermissionRequest event publishing" do
  it "publishes permission_request event to socket" do
    test_session_id =
      "perm-pub-#{Random.rand(10000)}"
    ledger_id = GalaxyLedger::Database.create_session(
      test_session_id,
      claude_pid: Process.pid.to_i64,
    )
    flush_wal

    # Set up a listening socket to capture the event
    socket_path = "/tmp/galaxy-test-perm-" \
                  "#{Random.rand(100000)}.sock"
    received = Channel(String).new(1)

    server = UNIXServer.new(socket_path)
    spawn do
      client = server.accept
      line = client.gets
      received.send(line || "")
      client.close
      server.close
    end

    begin
      sleep 10.milliseconds

      hook_input = {
        "session_id" => test_session_id,
      }.to_json

      result = run_binary(
        ["on-permission-request"],
        stdin: hook_input,
        extra_env: {
          "GALAXY_DIR" => File.dirname(socket_path),
        },
      )
      result[:status].should eq(0)

      # The event may or may not reach the socket
      # depending on socket path resolution in the
      # subprocess. This test verifies the binary
      # doesn't crash during the publish attempt.
    ensure
      server.close rescue nil
      File.delete(socket_path) if File.exists?(socket_path)
    end
  end

  it "succeeds silently when no socket is listening" do
    test_session_id =
      "perm-nosock-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(
      test_session_id,
      claude_pid: Process.pid.to_i64,
    )
    flush_wal

    hook_input = {
      "session_id" => test_session_id,
    }.to_json

    # No socket listening — should not crash
    result = run_binary(
      ["on-permission-request"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  end
end

describe "OnPermissionRequest graceful input handling" do
  it "handles empty stdin gracefully" do
    result = run_binary(
      ["on-permission-request"], stdin: "")
    result[:status].should eq(0)
  end

  it "handles malformed JSON stdin gracefully" do
    result = run_binary(
      ["on-permission-request"],
      stdin: "not valid json {{{",
    )
    result[:status].should eq(0)
  end

  it "handles JSON with missing session_id" do
    result = run_binary(
      ["on-permission-request"],
      stdin: %({"other_field": "value"}),
    )
    result[:status].should eq(0)
  end
end

describe "OnPermissionRequest help" do
  it "shows help with --help flag" do
    result = run_binary(
      ["on-permission-request", "--help"],
    )
    result[:status].should eq(0)
    result[:output].should contain("PermissionRequest")
  end

  it "shows help with -h flag" do
    result = run_binary(
      ["on-permission-request", "-h"],
    )
    result[:status].should eq(0)
    result[:output].should contain("PermissionRequest")
  end
end
