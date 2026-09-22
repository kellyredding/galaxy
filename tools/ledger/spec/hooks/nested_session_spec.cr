require "../spec_helper"

private alias Info = GalaxyLedger::Hooks::NestedSession::ProcessInfo

# Runs the block against a described process tree — pid to parent pid and
# command name — and the set of pids the ledger tracks, restoring the real
# lookups afterwards.
private def with_tree(
  tree : Hash(Int64, Tuple(Int64, String)),
  tracked_pids : Set(Int64),
  &
)
  nested = GalaxyLedger::Hooks::NestedSession
  looked_up = [] of Int64
  nested.lookup = ->(pid : Int64) {
    looked_up << pid
    tree[pid]?.try { |(ppid, comm)| Info.new(ppid, comm) }
  }
  nested.tracked = ->(pid : Int64) { tracked_pids.includes?(pid) }
  begin
    yield looked_up
  ensure
    nested.lookup = ->(pid : Int64) { nested.process_info(pid) }
    nested.tracked = ->(pid : Int64) {
      !GalaxyLedger::Database.resolve_claude_pid(pid).nil?
    }
  end
end

# A Claude Persona session as Galaxy launches it.
private SESSION_ANCESTRY = {
  100_i64 => {99_i64, "claude"},
   99_i64 => {98_i64, "claude-persona"},
   98_i64 => {1_i64, "/Applications/Galaxy.app/Contents/MacOS/Galaxy"},
}

describe GalaxyLedger::Hooks::NestedSession do
  describe ".nested?" do
    it "answers false for a claude the ledger already tracks, without walking" do
      with_tree(SESSION_ANCESTRY, Set{100_i64}) do |looked_up|
        GalaxyLedger::Hooks::NestedSession.nested?(100_i64).should be_false
        looked_up.should be_empty
      end
    end

    it "answers false for a top-level session under claude-persona" do
      # 99 tracked as well, so only the exact-name rule stands between a
      # persona parent and every session being taken for a nested one.
      with_tree(SESSION_ANCESTRY, Set{99_i64}) do
        GalaxyLedger::Hooks::NestedSession.nested?(100_i64).should be_false
      end
    end

    it "answers true for a claude run by a hook inside a tracked session" do
      tree = SESSION_ANCESTRY.merge({
        300_i64 => {200_i64, "claude"},
        200_i64 => {100_i64, "/bin/bash"},
      })
      with_tree(tree, Set{100_i64}) do
        GalaxyLedger::Hooks::NestedSession.nested?(300_i64).should be_true
      end
    end

    it "matches a claude executed by its full path" do
      tree = {
        300_i64 => {200_i64, "claude"},
        200_i64 => {100_i64, "/bin/bash"},
        100_i64 => {1_i64, "/Users/someone/.local/bin/claude"},
      }
      with_tree(tree, Set{100_i64}) do
        GalaxyLedger::Hooks::NestedSession.nested?(300_i64).should be_true
      end
    end

    it "answers false under a claude this ledger does not track" do
      # The end-to-end harness: its session runs inside the developer's own,
      # which is tracked in a different database than the harness sandbox.
      tree = SESSION_ANCESTRY.merge({
        400_i64 => {300_i64, "claude"},
        300_i64 => {200_i64, "python3"},
        200_i64 => {100_i64, "/bin/bash"},
      })
      with_tree(tree, Set(Int64).new) do
        GalaxyLedger::Hooks::NestedSession.nested?(400_i64).should be_false
      end
    end

    it "answers false when a process vanishes mid-walk" do
      tree = {300_i64 => {200_i64, "claude"}}
      with_tree(tree, Set{100_i64}) do
        GalaxyLedger::Hooks::NestedSession.nested?(300_i64).should be_false
      end
    end

    it "stops at MAX_DEPTH on a tree that loops" do
      tree = {
        300_i64 => {200_i64, "claude"},
        200_i64 => {201_i64, "/bin/bash"},
        201_i64 => {200_i64, "/bin/bash"},
      }
      with_tree(tree, Set(Int64).new) do |looked_up|
        GalaxyLedger::Hooks::NestedSession.nested?(300_i64).should be_false
        looked_up.size.should eq(GalaxyLedger::Hooks::NestedSession::MAX_DEPTH + 1)
      end
    end
  end

  describe ".claude?" do
    it "matches the name and a path ending in it, nothing else" do
      nested = GalaxyLedger::Hooks::NestedSession
      nested.claude?("claude").should be_true
      nested.claude?("/Users/someone/.local/bin/claude").should be_true
      nested.claude?("claude-persona").should be_false
      nested.claude?("/usr/local/bin/claude-persona").should be_false
      nested.claude?("node").should be_false
    end
  end

  describe ".process_info" do
    it "reads this process's parent and name from ps" do
      info = GalaxyLedger::Hooks::NestedSession
        .process_info(Process.pid.to_i64)
      info.should_not be_nil
      info.not_nil!.ppid.should eq(Process.ppid.to_i64)
      info.not_nil!.comm.should_not be_empty
    end

    it "reports a process executed as claude by that name" do
      with_fake_claude do |pid|
        info = GalaxyLedger::Hooks::NestedSession.process_info(pid)
        GalaxyLedger::Hooks::NestedSession.claude?(info.not_nil!.comm)
          .should be_true
      end
    end

    it "answers nil for a pid that does not exist" do
      GalaxyLedger::Hooks::NestedSession.process_info(999_999_999_i64)
        .should be_nil
    end
  end
end

# A real outer `claude` running a hook inside a real inner one: /bin/bash
# reached through a symlink named claude, so `ps` reports the name while the
# signed binary runs. `; true` after each command keeps every shell alive as
# its child's parent instead of exec'ing the command in its place, which is
# how Claude Code runs a hook too.
#
# The outer one waits until the block has had the chance to register it,
# then the inner one runs the built binary's on-startup with the outer
# session's id in its environment — exactly what an inherited
# CLAUDE_CLI_SESSION_ID gives it.
private def run_nested_startup(
  inner_session_id : String,
  outer_session_id : String,
  &
)
  dir = Path.new(Dir.tempdir) / "galaxy-ledger-spec-nested-#{Random.rand(100000)}"
  Dir.mkdir_p(dir)
  claude = dir / "claude"
  File.symlink("/bin/bash", claude.to_s)
  gate = dir / "go"
  input = dir / "input.json"
  File.write(input, {"session_id" => inner_session_id}.to_json)

  inner = "#{Process.quote(BINARY_PATH.to_s)} on-startup " \
          "< #{Process.quote(input.to_s)}; true"
  outer = "while [ ! -e #{Process.quote(gate.to_s)} ]; do sleep 0.05; done; " \
          "#{Process.quote(claude.to_s)} -c #{Process.quote(inner)}; true"

  ENV.delete("GALAXY_LEDGER_SKIP_CLI")
  process = Process.new(
    claude.to_s,
    args: ["-c", outer],
    env: binary_env.merge({"CLAUDE_CLI_SESSION_ID" => outer_session_id}),
    output: Process::Redirect::Close,
    error: Process::Redirect::Close,
  )

  begin
    yield process.pid.to_i64
    File.write(gate, "")
    process.wait
  ensure
    process.signal(Signal::KILL) rescue nil
    process.wait rescue nil
    FileUtils.rm_rf(dir.to_s)
  end
end

describe "the hook gate, with a real process tree" do
  it "leaves a claude nested inside a tracked session out of the ledger" do
    outer_id = "outer-#{Random.rand(100000)}"
    inner_id = "inner-#{Random.rand(100000)}"

    run_nested_startup(inner_id, outer_id) do |outer_pid|
      GalaxyLedger::Database.create_session(outer_id, claude_pid: outer_pid)
      flush_wal_for(outer_id)
    end

    GalaxyLedger::Database.resolve_session_identifier(inner_id).should be_nil
    outer = GalaxyLedger::Database.resolve_session_identifier(outer_id)
    outer.should_not be_nil
  end

  it "still records a claude whose outer claude the ledger does not track" do
    outer_id = "outer-#{Random.rand(100000)}"
    inner_id = "inner-#{Random.rand(100000)}"

    run_nested_startup(inner_id, outer_id) { |_| }

    GalaxyLedger::Database.resolve_session_identifier(inner_id)
      .should_not be_nil
  end
end
