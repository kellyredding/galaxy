require "../spec_helper"

# A parent transcript, optionally ending in its hand-off to the fork, and the
# fork's transcript beside it, opening with a record copied from the parent.
private def with_fork_transcripts(
  parent_sid : String,
  launch_id : String,
  fork_sid : String,
  handed_off : Bool,
  copied_records : Bool = true,
  &
)
  dir = Path.new(Dir.tempdir) / "galaxy-ledger-spec-fork-#{Random.rand(100000)}"
  Dir.mkdir_p(dir)
  File.open(dir / "#{parent_sid}.jsonl", "w") do |f|
    f.puts(%|{"type":"assistant","sessionId":"#{parent_sid}","session_id":"#{launch_id}"}|)
    if handed_off
      f.puts(%|{"type":"continued-in","sessionId":"#{parent_sid}","continuedInSessionId":"#{fork_sid}"}|)
    end
  end
  fork_path = dir / "#{fork_sid}.jsonl"
  File.open(fork_path, "w") do |f|
    if copied_records
      f.puts(%|{"type":"attachment","sessionId":"#{fork_sid}","session_id":"#{launch_id}"}|)
    end
    f.puts(%|{"type":"user","sessionId":"#{fork_sid}","session_id":"#{fork_sid}"}|)
  end

  begin
    yield fork_path.to_s
  ensure
    FileUtils.rm_rf(dir.to_s)
  end
end

# A ledger session as it stands just before a fork: launched under one id,
# currently on another.
private def session_before_fork(launch_id : String, parent_sid : String) : Int64
  ledger_id = GalaxyLedger::Database.create_session(launch_id)
  GalaxyLedger::Database.update_session(ledger_id, session_identifier: parent_sid)
  ledger_id
end

private def run_on_fork(
  fork_sid : String,
  transcript : String?,
  extra_env : Hash(String, String) = {} of String => String,
)
  input = {"session_id" => fork_sid, "source" => "fork"}
  input["transcript_path"] = transcript if transcript
  run_binary(
    ["on-fork"],
    stdin: input.to_json,
    extra_env: {"GALAXY_FORK_HANDOFF_WAIT_MS" => "0"}.merge(extra_env),
  )
end

private def ids
  n = Random.rand(1_000_000)
  {"fork-launch-#{n}", "fork-parent-#{n}", "fork-child-#{n}"}
end

describe "OnFork GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"
    result = run_binary(["on-fork"], stdin: {"session_id" => "x"}.to_json)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  ensure
    ENV.delete("GALAXY_SKIP_HOOKS")
  end
end

describe "OnFork adopting a fork that replaced its parent" do
  it "makes the fork the session's current id" do
    launch_id, parent_sid, fork_sid = ids
    ledger_id = session_before_fork(launch_id, parent_sid)

    with_fork_transcripts(parent_sid, launch_id, fork_sid, handed_off: true) do |path|
      result = run_on_fork(fork_sid, path)
      result[:status].should eq(0)
      JSON.parse(result[:output])["systemMessage"].as_s
        .should contain("follows the background session")
    end

    GalaxyLedger::Database.resolve_session_identifier(fork_sid).should eq(ledger_id)
    GalaxyLedger::Database.get_session_by_id(ledger_id).not_nil!
      .current_session_identifier.should eq(fork_sid)
  end

  it "registers the worker's pid as current" do
    launch_id, parent_sid, fork_sid = ids
    ledger_id = session_before_fork(launch_id, parent_sid)

    with_fork_transcripts(parent_sid, launch_id, fork_sid, handed_off: true) do |path|
      run_on_fork(fork_sid, path)
    end

    # The spec runner is the hook binary's parent, as Claude Code is.
    worker_pid = Process.pid.to_i64
    GalaxyLedger::Database.resolve_claude_pid(worker_pid).should eq(ledger_id)
    GalaxyLedger::Database.get_session_by_id(ledger_id).not_nil!
      .current_claude_pid.should eq(worker_pid)
  end

  it "keeps the ids the session had before" do
    launch_id, parent_sid, fork_sid = ids
    ledger_id = session_before_fork(launch_id, parent_sid)

    with_fork_transcripts(parent_sid, launch_id, fork_sid, handed_off: true) do |path|
      run_on_fork(fork_sid, path)
    end

    GalaxyLedger::Database.resolve_session_identifier(launch_id).should eq(ledger_id)
    GalaxyLedger::Database.resolve_session_identifier(parent_sid).should eq(ledger_id)
  end

  it "finds the parent through CLAUDE_CLI_SESSION_ID when the transcript cannot" do
    launch_id, parent_sid, fork_sid = ids
    ledger_id = session_before_fork(launch_id, parent_sid)

    with_fork_transcripts(
      parent_sid, launch_id, fork_sid,
      handed_off: true, copied_records: false,
    ) do |path|
      run_on_fork(fork_sid, path, {"CLAUDE_CLI_SESSION_ID" => launch_id})
    end

    GalaxyLedger::Database.get_session_by_id(ledger_id).not_nil!
      .current_session_identifier.should eq(fork_sid)
  end

  it "waits for a hand-off record written just after it starts" do
    launch_id, parent_sid, fork_sid = ids
    ledger_id = session_before_fork(launch_id, parent_sid)

    with_fork_transcripts(parent_sid, launch_id, fork_sid, handed_off: false) do |path|
      parent = (Path[path].parent / "#{parent_sid}.jsonl").to_s
      spawn do
        sleep 300.milliseconds
        File.open(parent, "a") do |f|
          f.puts(%|{"type":"continued-in","sessionId":"#{parent_sid}","continuedInSessionId":"#{fork_sid}"}|)
        end
      end
      run_on_fork(fork_sid, path, {"GALAXY_FORK_HANDOFF_WAIT_MS" => "3000"})
    end

    GalaxyLedger::Database.get_session_by_id(ledger_id).not_nil!
      .current_session_identifier.should eq(fork_sid)
  end
end

describe "OnFork leaving a parent that kept running" do
  it "neither registers nor adopts the fork" do
    launch_id, parent_sid, fork_sid = ids
    ledger_id = session_before_fork(launch_id, parent_sid)

    with_fork_transcripts(parent_sid, launch_id, fork_sid, handed_off: false) do |path|
      result = run_on_fork(fork_sid, path)
      result[:status].should eq(0)
      result[:error].should contain("not adopted")
    end

    GalaxyLedger::Database.resolve_session_identifier(fork_sid).should be_nil
    GalaxyLedger::Database.get_session_by_id(ledger_id).not_nil!
      .current_session_identifier.should eq(parent_sid)
  end

  it "ignores a hand-off to a different fork" do
    launch_id, parent_sid, fork_sid = ids
    ledger_id = session_before_fork(launch_id, parent_sid)

    with_fork_transcripts(parent_sid, launch_id, "someone-else", handed_off: true) do |other_path|
      # Same directory and parent; this fork is not the one handed to.
      path = (Path[other_path].parent / "#{fork_sid}.jsonl").to_s
      File.write(path, %|{"type":"attachment","sessionId":"#{fork_sid}","session_id":"#{launch_id}"}\n|)
      run_on_fork(fork_sid, path)
    end

    GalaxyLedger::Database.get_session_by_id(ledger_id).not_nil!
      .current_session_identifier.should eq(parent_sid)
  end
end

describe "OnFork when nothing resolves" do
  it "outputs valid JSON and creates no session" do
    fork_sid = "fork-orphan-#{Random.rand(1_000_000)}"
    sessions_before = GalaxyLedger::Database.list_sessions.size

    result = run_on_fork(fork_sid, nil)
    result[:status].should eq(0)
    JSON.parse(result[:output])["systemMessage"].as_s.should eq("Forked")

    GalaxyLedger::Database.resolve_session_identifier(fork_sid).should be_nil
    GalaxyLedger::Database.list_sessions.size.should eq(sessions_before)
  end

  it "handles malformed JSON stdin gracefully" do
    result = run_binary(["on-fork"], stdin: "not valid json")
    result[:status].should eq(0)
    JSON.parse(result[:output])["hookSpecificOutput"].should_not be_nil
  end
end

describe "OnFork help" do
  it "describes the fork source" do
    result = run_binary(["on-fork", "--help"])
    result[:output].should contain("SessionStart(fork)")
  end
end
