require "../spec_helper"

# Verifies that session lifecycle hooks publish events
# through the correct channel:
#
# - timeline.* events (session:started, session:resumed,
#   context:cleared, context:compacted) flow exclusively
#   through the timeline pipeline. They MUST NOT appear as
#   direct socket events.
# - session:ready is the one direct-socket event the
#   SessionStart hooks emit. It signals to Galaxy.app that
#   the on_resume / on_startup hook has completed and the
#   prompt is imminent. ref disambiguates resume vs startup.
#
# Uses a logging timeline stub that records invocations
# to a temp file, and a UNIXServer on the socket path
# to capture any direct publishes.

# Build a timeline stub script that logs its args to a
# file. Returns {stub_path, log_path}.
private def build_timeline_logging_stub : {Path, Path}
  log_path = SPEC_GALAXY_DIR / "timeline_invocations.log"
  stub_path = SPEC_GALAXY_DIR / "bin" / "galaxy-timeline"

  File.write(stub_path, <<-BASH)
  #!/bin/bash
  echo "$@" >> "#{log_path}"
  # Echo a valid JSON response for --json calls
  if echo "$@" | grep -q '\\-\\-json'; then
    echo '{"id": 1}'
  fi
  exit 0
  BASH
  File.chmod(stub_path, 0o755)

  {stub_path, log_path}
end

# Read timeline invocation log lines. Each line is the
# full argument string from one galaxy-timeline call.
private def read_timeline_log(
  log_path : Path,
) : Array(String)
  return [] of String unless File.exists?(log_path)
  File.read_lines(log_path).reject(&.empty?)
end

# Start a socket server and collect any events received
# within the timeout window. Returns the collected event
# strings. The block should run the hook under test.
private def capture_socket_events(
  socket_path : Path,
  &
) : Array(String)
  events = [] of String
  server = UNIXServer.new(socket_path.to_s)

  # Accept connections in the background until we close
  # the server.
  spawn do
    loop do
      begin
        client = server.accept
        if line = client.gets
          events << line
        end
        client.close
      rescue IO::Error
        break
      end
    end
  end

  yield

  # Give any fire-and-forget publishes time to arrive
  sleep 300.milliseconds

  server.close rescue nil
  File.delete(socket_path.to_s) if File.exists?(socket_path.to_s)
  events
end

describe "Event pipeline: hooks use timeline, not direct socket" do
  describe "on-startup" do
    it "records session:started via timeline" do
      _, log_path = build_timeline_logging_stub
      File.delete(log_path) if File.exists?(log_path)

      session_id = "evpipe-startup-#{Random.rand(100000)}"
      hook_input = {"session_id" => session_id}.to_json

      result = run_binary(["on-startup"], stdin: hook_input)
      result[:status].should eq(0)

      # Give fire-and-forget Process.new time to execute
      sleep 200.milliseconds

      lines = read_timeline_log(log_path)
      matching = lines.select(&.includes?("session:started"))
      matching.size.should be >= 1
      matching.first.should contain("--event-type")
      matching.first.should contain("--source")
    ensure
      File.delete(log_path) if log_path && File.exists?(log_path)
    end

    it "does not publish session.startup directly to the socket" do
      session_id = "evpipe-startup-nosock-#{Random.rand(100000)}"
      hook_input = {"session_id" => session_id}.to_json
      socket_path = SPEC_GALAXY_DIR / "galaxy.sock"

      events = capture_socket_events(socket_path) do
        result = run_binary(["on-startup"], stdin: hook_input)
        result[:status].should eq(0)
        sleep 200.milliseconds
      end

      direct_startup = events.select do |e|
        begin
          parsed = JSON.parse(e)
          parsed["event"].as_s == "session.startup"
        rescue
          false
        end
      end
      direct_startup.should be_empty
    ensure
      path = SPEC_GALAXY_DIR / "galaxy.sock"
      File.delete(path) if File.exists?(path)
    end

    it "publishes session:ready with ref=startup to direct socket" do
      session_id = "evpipe-startup-ready-#{Random.rand(100000)}"
      hook_input = {"session_id" => session_id}.to_json
      socket_path = SPEC_GALAXY_DIR / "galaxy.sock"

      events = capture_socket_events(socket_path) do
        result = run_binary(["on-startup"], stdin: hook_input)
        result[:status].should eq(0)
        sleep 200.milliseconds
      end

      ready_events = events.compact_map do |e|
        begin
          parsed = JSON.parse(e)
          parsed["event"].as_s == "session:ready" ? parsed : nil
        rescue
          nil
        end
      end
      ready_events.size.should eq(1)
      ready_events.first["ref"].as_s.should eq("startup")
      ready_events.first["ledger_session_id"].as_i64.should be > 0
    ensure
      path = SPEC_GALAXY_DIR / "galaxy.sock"
      File.delete(path) if File.exists?(path)
    end
  end

  describe "on-resume" do
    it "records session:resumed via timeline" do
      _, log_path = build_timeline_logging_stub
      File.delete(log_path) if File.exists?(log_path)

      session_id = "evpipe-resume-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(session_id)
      flush_wal

      hook_input = {"session_id" => session_id}.to_json

      result = run_binary(["on-resume"], stdin: hook_input)
      result[:status].should eq(0)

      sleep 200.milliseconds

      lines = read_timeline_log(log_path)
      matching = lines.select(&.includes?("session:resumed"))
      matching.size.should be >= 1
      matching.first.should contain("--event-type")
      matching.first.should contain("--source")
    ensure
      File.delete(log_path) if log_path && File.exists?(log_path)
    end

    it "does not publish session.resume directly to the socket" do
      session_id = "evpipe-resume-nosock-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(session_id)
      flush_wal

      hook_input = {"session_id" => session_id}.to_json
      socket_path = SPEC_GALAXY_DIR / "galaxy.sock"

      events = capture_socket_events(socket_path) do
        result = run_binary(["on-resume"], stdin: hook_input)
        result[:status].should eq(0)
        sleep 200.milliseconds
      end

      direct_resume = events.select do |e|
        begin
          parsed = JSON.parse(e)
          parsed["event"].as_s == "session.resume"
        rescue
          false
        end
      end
      direct_resume.should be_empty
    ensure
      path = SPEC_GALAXY_DIR / "galaxy.sock"
      File.delete(path) if File.exists?(path)
    end

    it "publishes session:ready with ref=resume to direct socket" do
      session_id = "evpipe-resume-ready-#{Random.rand(100000)}"
      ledger_id = GalaxyLedger::Database.create_session(session_id)
      flush_wal

      hook_input = {"session_id" => session_id}.to_json
      socket_path = SPEC_GALAXY_DIR / "galaxy.sock"

      events = capture_socket_events(socket_path) do
        result = run_binary(["on-resume"], stdin: hook_input)
        result[:status].should eq(0)
        sleep 200.milliseconds
      end

      ready_events = events.compact_map do |e|
        begin
          parsed = JSON.parse(e)
          parsed["event"].as_s == "session:ready" ? parsed : nil
        rescue
          nil
        end
      end
      ready_events.size.should eq(1)
      ready_events.first["ref"].as_s.should eq("resume")
      ready_events.first["ledger_session_id"]
        .as_i64.should eq(ledger_id)
    ensure
      path = SPEC_GALAXY_DIR / "galaxy.sock"
      File.delete(path) if File.exists?(path)
    end

    it "does not publish session:ready when session cannot be resolved" do
      # No DB record for this identifier. on_resume's
      # resolve_for_resume returns nil → output_empty → no
      # EventPublisher.publish call.
      session_id = "evpipe-resume-noresolve-#{Random.rand(100000)}"
      hook_input = {"session_id" => session_id}.to_json
      socket_path = SPEC_GALAXY_DIR / "galaxy.sock"

      events = capture_socket_events(socket_path) do
        result = run_binary(["on-resume"], stdin: hook_input)
        result[:status].should eq(0)
        sleep 200.milliseconds
      end

      ready_events = events.select do |e|
        begin
          parsed = JSON.parse(e)
          parsed["event"].as_s == "session:ready"
        rescue
          false
        end
      end
      ready_events.should be_empty
    ensure
      path = SPEC_GALAXY_DIR / "galaxy.sock"
      File.delete(path) if File.exists?(path)
    end
  end

  describe "on-clear" do
    it "records context:cleared via timeline" do
      _, log_path = build_timeline_logging_stub
      File.delete(log_path) if File.exists?(log_path)

      session_id = "evpipe-clear-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(
        session_id, claude_pid: Process.pid.to_i64)
      flush_wal

      hook_input = {
        "session_id" => session_id,
        "source"     => "clear",
      }.to_json

      result = run_binary(["on-clear"], stdin: hook_input)
      result[:status].should eq(0)

      sleep 200.milliseconds

      lines = read_timeline_log(log_path)
      matching = lines.select(&.includes?("context:cleared"))
      matching.size.should be >= 1
      matching.first.should contain("--event-type")
    ensure
      File.delete(log_path) if log_path && File.exists?(log_path)
    end

    it "does not publish session.clear directly to the socket" do
      session_id = "evpipe-clear-nosock-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(
        session_id, claude_pid: Process.pid.to_i64)
      flush_wal

      hook_input = {
        "session_id" => session_id,
        "source"     => "clear",
      }.to_json
      socket_path = SPEC_GALAXY_DIR / "galaxy.sock"

      events = capture_socket_events(socket_path) do
        result = run_binary(["on-clear"], stdin: hook_input)
        result[:status].should eq(0)
        sleep 200.milliseconds
      end

      direct_clear = events.select do |e|
        begin
          parsed = JSON.parse(e)
          parsed["event"].as_s == "session.clear"
        rescue
          false
        end
      end
      direct_clear.should be_empty
    ensure
      path = SPEC_GALAXY_DIR / "galaxy.sock"
      File.delete(path) if File.exists?(path)
    end
  end

  describe "on-compact" do
    it "records context:compacted via timeline" do
      _, log_path = build_timeline_logging_stub
      File.delete(log_path) if File.exists?(log_path)

      session_id = "evpipe-compact-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(
        session_id, claude_pid: Process.pid.to_i64)
      flush_wal

      hook_input = {
        "session_id" => session_id,
        "source"     => "compact",
      }.to_json

      result = run_binary(["on-compact"], stdin: hook_input)
      result[:status].should eq(0)

      sleep 200.milliseconds

      lines = read_timeline_log(log_path)
      matching = lines.select(&.includes?("context:compacted"))
      matching.size.should be >= 1
      matching.first.should contain("--event-type")
    ensure
      File.delete(log_path) if log_path && File.exists?(log_path)
    end

    it "does not publish session.compact directly to the socket" do
      session_id = "evpipe-compact-nosock-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(
        session_id, claude_pid: Process.pid.to_i64)
      flush_wal

      hook_input = {
        "session_id" => session_id,
        "source"     => "compact",
      }.to_json
      socket_path = SPEC_GALAXY_DIR / "galaxy.sock"

      events = capture_socket_events(socket_path) do
        result = run_binary(["on-compact"], stdin: hook_input)
        result[:status].should eq(0)
        sleep 200.milliseconds
      end

      direct_compact = events.select do |e|
        begin
          parsed = JSON.parse(e)
          parsed["event"].as_s == "session.compact"
        rescue
          false
        end
      end
      direct_compact.should be_empty
    ensure
      path = SPEC_GALAXY_DIR / "galaxy.sock"
      File.delete(path) if File.exists?(path)
    end
  end
end
