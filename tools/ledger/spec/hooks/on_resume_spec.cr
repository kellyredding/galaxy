require "../spec_helper"

describe "OnResume GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"

    test_session_id = "skip-hooks-resume-#{Random.rand(10000)}"
    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  ensure
    ENV.delete("GALAXY_SKIP_HOOKS")
  end
end

describe GalaxyLedger::Hooks::OnResume do
  describe "#run" do
    it "creates instance successfully" do
      handler = GalaxyLedger::Hooks::OnResume.new
      handler.should be_a(GalaxyLedger::Hooks::OnResume)
    end
  end
end

describe "OnResume JSON output" do
  it "outputs clean JSON with systemMessage and hookSpecificOutput" do
    test_session_id = "resume-json-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    result[:status].should eq(0)

    output = JSON.parse(result[:output])
    output["systemMessage"].should be_a(JSON::Any)
    output["hookSpecificOutput"]["hookEventName"].should eq("SessionStart")
    output["hookSpecificOutput"]["additionalContext"].should be_a(JSON::Any)
  end
end

describe "OnResume systemMessage" do
  it "shows 'Resumed' prefix" do
    test_session_id = "resume-sm-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("Resumed")
  end

  it "shows data counts when session has data" do
    test_session_id = "resume-sm-data-#{Random.rand(10000)}"
    ledger_id = GalaxyLedger::Database.create_session(test_session_id)

    2.times do |i|
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Resume learning #{i + 1}",
        importance: "medium",
      )
      GalaxyLedger::Database.insert(ledger_id, entry)
    end

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("Resumed")
    msg.should contain("2 learnings")
  end
end

describe "OnResume additionalContext" do
  it "includes Galaxy Ledger heading" do
    test_session_id = "resume-ctx-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("## Galaxy Ledger")
  end

  it "includes Ledger PID" do
    test_session_id = "resume-ctx-pid-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("**Ledger PID**:")
  end

  it "includes ledger awareness description" do
    test_session_id = "resume-ctx-aware-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("persistent context ledger")
    ctx.should contain("Guidelines")
    ctx.should contain("Decisions")
    ctx.should contain("Learnings")
    ctx.should contain("captured automatically by hooks")
    ctx.should contain("action needed for any of these")
  end

  it "includes lookup directives with --pid" do
    test_session_id = "resume-ctx-lookup-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("galaxy-ledger list-files")
    ctx.should contain("--pid")
    ctx.should contain("galaxy:recall")
    ctx.should contain("Normal exploration")
  end

  it "includes resumed session note when data exists" do
    test_session_id = "resume-ctx-note-#{Random.rand(10000)}"
    ledger_id = GalaxyLedger::Database.create_session(test_session_id)

    entry = GalaxyLedger::Entry.new(
      entry_type: "learning",
      content: "Test learning for resume",
      importance: "medium",
    )
    GalaxyLedger::Database.insert(ledger_id, entry)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("resumed session")
    ctx.should contain("conversation history is already")
    ctx.should contain("1 learning")
  end

  it "includes condensed counts for accumulated data" do
    test_session_id = "resume-ctx-counts-#{Random.rand(10000)}"
    ledger_id = GalaxyLedger::Database.create_session(test_session_id)

    # Add guideline file (counted from file_type, not entry_type)
    GalaxyLedger::Database.upsert_session_file(
      ledger_id, "/home/user/guidelines/ruby.md", :read,
      file_type: "guideline",
    )

    entry = GalaxyLedger::Entry.new(
      entry_type: "decision",
      content: "Use SQLite",
      importance: "high"
    )
    GalaxyLedger::Database.insert(ledger_id, entry)

    entry = GalaxyLedger::Entry.new(
      entry_type: "learning",
      content: "SQLite WAL mode is fast",
      importance: "medium"
    )
    GalaxyLedger::Database.insert(ledger_id, entry)

    GalaxyLedger::Database.upsert_session_file(ledger_id, "/home/user/app.cr", :read)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("1 guideline")
    ctx.should contain("1 decision")
    ctx.should contain("1 learning")
    ctx.should contain("2 session files tracked")
  end
end

describe "OnResume cwd and git_branch in additionalContext" do
  it "includes working directory when session has cwd" do
    test_session_id = "resume-cwd-#{Random.rand(10000)}"
    ledger_id = GalaxyLedger::Database.create_session(test_session_id)
    GalaxyLedger::Database.update_session(ledger_id, cwd: "#{Path.home}/projects/my-app")

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("**Working directory**: `~/projects/my-app`")
  end

  it "includes git branch when session has git_branch" do
    test_session_id = "resume-branch-#{Random.rand(10000)}"
    ledger_id = GalaxyLedger::Database.create_session(test_session_id)
    GalaxyLedger::Database.update_session(ledger_id, git_branch: "kr/feature-branch")

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("**Git branch**: `kr/feature-branch`")
  end

  it "omits working directory and git branch when nil" do
    test_session_id = "resume-no-cwd-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should_not contain("**Working directory**:")
    ctx.should_not contain("**Git branch**:")
  end

  it "includes both cwd and git_branch together" do
    test_session_id = "resume-both-#{Random.rand(10000)}"
    ledger_id = GalaxyLedger::Database.create_session(test_session_id)
    GalaxyLedger::Database.update_session(
      ledger_id,
      cwd: "#{Path.home}/projects/galaxy",
      git_branch: "main",
    )

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("**Working directory**: `~/projects/galaxy`")
    ctx.should contain("**Git branch**: `main`")
  end

  it "includes CWD restore directive when cwd is present" do
    test_session_id = "resume-cwd-directive-#{Random.rand(10000)}"
    ledger_id = GalaxyLedger::Database.create_session(test_session_id)
    GalaxyLedger::Database.update_session(
      ledger_id,
      cwd: "#{Path.home}/projects/my-app",
    )

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("**REQUIRED**")
    ctx.should contain("`cd`")
  end

  it "omits CWD restore directive when cwd is nil" do
    test_session_id = "resume-no-directive-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should_not contain("**REQUIRED**")
  end

  it "prefers last_stop_cwd over cwd column via best_cwd" do
    test_session_id = "resume-best-cwd-#{Random.rand(10000)}"
    ledger_id = GalaxyLedger::Database.create_session(test_session_id)

    # Set the cwd column to the project root
    GalaxyLedger::Database.update_session(
      ledger_id,
      cwd: "#{Path.home}/projects/galaxy",
    )

    # Stamp last_stop_cwd to a deeper subdirectory
    GalaxyLedger::Database.stamp_stop_cwd(
      ledger_id,
      "#{Path.home}/projects/galaxy/tools/ledger",
    )

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("~/projects/galaxy/tools/ledger")
  end
end

describe "OnResume resolves to original session via env var" do
  it "resolves existing session and registers new hook session_id" do
    # Setup: create original session with env var
    original_hook_id = "resume-resolve-orig-#{Random.rand(10000)}"
    env_id = "resume-resolve-env-#{Random.rand(10000)}"
    original_ledger_id = GalaxyLedger::Database.create_session(original_hook_id)
    GalaxyLedger::Database.register_session_identifier(original_ledger_id, env_id)

    # Add data to verify we resolve to the right session
    entry = GalaxyLedger::Entry.new(
      entry_type: "learning",
      content: "This is the original session data",
      importance: "medium"
    )
    GalaxyLedger::Database.insert(original_ledger_id, entry)

    # Resume: new hook session_id, same env var
    new_hook_id = "resume-resolve-new-#{Random.rand(10000)}"
    hook_input = {"session_id" => new_hook_id}.to_json

    result = run_binary(
      ["on-resume"],
      stdin: hook_input,
      extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
    )
    result[:status].should eq(0)

    # New hook_id should map to the original session
    GalaxyLedger::Database.resolve_session_identifier(new_hook_id).should eq(original_ledger_id)

    # Context should mention the data
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("1 learnings")
  end
end

describe "OnResume with stale PID collision" do
  it "resolves via env var, ignoring stale PID" do
    # Session A: correct session, with env var
    session_a_id = "resume-stale-a-#{Random.rand(10000)}"
    env_id = "resume-stale-env-#{Random.rand(10000)}"
    ledger_a = GalaxyLedger::Database.create_session(session_a_id)
    GalaxyLedger::Database.register_session_identifier(ledger_a, env_id)

    entry = GalaxyLedger::Entry.new(
      entry_type: "learning",
      content: "Session A data",
      importance: "medium"
    )
    GalaxyLedger::Database.insert(ledger_a, entry)

    new_hook_id = "resume-stale-new-#{Random.rand(10000)}"
    hook_input = {"session_id" => new_hook_id}.to_json

    result = run_binary(
      ["on-resume"],
      stdin: hook_input,
      extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
    )
    result[:status].should eq(0)

    # Should resolve to session A via env var
    GalaxyLedger::Database.resolve_session_identifier(new_hook_id).should eq(ledger_a)
  end
end

describe "OnResume resolves via stdin session_id when no env var" do
  it "finds original session by hook session_id" do
    # Setup: create session with session_id registered
    original_id = "resume-stdin-orig-#{Random.rand(10000)}"
    original_ledger_id = GalaxyLedger::Database.create_session(original_id)

    entry = GalaxyLedger::Entry.new(
      entry_type: "learning",
      content: "Original session data via stdin",
      importance: "medium"
    )
    GalaxyLedger::Database.insert(original_ledger_id, entry)

    # Resume: stdin = original session_id, no env var
    hook_input = {"session_id" => original_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    result[:status].should eq(0)

    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("Resumed")
    msg.should contain("1 learning")
  end
end

describe "OnResume returns output_empty when nothing resolves" do
  it "returns output_empty instead of creating a session" do
    new_hook_id = "resume-noresolve-#{Random.rand(10000)}"
    hook_input = {"session_id" => new_hook_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    result[:status].should eq(0)

    # Should NOT have created a new session
    ledger_id = GalaxyLedger::Database.resolve_session_identifier(new_hook_id)
    ledger_id.should be_nil

    # Output should still be valid JSON
    output = JSON.parse(result[:output])
    output["systemMessage"].as_s.should contain("Resumed")
  end
end

describe "OnResume orphan cleanup" do
  it "deletes orphan session created by OnStartup" do
    # Setup: create original session (session A)
    original_id = "resume-orphan-orig-#{Random.rand(10000)}"
    original_ledger_id = GalaxyLedger::Database.create_session(original_id)

    # Simulate OnStartup orphan: create session B with same PID as subprocess
    orphan_id = "resume-orphan-orphan-#{Random.rand(10000)}"
    # We need to use the PID that the subprocess will see as its ppid.
    # In tests, the subprocess's ppid is the Crystal spec runner PID.
    spec_runner_pid = Process.pid.to_i64
    orphan_ledger_id = GalaxyLedger::Database.create_session(orphan_id, claude_pid: spec_runner_pid)

    # Resume: stdin session_id resolves to session A
    hook_input = {"session_id" => original_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    result[:status].should eq(0)

    # Orphan should be deleted
    GalaxyLedger::Database.get_session_by_id(orphan_ledger_id).should be_nil

    # Original should still exist
    GalaxyLedger::Database.get_session_by_id(original_ledger_id).should_not be_nil

    # PID should now map to original session
    GalaxyLedger::Database.resolve_claude_pid(spec_runner_pid).should eq(original_ledger_id)
  end

  it "re-registers all orphan identifier mappings against original" do
    original_id = "resume-orphan-ids-orig-#{Random.rand(10000)}"
    original_ledger_id = GalaxyLedger::Database.create_session(original_id)

    # Create orphan with two identifiers
    orphan_id = "resume-orphan-ids-orphan-#{Random.rand(10000)}"
    extra_orphan_id = "resume-orphan-ids-extra-#{Random.rand(10000)}"
    spec_runner_pid = Process.pid.to_i64
    orphan_ledger_id = GalaxyLedger::Database.create_session(orphan_id, claude_pid: spec_runner_pid)
    GalaxyLedger::Database.register_session_identifier(orphan_ledger_id, extra_orphan_id)

    # Resume: resolves to original via stdin
    hook_input = {"session_id" => original_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    result[:status].should eq(0)

    # Both orphan identifiers should now resolve to original session
    GalaxyLedger::Database.resolve_session_identifier(orphan_id).should eq(original_ledger_id)
    GalaxyLedger::Database.resolve_session_identifier(extra_orphan_id).should eq(original_ledger_id)
  end

  it "re-registers all orphan PID mappings against original" do
    original_id = "resume-orphan-pids-orig-#{Random.rand(10000)}"
    original_ledger_id = GalaxyLedger::Database.create_session(original_id)

    # Create orphan with PID
    orphan_id = "resume-orphan-pids-orphan-#{Random.rand(10000)}"
    spec_runner_pid = Process.pid.to_i64
    orphan_ledger_id = GalaxyLedger::Database.create_session(orphan_id, claude_pid: spec_runner_pid)

    # Resume: resolves to original via stdin
    hook_input = {"session_id" => original_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    result[:status].should eq(0)

    # PID should map to original
    GalaxyLedger::Database.resolve_claude_pid(spec_runner_pid).should eq(original_ledger_id)
  end

  it "preserves a session with accumulated entries (guardrail)" do
    # An OnStartup-created orphan never has entries — entries come
    # from Stop/UserPromptSubmit/PostToolUse hooks running during real
    # work. A session with entries whose PID happens to match ours is
    # almost certainly a real long-running session whose PID got
    # recycled by the OS, not an orphan. The guardrail must refuse
    # to CASCADE-delete it.
    resolved_id = "resume-guardrail-entries-resolved-#{Random.rand(10000)}"
    resolved_ledger_id = GalaxyLedger::Database.create_session(resolved_id)

    stale_id = "resume-guardrail-entries-stale-#{Random.rand(10000)}"
    spec_runner_pid = Process.pid.to_i64
    stale_ledger_id = GalaxyLedger::Database.create_session(stale_id, claude_pid: spec_runner_pid)

    stale_entry = GalaxyLedger::Entry.new(
      entry_type: "learning",
      content: "Real session's data must survive",
      importance: "medium",
    )
    GalaxyLedger::Database.insert(stale_ledger_id, stale_entry)
    GalaxyLedger::Database.upsert_session_file(stale_ledger_id, "/real/file.cr", :read)

    hook_input = {"session_id" => resolved_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    result[:status].should eq(0)

    # The "stale" session must be untouched — row still present,
    # entries and files preserved.
    GalaxyLedger::Database.get_session_by_id(stale_ledger_id).should_not be_nil
    GalaxyLedger::Database.count_by_session(stale_ledger_id).should eq(1)
    GalaxyLedger::Database.session_files(stale_ledger_id).size.should eq(1)

    # The recycled PID should now point at the resolved session
    # (register_claude_pid updates the row in place on line 52 of
    # on_resume.cr).
    GalaxyLedger::Database.resolve_claude_pid(spec_runner_pid).should eq(resolved_ledger_id)
  end

  it "preserves a session older than the fresh-orphan window (guardrail)" do
    resolved_id = "resume-guardrail-age-resolved-#{Random.rand(10000)}"
    resolved_ledger_id = GalaxyLedger::Database.create_session(resolved_id)

    stale_id = "resume-guardrail-age-stale-#{Random.rand(10000)}"
    spec_runner_pid = Process.pid.to_i64
    stale_ledger_id = GalaxyLedger::Database.create_session(stale_id, claude_pid: spec_runner_pid)

    # Backdate started_at by an hour — well outside the
    # FRESH_ORPHAN_MAX_AGE_SECONDS (300s) window.
    GalaxyLedger::Database.open do |db|
      db.exec(
        "UPDATE ledger_sessions SET started_at = datetime('now', '-1 hour') WHERE id = ?",
        stale_ledger_id,
      )
    end

    hook_input = {"session_id" => resolved_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    result[:status].should eq(0)

    GalaxyLedger::Database.get_session_by_id(stale_ledger_id).should_not be_nil
    GalaxyLedger::Database.resolve_claude_pid(spec_runner_pid).should eq(resolved_ledger_id)
  end

  it "preserves a session with multiple PID registrations (guardrail)" do
    # OnStartup registers exactly one PID per orphan. Finding >1 PID
    # attached means the candidate is a real session that has seen
    # multiple processes over its lifetime.
    resolved_id = "resume-guardrail-pids-resolved-#{Random.rand(10000)}"
    resolved_ledger_id = GalaxyLedger::Database.create_session(resolved_id)

    stale_id = "resume-guardrail-pids-stale-#{Random.rand(10000)}"
    spec_runner_pid = Process.pid.to_i64
    stale_ledger_id = GalaxyLedger::Database.create_session(stale_id, claude_pid: spec_runner_pid)

    # Add a second PID to the "stale" session — simulates a real
    # session that saw multiple claude processes over time.
    GalaxyLedger::Database.register_claude_pid(stale_ledger_id, spec_runner_pid + 1_i64)

    hook_input = {"session_id" => resolved_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    result[:status].should eq(0)

    GalaxyLedger::Database.get_session_by_id(stale_ledger_id).should_not be_nil
    # The non-recycled PID stays attached to the stale session.
    GalaxyLedger::Database
      .resolve_claude_pid(spec_runner_pid + 1_i64)
      .should eq(stale_ledger_id)
    # The recycled PID moves to the resolved session.
    GalaxyLedger::Database.resolve_claude_pid(spec_runner_pid).should eq(resolved_ledger_id)
  end

  it "preserves a session with tracked files (guardrail)" do
    resolved_id = "resume-guardrail-files-resolved-#{Random.rand(10000)}"
    resolved_ledger_id = GalaxyLedger::Database.create_session(resolved_id)

    stale_id = "resume-guardrail-files-stale-#{Random.rand(10000)}"
    spec_runner_pid = Process.pid.to_i64
    stale_ledger_id = GalaxyLedger::Database.create_session(stale_id, claude_pid: spec_runner_pid)

    GalaxyLedger::Database.upsert_session_file(stale_ledger_id, "/real/work.cr", :edited)

    hook_input = {"session_id" => resolved_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    result[:status].should eq(0)

    GalaxyLedger::Database.get_session_by_id(stale_ledger_id).should_not be_nil
    GalaxyLedger::Database.session_files(stale_ledger_id).size.should eq(1)
    GalaxyLedger::Database.resolve_claude_pid(spec_runner_pid).should eq(resolved_ledger_id)
  end

  it "no-ops when PID already points to resolved session" do
    # OnStartup resolved correctly via env var, so PID → resolved session
    original_id = "resume-orphan-noop-#{Random.rand(10000)}"
    env_id = "resume-orphan-noop-env-#{Random.rand(10000)}"
    spec_runner_pid = Process.pid.to_i64
    original_ledger_id = GalaxyLedger::Database.create_session(original_id, claude_pid: spec_runner_pid)
    GalaxyLedger::Database.register_session_identifier(original_ledger_id, env_id)

    hook_input = {"session_id" => original_id}.to_json

    # Count sessions before
    sessions_before = GalaxyLedger::Database.list_sessions.size

    result = run_binary(
      ["on-resume"],
      stdin: hook_input,
      extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
    )
    result[:status].should eq(0)

    # Session count should be unchanged
    GalaxyLedger::Database.list_sessions.size.should eq(sessions_before)
  end

  it "no-ops when PID has no mapping" do
    # First-ever session, no prior PID mapping
    original_id = "resume-orphan-nopid-#{Random.rand(10000)}"
    original_ledger_id = GalaxyLedger::Database.create_session(original_id)

    hook_input = {"session_id" => original_id}.to_json

    sessions_before = GalaxyLedger::Database.list_sessions.size

    result = run_binary(["on-resume"], stdin: hook_input)
    result[:status].should eq(0)

    # Session count should be unchanged
    GalaxyLedger::Database.list_sessions.size.should eq(sessions_before)
  end
end

describe "OnResume timeline recording" do
  it "succeeds even when galaxy-timeline is unavailable" do
    test_session_id = "resume-timeline-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    result[:status].should eq(0)

    output = JSON.parse(result[:output])
    output["systemMessage"].as_s.should contain("Resumed")
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("## Galaxy Ledger")
  end

  it "does not affect restoration data output" do
    test_session_id = "resume-timeline-data-#{Random.rand(10000)}"
    ledger_id = GalaxyLedger::Database.create_session(test_session_id)

    entry = GalaxyLedger::Entry.new(
      entry_type: "learning",
      content: "Timeline test learning",
      importance: "medium",
    )
    GalaxyLedger::Database.insert(ledger_id, entry)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    result[:status].should eq(0)

    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("1 learning")
  end
end

describe "OnResume edge cases" do
  it "handles empty stdin gracefully" do
    result = run_binary(["on-resume"], stdin: "")
    result[:status].should eq(0)
    # With empty stdin, no session_id is parsed — nothing resolves → output_empty
    output = JSON.parse(result[:output])
    output["hookSpecificOutput"].should_not be_nil
  end

  it "handles malformed JSON stdin gracefully" do
    result = run_binary(["on-resume"], stdin: "not valid json")
    result[:status].should eq(0)
    output = JSON.parse(result[:output])
    output["hookSpecificOutput"].should_not be_nil
  end
end
