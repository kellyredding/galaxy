require "../spec_helper"

# Build an artifacts stub script that logs its invocation
# args to a file, one call per line. Returns the log path.
# Mirrors the timeline logging-stub pattern in
# tools/ledger/spec/integration/event_pipeline_spec.cr so
# subprocess arg assertions stay consistent across specs.
private def build_artifacts_logging_stub : Path
  log_path = SPEC_GALAXY_DIR / "artifacts_invocations.log"
  stub_path = SPEC_GALAXY_DIR / "bin" / "galaxy-artifacts"

  File.write(stub_path, <<-BASH)
  #!/bin/bash
  echo "$@" >> "#{log_path}"
  exit 0
  BASH
  File.chmod(stub_path, 0o755)

  log_path
end

# Read each invocation of the artifacts stub as a separate
# line. Empty lines rejected for robustness.
private def read_artifacts_log(
  log_path : Path,
) : Array(String)
  return [] of String unless File.exists?(log_path)
  File.read_lines(log_path).reject(&.empty?)
end

# Restore the no-op artifacts stub installed by
# spec_helper.cr so later tests aren't affected.
private def restore_artifacts_noop
  File.write(
    SPEC_ARTIFACTS_NOOP, "#!/bin/sh\nexit 0\n",
  )
  File.chmod(SPEC_ARTIFACTS_NOOP, 0o755)
end

# Build a timeline stub that logs its invocation args to
# a file, one call per line. Returns the log path. Mirrors
# `build_artifacts_logging_stub` above; together they let
# specs assert which timeline / artifact subprocess calls
# the CLI made (or didn't make).
private def build_timeline_logging_stub : Path
  log_path = SPEC_GALAXY_DIR / "timeline_invocations.log"
  stub_path = SPEC_GALAXY_DIR / "bin" / "galaxy-timeline"

  File.write(stub_path, <<-BASH)
  #!/bin/bash
  echo "$@" >> "#{log_path}"
  exit 0
  BASH
  File.chmod(stub_path, 0o755)

  log_path
end

private def read_timeline_log(
  log_path : Path,
) : Array(String)
  return [] of String unless File.exists?(log_path)
  File.read_lines(log_path).reject(&.empty?)
end

# Wait until the stub log holds at least `count` lines, or
# the deadline passes. The CLI publishes through a detached
# process, so how long a record takes to land is not bounded
# by how long the CLI itself ran — a fixed sleep either
# flakes or reads the log before anything has been written.
private def wait_for_timeline_calls(
  log_path : Path,
  count : Int32,
  timeout : Time::Span = 5.seconds,
) : Array(String)
  deadline = Time.monotonic + timeout
  loop do
    calls = read_timeline_log(log_path)
    return calls if calls.size >= count
    break if Time.monotonic > deadline
    sleep 25.milliseconds
  end
  read_timeline_log(log_path)
end

# Count stub invocations for one agent and event type.
# Totals rather than a before/after window: the ordering of
# detached publishes is not guaranteed, so a positional
# snapshot can attribute an earlier record to a later call.
private def count_calls(
  calls : Array(String),
  agent_id : String,
  event_type : String,
) : Int32
  calls.count do |line|
    line.includes?("--event-type #{event_type}") &&
      line.includes?("agent--#{agent_id}")
  end
end

# Restore the no-op timeline stub installed by
# spec_helper.cr so later tests aren't affected.
private def restore_timeline_noop
  File.write(
    SPEC_TIMELINE_NOOP, "#!/bin/sh\nexit 0\n",
  )
  File.chmod(SPEC_TIMELINE_NOOP, 0o755)
end

describe "CLI agent commands", tags: "integration" do
  describe "start" do
    it "starts an agent" do
      result = run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "test123",
        "--agent-type", "Explore",
      ])

      result[:status].should eq(0)
      result[:output].should contain("Agent test123 started")
    end

    it "reads description from .meta.json" do
      # Create a fake parent transcript and meta file
      # derive_meta_path strips .jsonl, so
      # transcript.jsonl -> transcript/subagents/
      tmp = Path.new(Dir.tempdir) /
            "galaxy-agents-meta-#{Random.rand(100000)}"
      Dir.mkdir_p(
        tmp / "transcript" / "subagents",
      )
      File.write(
        tmp / "transcript.jsonl",
        "{}\n",
      )
      File.write(
        tmp / "transcript" / "subagents" /
        "agent-m1.meta.json",
        %({"agentType":"Explore","description":"Find timeline refs"}),
      )

      result = run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "m1",
        "--agent-type", "Explore",
        "--parent-transcript-path",
        (tmp / "transcript.jsonl").to_s,
      ])

      result[:status].should eq(0)
      result[:output].should contain("Agent m1 started")

      # Verify description stored
      show = run_binary([
        "show",
        "--ledger-session-id", "1",
        "--agent-id", "m1",
        "--json",
      ])
      show[:status].should eq(0)
      parsed = JSON.parse(show[:output])
      parsed["description"].as_s.should eq(
        "Find timeline refs",
      )

      FileUtils.rm_rf(tmp.to_s)
    end

    it "errors when agent-id missing" do
      result = run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-type", "Explore",
      ])

      result[:status].should_not eq(0)
      result[:error].should contain("--agent-id")
    end

    it "errors when agent-type missing" do
      result = run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "test123",
      ])

      result[:status].should_not eq(0)
      result[:error].should contain("--agent-type")
    end

    it "errors when session missing" do
      result = run_binary([
        "start",
        "--agent-id", "test123",
        "--agent-type", "Explore",
      ])

      result[:status].should_not eq(0)
      result[:error].should contain(
        "--ledger-session-id",
      )
    end

    it "succeeds on duplicate agent_id (idempotent)" do
      r1 = run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "dup1",
        "--agent-type", "Explore",
      ])
      r1[:status].should eq(0)

      r2 = run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "dup1",
        "--agent-type", "Explore",
      ])
      r2[:status].should eq(0)
    end

    it "updates description on duplicate start" do
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "dup2",
        "--agent-type", "Explore",
      ])

      # Create meta file for second start
      tmp = Path.new(Dir.tempdir) /
            "galaxy-agents-dup-#{Random.rand(100000)}"
      Dir.mkdir_p(tmp / "transcript" / "subagents")
      File.write(
        tmp / "transcript.jsonl", "{}\n",
      )
      File.write(
        tmp / "transcript" / "subagents" /
        "agent-dup2.meta.json",
        %({"agentType":"Explore","description":"Updated desc"}),
      )

      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "dup2",
        "--agent-type", "Explore",
        "--parent-transcript-path",
        (tmp / "transcript.jsonl").to_s,
      ])

      show = run_binary([
        "show",
        "--ledger-session-id", "1",
        "--agent-id", "dup2",
        "--json",
      ])
      parsed = JSON.parse(show[:output])
      parsed["description"].as_s.should eq(
        "Updated desc",
      )
      parsed["status"].as_s.should eq("running")

      # Verify only one agent listed
      list = run_binary([
        "list",
        "--ledger-session-id", "1",
        "--json",
      ])
      agents = JSON.parse(list[:output])["agents"]
        .as_a
      dup_agents = agents.select do |a|
        a["agent_id"].as_s == "dup2"
      end
      dup_agents.size.should eq(1)

      FileUtils.rm_rf(tmp.to_s)
    end

    it "publishes no timeline event when already running" do
      log_path = build_timeline_logging_stub

      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "sd1",
        "--agent-type", "Explore",
      ])

      # Snapshot the log just before the second start so we
      # can isolate which timeline records came from it.
      sleep 100.milliseconds
      pre_start = read_timeline_log(log_path).size

      result = run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "sd1",
        "--agent-type", "Explore",
      ])

      result[:status].should eq(0)
      result[:output].should contain(
        "was already running",
      )

      # Timeline publish is fire-and-forget; give it a
      # moment to actually NOT happen.
      sleep 200.milliseconds
      post_start = read_timeline_log(log_path)
      start_calls = post_start.skip(pre_start)

      start_calls.any? do |line|
        line.includes?("agent:started")
      end.should be_false
    ensure
      File.delete(log_path) if log_path &&
                               File.exists?(log_path)
      restore_timeline_noop
    end

    it "still publishes timeline event on a fresh start" do
      log_path = build_timeline_logging_stub

      sleep 100.milliseconds
      pre_start = read_timeline_log(log_path).size

      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "sd2",
        "--agent-type", "Explore",
      ])

      sleep 200.milliseconds
      post_start = read_timeline_log(log_path)
      start_calls = post_start.skip(pre_start)

      start_calls.any? do |line|
        line.includes?("agent:started")
      end.should be_true
    ensure
      File.delete(log_path) if log_path &&
                               File.exists?(log_path)
      restore_timeline_noop
    end

    it "publishes the stop that follows a resume" do
      log_path = build_timeline_logging_stub

      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "sd4",
        "--agent-type", "Explore",
      ])
      run_binary(
        [
          "stop",
          "--ledger-session-id", "1",
          "--agent-id", "sd4",
          "--last-message-stdin",
        ],
        stdin: "First run done",
      )

      # Resume: the row must return to running, or the stop
      # below reads as a repeat of an already-terminal stop
      # and publishes nothing — leaving the agent started
      # once more than it was ever stopped, which is what
      # strands it in the running set of anything counting.
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "sd4",
        "--agent-type", "Explore",
      ])
      run_binary(
        [
          "stop",
          "--ledger-session-id", "1",
          "--agent-id", "sd4",
          "--last-message-stdin",
        ],
        stdin: "Second run done",
      )

      calls = wait_for_timeline_calls(log_path, 4)
      count_calls(calls, "sd4", "agent:started").should eq(2)
      count_calls(calls, "sd4", "agent:stopped").should eq(2)
    ensure
      File.delete(log_path) if log_path &&
                               File.exists?(log_path)
      restore_timeline_noop
    end

    it "suppresses a third start after a resume" do
      log_path = build_timeline_logging_stub

      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "sd5",
        "--agent-type", "Explore",
      ])
      run_binary(
        [
          "stop",
          "--ledger-session-id", "1",
          "--agent-id", "sd5",
          "--last-message-stdin",
        ],
        stdin: "Done",
      )
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "sd5",
        "--agent-type", "Explore",
      ])

      result = run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "sd5",
        "--agent-type", "Explore",
      ])
      result[:output].should contain(
        "was already running",
      )

      calls = wait_for_timeline_calls(log_path, 3)
      count_calls(calls, "sd5", "agent:started").should eq(2)
    ensure
      File.delete(log_path) if log_path &&
                               File.exists?(log_path)
      restore_timeline_noop
    end

    it "keeps the description when a resume reads none" do
      tmp = Path.new(Dir.tempdir) /
            "galaxy-agents-keep-#{Random.rand(100000)}"
      Dir.mkdir_p(tmp / "transcript" / "subagents")
      File.write(
        tmp / "transcript.jsonl", "{}\n",
      )
      meta = tmp / "transcript" / "subagents" /
             "agent-sd3.meta.json"
      File.write(
        meta,
        %({"agentType":"Explore","description":"First desc"}),
      )

      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "sd3",
        "--agent-type", "Explore",
        "--parent-transcript-path",
        (tmp / "transcript.jsonl").to_s,
      ])

      # A resumed agent re-runs start, and the sidecar is
      # frequently unreadable the second time around.
      File.delete(meta)

      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "sd3",
        "--agent-type", "Explore",
        "--parent-transcript-path",
        (tmp / "transcript.jsonl").to_s,
      ])

      show = run_binary([
        "show",
        "--ledger-session-id", "1",
        "--agent-id", "sd3",
        "--json",
      ])
      parsed = JSON.parse(show[:output])
      parsed["description"].as_s.should eq("First desc")

      FileUtils.rm_rf(tmp.to_s)
    end
  end

  describe "duration formatting" do
    it "renders whole minutes without a fraction" do
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "dur1",
        "--agent-type", "Explore",
      ])
      GalaxyAgents::Database.stop_agent(
        1_i64, "dur1",
        status: "stopped",
        duration_ms: 331_875_i64,
      )

      result = run_binary([
        "list",
        "--ledger-session-id", "1",
      ])

      result[:output].should contain("5m31.9s")
      result[:output].should_not contain("5.53125")
    end
  end

  describe "stop" do
    it "stops a running agent with success" do
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "s1",
        "--agent-type", "Explore",
      ])

      result = run_binary(
        [
          "stop",
          "--ledger-session-id", "1",
          "--agent-id", "s1",
          "--last-message-stdin",
        ],
        stdin: "Found 15 files",
      )

      result[:status].should eq(0)
      result[:output].should contain("Agent s1 stopped")
    end

    it "marks as failed with empty stdin" do
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "f1",
        "--agent-type", "Explore",
      ])

      result = run_binary(
        [
          "stop",
          "--ledger-session-id", "1",
          "--agent-id", "f1",
          "--last-message-stdin",
        ],
        stdin: "",
      )

      result[:status].should eq(0)
      result[:output].should contain("Agent f1 failed")
    end

    it "extracts prompt from transcript" do
      tmp = Path.new(Dir.tempdir) /
            "galaxy-agents-stop-#{Random.rand(100000)}"
      Dir.mkdir_p(tmp)
      transcript = tmp / "agent-t1.jsonl"
      File.write(transcript, %({"type":"user","message":{"role":"user","content":"Search for timeline files"}}\n{"type":"assistant","message":{"role":"assistant","content":"Found 10 files"}}\n))

      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "t1",
        "--agent-type", "Explore",
      ])

      result = run_binary(
        [
          "stop",
          "--ledger-session-id", "1",
          "--agent-id", "t1",
          "--agent-transcript-path",
          transcript.to_s,
          "--last-message-stdin",
        ],
        stdin: "Found 10 files",
      )

      result[:status].should eq(0)

      show = run_binary([
        "show",
        "--ledger-session-id", "1",
        "--agent-id", "t1",
        "--json",
      ])
      parsed = JSON.parse(show[:output])
      parsed["prompt"].as_s.should eq(
        "Search for timeline files",
      )

      FileUtils.rm_rf(tmp.to_s)
    end

    it "errors when agent not found" do
      result = run_binary(
        [
          "stop",
          "--ledger-session-id", "1",
          "--agent-id", "nonexistent",
          "--last-message-stdin",
        ],
        stdin: "msg",
      )

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end

    it "succeeds on double stop (idempotent)" do
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "ids1",
        "--agent-type", "Explore",
      ])

      r1 = run_binary(
        [
          "stop",
          "--ledger-session-id", "1",
          "--agent-id", "ids1",
          "--last-message-stdin",
        ],
        stdin: "First msg",
      )
      r1[:status].should eq(0)

      r2 = run_binary(
        [
          "stop",
          "--ledger-session-id", "1",
          "--agent-id", "ids1",
          "--last-message-stdin",
        ],
        stdin: "Second msg",
      )
      r2[:status].should eq(0)
    end

    it "enriches fields on idempotent stop" do
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "ids2",
        "--agent-type", "Explore",
      ])

      # First stop with last_message only
      run_binary(
        [
          "stop",
          "--ledger-session-id", "1",
          "--agent-id", "ids2",
          "--last-message-stdin",
        ],
        stdin: "First msg",
      )

      # Create transcript for second stop
      tmp = Path.new(Dir.tempdir) /
            "galaxy-agents-idstop-" \
            "#{Random.rand(100000)}"
      Dir.mkdir_p(tmp)
      transcript = tmp / "agent-ids2.jsonl"
      File.write(
        transcript,
        %({"type":"user","message":{"role":"user","content":"Second prompt"}}\n),
      )

      # Second stop with transcript (adds prompt)
      run_binary(
        [
          "stop",
          "--ledger-session-id", "1",
          "--agent-id", "ids2",
          "--agent-transcript-path",
          transcript.to_s,
          "--last-message-stdin",
        ],
        stdin: "Second msg",
      )

      show = run_binary([
        "show",
        "--ledger-session-id", "1",
        "--agent-id", "ids2",
        "--json",
      ])
      parsed = JSON.parse(show[:output])
      # Status unchanged from first stop
      parsed["status"].as_s.should eq("stopped")
      # Second call's non-blank fields updated
      parsed["last_message"].as_s.should eq(
        "Second msg",
      )
      parsed["prompt"].as_s.should eq(
        "Second prompt",
      )

      FileUtils.rm_rf(tmp.to_s)
    end

    it "preserves existing values on blank stop" do
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "ids3",
        "--agent-type", "Explore",
      ])

      tmp = Path.new(Dir.tempdir) /
            "galaxy-agents-idblank-" \
            "#{Random.rand(100000)}"
      Dir.mkdir_p(tmp)
      transcript = tmp / "agent-ids3.jsonl"
      File.write(
        transcript,
        %({"type":"user","message":{"role":"user","content":"Original prompt"}}\n),
      )

      # First stop with prompt + last_message
      run_binary(
        [
          "stop",
          "--ledger-session-id", "1",
          "--agent-id", "ids3",
          "--agent-transcript-path",
          transcript.to_s,
          "--last-message-stdin",
        ],
        stdin: "Original msg",
      )

      # Second stop with empty stdin (blank)
      run_binary(
        [
          "stop",
          "--ledger-session-id", "1",
          "--agent-id", "ids3",
          "--last-message-stdin",
        ],
        stdin: "",
      )

      show = run_binary([
        "show",
        "--ledger-session-id", "1",
        "--agent-id", "ids3",
        "--json",
      ])
      parsed = JSON.parse(show[:output])
      # Original values preserved
      parsed["prompt"].as_s.should eq(
        "Original prompt",
      )
      parsed["last_message"].as_s.should eq(
        "Original msg",
      )

      FileUtils.rm_rf(tmp.to_s)
    end

    it "saves transcript artifact with --skip-event" do
      log_path = build_artifacts_logging_stub
      File.delete(log_path) if File.exists?(log_path)

      tmp = Path.new(Dir.tempdir) /
            "galaxy-agents-skipevt-#{Random.rand(100000)}"
      Dir.mkdir_p(tmp)
      transcript = tmp / "agent-skipevt.jsonl"
      File.write(
        transcript,
        %({"type":"assistant",) +
        %("message":{"role":"assistant",) +
        %("content":"ok"}}\n),
      )

      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "skipevt",
        "--agent-type", "Explore",
      ])

      result = run_binary(
        [
          "stop",
          "--ledger-session-id", "1",
          "--agent-id", "skipevt",
          "--agent-transcript-path",
          transcript.to_s,
          "--last-message-stdin",
        ],
        stdin: "ok",
      )

      result[:status].should eq(0)

      # save_transcript_artifact is fire-and-forget —
      # give the subprocess time to log before reading.
      sleep 200.milliseconds

      # Find the save call for OUR transcript specifically.
      # Earlier tests in this describe block fire the same
      # fire-and-forget save path; their subprocesses can
      # race with ours after the logging stub is installed.
      lines = read_artifacts_log(log_path)
      save_call = lines.find do |line|
        line.includes?("save") &&
          line.includes?(transcript.to_s)
      end

      save_call.should_not be_nil
      call = save_call.not_nil!
      call.should contain("--skip-event")
      call.should contain("--artifact-type")
      call.should contain("jsonl")

      FileUtils.rm_rf(tmp.to_s)
    ensure
      File.delete(log_path) if log_path &&
                               File.exists?(log_path)
      restore_artifacts_noop
    end

    it "preserves abandoned status on a later stop" do
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "sa1",
        "--agent-type", "Explore",
      ])
      run_binary([
        "abandon",
        "--ledger-session-id", "1",
        "--agent-id", "sa1",
      ])

      result = run_binary(
        [
          "stop",
          "--ledger-session-id", "1",
          "--agent-id", "sa1",
          "--last-message-stdin",
        ],
        stdin: "Done!",
      )

      result[:status].should eq(0)
      result[:output].should contain(
        "was already abandoned",
      )

      list = run_binary([
        "list",
        "--ledger-session-id", "1",
        "--json",
      ])
      parsed = JSON.parse(list[:output])
      sa1 = parsed["agents"].as_a.find do |a|
        a["agent_id"].as_s == "sa1"
      end
      sa1.should_not be_nil
      sa1.not_nil!["status"].as_s.should eq("abandoned")
      # The idempotent stop path still captures the
      # final response so the detail view can show it.
      sa1.not_nil!["last_message"].as_s.should eq("Done!")
    end

    it(
      "skips lifecycle timeline event when " \
      "stop arrives after abandon",
    ) do
      log_path = build_timeline_logging_stub

      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "sa2",
        "--agent-type", "Explore",
      ])
      run_binary([
        "abandon",
        "--ledger-session-id", "1",
        "--agent-id", "sa2",
      ])

      # Snapshot the log just before the stop call so we
      # can isolate which timeline records came from stop.
      sleep 100.milliseconds
      pre_stop = read_timeline_log(log_path).size

      run_binary(
        [
          "stop",
          "--ledger-session-id", "1",
          "--agent-id", "sa2",
          "--last-message-stdin",
        ],
        stdin: "Late finish",
      )

      # Timeline publish is fire-and-forget; give it a
      # moment to actually NOT happen.
      sleep 200.milliseconds
      post_stop = read_timeline_log(log_path)
      stop_calls = post_stop.skip(pre_stop)

      stop_calls.any? do |line|
        line.includes?("agent:stopped")
      end.should be_false
      stop_calls.any? do |line|
        line.includes?("agent:failed")
      end.should be_false
    ensure
      File.delete(log_path) if log_path &&
                               File.exists?(log_path)
      restore_timeline_noop
    end

    it "still publishes timeline event on normal stop" do
      log_path = build_timeline_logging_stub

      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "sa3",
        "--agent-type", "Explore",
      ])

      sleep 100.milliseconds
      pre_stop = read_timeline_log(log_path).size

      run_binary(
        [
          "stop",
          "--ledger-session-id", "1",
          "--agent-id", "sa3",
          "--last-message-stdin",
        ],
        stdin: "Finished cleanly",
      )

      sleep 200.milliseconds
      post_stop = read_timeline_log(log_path)
      stop_calls = post_stop.skip(pre_stop)

      stop_calls.any? do |line|
        line.includes?("agent:stopped")
      end.should be_true
    ensure
      File.delete(log_path) if log_path &&
                               File.exists?(log_path)
      restore_timeline_noop
    end
  end

  describe "abandon" do
    it "abandons all running agents" do
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "ab1",
        "--agent-type", "Explore",
      ])
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "ab2",
        "--agent-type", "general-purpose",
      ])

      result = run_binary([
        "abandon",
        "--ledger-session-id", "1",
      ])

      result[:status].should eq(0)
      result[:output].should contain("Abandoned 2 agents")
    end

    it "reports 0 when no running agents" do
      result = run_binary([
        "abandon",
        "--ledger-session-id", "1",
      ])

      result[:status].should eq(0)
      result[:output].should contain("Abandoned 0 agents")
    end

    it "abandons a single agent by id" do
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "ab1",
        "--agent-type", "Explore",
      ])
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "ab2",
        "--agent-type", "general-purpose",
      ])

      result = run_binary([
        "abandon",
        "--ledger-session-id", "1",
        "--agent-id", "ab1",
      ])

      result[:status].should eq(0)
      result[:output].should contain("Abandoned agent ab1")

      # ab2 is still running
      list = run_binary([
        "list",
        "--ledger-session-id", "1",
        "--json",
      ])
      parsed = JSON.parse(list[:output])
      statuses = parsed["agents"].as_a.map do |a|
        {a["agent_id"].as_s, a["status"].as_s}
      end
      statuses.should contain({"ab1", "abandoned"})
      statuses.should contain({"ab2", "running"})
    end

    it "exits 0 with no-op message for already terminal" do
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "ab1",
        "--agent-type", "Explore",
      ])
      run_binary([
        "abandon",
        "--ledger-session-id", "1",
        "--agent-id", "ab1",
      ])

      result = run_binary([
        "abandon",
        "--ledger-session-id", "1",
        "--agent-id", "ab1",
      ])

      result[:status].should eq(0)
      result[:output].should contain("not running")
    end

    it "exits 0 with no-op message for missing agent" do
      result = run_binary([
        "abandon",
        "--ledger-session-id", "1",
        "--agent-id", "never-existed",
      ])

      result[:status].should eq(0)
      result[:output].should contain("not running")
    end
  end

  describe "list" do
    it "lists agents in human-readable format" do
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "l1",
        "--agent-type", "Explore",
      ])
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "l2",
        "--agent-type", "general-purpose",
      ])

      result = run_binary([
        "list",
        "--ledger-session-id", "1",
      ])

      result[:status].should eq(0)
      result[:output].should contain("2 total")
      result[:output].should contain("l1")
      result[:output].should contain("l2")
    end

    it "lists in JSON format" do
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "j1",
        "--agent-type", "Explore",
      ])

      result = run_binary([
        "list",
        "--ledger-session-id", "1",
        "--json",
      ])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      agents = parsed["agents"].as_a
      agents.size.should eq(1)
      agents[0]["agent_id"].as_s.should eq("j1")
      agents[0]["status"].as_s.should eq("running")
    end

    it "shows empty message when no agents" do
      result = run_binary([
        "list",
        "--ledger-session-id", "1",
      ])

      result[:status].should eq(0)
      result[:output].should contain("No agents")
    end

    it "returns empty JSON array" do
      result = run_binary([
        "list",
        "--ledger-session-id", "1",
        "--json",
      ])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["agents"].as_a.size.should eq(0)
    end
  end

  describe "show" do
    it "shows full agent detail in JSON" do
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "sh1",
        "--agent-type", "Explore",
      ])

      result = run_binary([
        "show",
        "--ledger-session-id", "1",
        "--agent-id", "sh1",
        "--json",
      ])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["agent_id"].as_s.should eq("sh1")
      parsed["agent_type"].as_s.should eq("Explore")
      parsed["status"].as_s.should eq("running")
    end

    it "shows human-readable detail" do
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "sh2",
        "--agent-type", "Explore",
      ])

      result = run_binary([
        "show",
        "--ledger-session-id", "1",
        "--agent-id", "sh2",
      ])

      result[:status].should eq(0)
      result[:output].should contain("Agent: sh2")
      result[:output].should contain("Explore")
      result[:output].should contain("running")
    end

    it "errors when agent not found" do
      result = run_binary([
        "show",
        "--ledger-session-id", "1",
        "--agent-id", "nonexistent",
      ])

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end
  end

  describe "running" do
    it "returns running count as JSON" do
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "r1",
        "--agent-type", "Explore",
      ])
      run_binary([
        "start",
        "--ledger-session-id", "1",
        "--agent-id", "r2",
        "--agent-type", "Explore",
      ])

      result = run_binary([
        "running",
        "--ledger-session-id", "1",
        "--json",
      ])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["count"].as_i.should eq(2)
    end

    it "returns 0 when none running" do
      result = run_binary([
        "running",
        "--ledger-session-id", "1",
      ])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["count"].as_i.should eq(0)
    end
  end

  describe "help and version" do
    it "shows help" do
      result = run_binary(["help"])
      result[:status].should eq(0)
      result[:output].should contain("galaxy-agents")
      result[:output].should contain("COMMANDS")
    end

    it "shows version" do
      result = run_binary(["version"])
      result[:status].should eq(0)
      result[:output].should contain("galaxy-agents")
    end

    it "shows subcommand help" do
      result = run_binary(["help", "start"])
      result[:status].should eq(0)
      result[:output].should contain("--agent-id")
    end

    it "errors on unknown command" do
      result = run_binary(["nonexistent"])
      result[:status].should_not eq(0)
      result[:error].should contain("Unknown command")
    end
  end
end
