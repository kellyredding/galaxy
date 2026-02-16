require "../spec_helper"

describe "CLAUDE_CLI_SESSION_ID env var resolution" do
  describe "on-startup" do
    it "creates session and registers env var mapping" do
      hook_id = "env-startup-#{rand(100000)}"
      env_id = "env-durable-#{rand(100000)}"

      hook_input = {"session_id" => hook_id}.to_json

      result = run_binary(
        ["on-startup"],
        stdin: hook_input,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)

      # Session should exist with hook_id as current_session_identifier
      session = GalaxyLedger::Database.get_session(hook_id)
      session.should_not be_nil
      session.not_nil!.current_session_identifier.should eq(hook_id)

      # Both hook_id and env_id should resolve to the new session
      ledger_id_from_hook = GalaxyLedger::Database.resolve_session_identifier(hook_id)
      ledger_id_from_hook.should_not be_nil
      GalaxyLedger::Database.resolve_session_identifier(env_id).should eq(ledger_id_from_hook)
    end

    it "works normally without CLAUDE_CLI_SESSION_ID env var" do
      hook_id = "env-noenv-#{rand(100000)}"
      hook_input = {"session_id" => hook_id}.to_json

      result = run_binary(["on-startup"], stdin: hook_input)
      result[:status].should eq(0)

      session = GalaxyLedger::Database.get_session(hook_id)
      session.should_not be_nil
    end
  end

  describe "on-clear" do
    it "resolves via env var when PID does not match (resume scenario)" do
      # Create original session with env var mapping
      original_hook_id = "env-clear-orig-#{rand(100000)}"
      env_id = "env-clear-durable-#{rand(100000)}"
      original_ledger_id = GalaxyLedger::Database.create_session(original_hook_id)
      GalaxyLedger::Database.register_session_identifier(original_ledger_id, env_id)

      # Add some data so the handoff context is non-empty
      entry = GalaxyLedger::Entry.new(
        entry_type: "guideline",
        content: "Always use trailing commas",
        importance: "medium",
        source_file: "/home/user/guidelines/style.md",
      )
      GalaxyLedger::Database.insert(original_ledger_id, entry)

      # Simulate on-clear with new hook session_id but same env var
      new_hook_id = "env-clear-cleared-#{rand(100000)}"
      hook_input = {
        "session_id" => new_hook_id,
        "source"     => "clear",
      }.to_json

      result = run_binary(
        ["on-clear"],
        stdin: hook_input,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)

      # Should have resolved to original session (handoff data present)
      output = JSON.parse(result[:output])
      ctx = output["hookSpecificOutput"]["additionalContext"].as_s
      ctx.should contain("trailing commas")

      # New hook_id should map to original session
      GalaxyLedger::Database.resolve_session_identifier(new_hook_id).should eq(original_ledger_id)
    end
  end

  describe "on-compact" do
    it "resolves via env var and restores context" do
      # Create original session with env var mapping
      original_hook_id = "env-compact-orig-#{rand(100000)}"
      env_id = "env-compact-durable-#{rand(100000)}"
      original_ledger_id = GalaxyLedger::Database.create_session(original_hook_id)
      GalaxyLedger::Database.register_session_identifier(original_ledger_id, env_id)

      entry = GalaxyLedger::Entry.new(
        entry_type: "decision",
        content: "Use Crystal for CLI tools",
        importance: "high",
      )
      GalaxyLedger::Database.insert(original_ledger_id, entry)

      new_hook_id = "env-compact-new-#{rand(100000)}"
      hook_input = {
        "session_id" => new_hook_id,
        "source"     => "compact",
      }.to_json

      result = run_binary(
        ["on-compact"],
        stdin: hook_input,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)

      output = JSON.parse(result[:output])
      ctx = output["hookSpecificOutput"]["additionalContext"].as_s
      ctx.should contain("Crystal for CLI")

      GalaxyLedger::Database.resolve_session_identifier(new_hook_id).should eq(original_ledger_id)
    end
  end

  describe "on-resume" do
    it "resolves via env var and injects awareness context" do
      # Create original session with env var
      original_hook_id = "env-resume-orig-#{rand(100000)}"
      env_id = "env-resume-durable-#{rand(100000)}"
      original_ledger_id = GalaxyLedger::Database.create_session(original_hook_id)
      GalaxyLedger::Database.register_session_identifier(original_ledger_id, env_id)

      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "WAL mode improves concurrency",
        importance: "medium",
      )
      GalaxyLedger::Database.insert(original_ledger_id, entry)

      # Resume: new hook session_id, same env var
      new_hook_id = "env-resume-new-#{rand(100000)}"
      hook_input = {"session_id" => new_hook_id}.to_json

      result = run_binary(
        ["on-resume"],
        stdin: hook_input,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)

      output = JSON.parse(result[:output])
      msg = output["systemMessage"].as_s
      msg.should contain("Resumed")

      ctx = output["hookSpecificOutput"]["additionalContext"].as_s
      ctx.should contain("## Galaxy Ledger")
      ctx.should contain("resumed session")
      ctx.should contain("1 learnings")

      # New hook_id should map to original session
      GalaxyLedger::Database.resolve_session_identifier(new_hook_id).should eq(original_ledger_id)
    end
  end

  describe "on-post-tool-use" do
    it "resolves via env var and tracks file" do
      # Create session with env var mapping
      hook_id = "env-ptu-orig-#{rand(100000)}"
      env_id = "env-ptu-durable-#{rand(100000)}"
      ledger_id = GalaxyLedger::Database.create_session(hook_id)
      GalaxyLedger::Database.register_session_identifier(ledger_id, env_id)

      # Call on-post-tool-use with a different hook session_id but same env var
      new_hook_id = "env-ptu-new-#{rand(100000)}"
      input = {
        "session_id"    => new_hook_id,
        "tool_name"     => "Read",
        "tool_input"    => {"file_path" => "/path/to/file.rb"},
        "tool_response" => "file contents",
      }.to_json

      result = run_binary(
        ["on-post-tool-use"],
        stdin: input,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)

      # File should be tracked under the original session
      files = GalaxyLedger::Database.session_files(ledger_id)
      files.size.should eq(1)
      files.first.file_path.should eq("/path/to/file.rb")
    end
  end

  describe "on-stop" do
    it "resolves via env var and captures last exchange" do
      # Create session with env var mapping
      hook_id = "env-stop-orig-#{rand(100000)}"
      env_id = "env-stop-durable-#{rand(100000)}"
      ledger_id = GalaxyLedger::Database.create_session(hook_id)
      GalaxyLedger::Database.register_session_identifier(ledger_id, env_id)

      # Create transcript file
      transcript_file = File.tempfile("transcript", ".jsonl")
      transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Add auth"}}\n|)
      transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Done adding auth."}}\n|)
      transcript_file.close

      new_hook_id = "env-stop-new-#{rand(100000)}"
      hook_input = {
        "session_id"       => new_hook_id,
        "transcript_path"  => transcript_file.path,
        "stop_hook_active" => false,
      }.to_json

      result = run_binary(
        ["on-stop"],
        stdin: hook_input,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)

      # Last interaction should be saved on the original session
      session = GalaxyLedger::Database.get_session_by_id(ledger_id)
      session.not_nil!.last_interaction.should_not be_nil

      File.delete(transcript_file.path)
    end
  end

  describe "on-user-prompt-submit" do
    it "resolves via env var and stores initial message" do
      # Create session with env var mapping
      hook_id = "env-ups-orig-#{rand(100000)}"
      env_id = "env-ups-durable-#{rand(100000)}"
      ledger_id = GalaxyLedger::Database.create_session(hook_id)
      GalaxyLedger::Database.register_session_identifier(ledger_id, env_id)

      new_hook_id = "env-ups-new-#{rand(100000)}"
      input = {
        "session_id" => new_hook_id,
        "prompt"     => "Please implement the authentication feature with JWT tokens",
      }.to_json

      result = run_binary(
        ["on-user-prompt-submit"],
        stdin: input,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)

      # Initial message should be stored on the original session
      session = GalaxyLedger::Database.get_session_by_id(ledger_id)
      context = JSON.parse(session.not_nil!.context)
      context["initial_message"]?.should_not be_nil
    end
  end

  describe "full resume lifecycle" do
    it "maintains session continuity: startup → /clear → resume → /clear" do
      env_id = "env-lifecycle-#{rand(100000)}"

      # Step 1: Initial on-startup (creates session)
      hook_id_1 = "env-lc-h1-#{rand(100000)}"
      result = run_binary(
        ["on-startup"],
        stdin: {"session_id" => hook_id_1}.to_json,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)

      ledger_id = GalaxyLedger::Database.resolve_session_identifier(hook_id_1).not_nil!

      # Add some data to the session
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Learned about session continuity",
        importance: "medium",
      )
      GalaxyLedger::Database.insert(ledger_id, entry)

      # Step 2: /clear → on-clear (new hook session_id, same process)
      hook_id_2 = "env-lc-h2-#{rand(100000)}"
      result = run_binary(
        ["on-clear"],
        stdin: {"session_id" => hook_id_2, "source" => "clear"}.to_json,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)

      # Should still be the same session with the learning entry
      output = JSON.parse(result[:output])
      msg = output["systemMessage"].as_s
      msg.should contain("1 learning")

      # Step 3: Resume → on-resume (new hook session_id, same env var)
      hook_id_3 = "env-lc-h3-#{rand(100000)}"
      result = run_binary(
        ["on-resume"],
        stdin: {"session_id" => hook_id_3}.to_json,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)

      # Should resolve to same session
      output = JSON.parse(result[:output])
      msg = output["systemMessage"].as_s
      msg.should contain("Resumed")
      msg.should contain("1 learning")

      # Step 4: /clear after resume → on-clear (another new hook session_id)
      hook_id_4 = "env-lc-h4-#{rand(100000)}"
      result = run_binary(
        ["on-clear"],
        stdin: {"session_id" => hook_id_4, "source" => "clear"}.to_json,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)

      # Still the same session
      GalaxyLedger::Database.resolve_session_identifier(hook_id_4).should eq(ledger_id)

      # hook_id_2 through hook_id_4 and the env var should point to the same session
      GalaxyLedger::Database.resolve_session_identifier(hook_id_2).should eq(ledger_id)
      GalaxyLedger::Database.resolve_session_identifier(hook_id_3).should eq(ledger_id)
      GalaxyLedger::Database.resolve_session_identifier(hook_id_4).should eq(ledger_id)
      GalaxyLedger::Database.resolve_session_identifier(env_id).should eq(ledger_id)
    end
  end

  describe "resume with env var (claude-persona)" do
    it "startup before resume does not create orphan" do
      env_id = "env-resume-noorphan-#{rand(100000)}"

      # Step 1: on-startup (first time, env var not registered yet → creates)
      hook_id_1 = "env-resume-noorphan-h1-#{rand(100000)}"
      result = run_binary(
        ["on-startup"],
        stdin: {"session_id" => hook_id_1}.to_json,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)
      ledger_id = GalaxyLedger::Database.resolve_session_identifier(hook_id_1).not_nil!

      # Step 2: Exit and resume — on-startup fires again (env var now registered)
      hook_id_2 = "env-resume-noorphan-h2-#{rand(100000)}"
      result = run_binary(
        ["on-startup"],
        stdin: {"session_id" => hook_id_2}.to_json,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)

      # Should NOT have created a second session — env var resolves to original
      GalaxyLedger::Database.resolve_session_identifier(hook_id_2).should eq(ledger_id)
      GalaxyLedger::Database.list_sessions.size.should eq(1)

      # Step 3: on-resume fires
      hook_id_3 = "env-resume-noorphan-h3-#{rand(100000)}"
      result = run_binary(
        ["on-resume"],
        stdin: {"session_id" => hook_id_3}.to_json,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)

      # Still 1 session, all hook_ids registered
      GalaxyLedger::Database.list_sessions.size.should eq(1)
      GalaxyLedger::Database.resolve_session_identifier(hook_id_1).should eq(ledger_id)
      GalaxyLedger::Database.resolve_session_identifier(hook_id_2).should eq(ledger_id)
      GalaxyLedger::Database.resolve_session_identifier(hook_id_3).should eq(ledger_id)
      GalaxyLedger::Database.resolve_session_identifier(env_id).should eq(ledger_id)
    end
  end

  describe "resume without env var (no persona)" do
    it "on-resume resolves via stdin to original session" do
      # Step 1: Create original session via on-startup subprocess
      uuid_a = "env-nopersona-a-#{rand(100000)}"
      result = run_binary(
        ["on-startup"],
        stdin: {"session_id" => uuid_a}.to_json,
      )
      result[:status].should eq(0)
      original_ledger_id = GalaxyLedger::Database.resolve_session_identifier(uuid_a).not_nil!

      # Add data to verify resolution
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Data from original session",
        importance: "medium"
      )
      GalaxyLedger::Database.insert(original_ledger_id, entry)

      # Step 2: Simulate resume — on-startup fires first with new UUID-B
      uuid_b = "env-nopersona-b-#{rand(100000)}"
      result = run_binary(
        ["on-startup"],
        stdin: {"session_id" => uuid_b}.to_json,
      )
      result[:status].should eq(0)

      # Orphan should exist now (on-startup creates without env var)
      orphan_id = GalaxyLedger::Database.resolve_session_identifier(uuid_b)
      orphan_id.should_not be_nil
      orphan_id.should_not eq(original_ledger_id)

      # Step 3: on-resume fires with original UUID-A
      result = run_binary(
        ["on-resume"],
        stdin: {"session_id" => uuid_a}.to_json,
      )
      result[:status].should eq(0)

      # UUID-A should still resolve to original session
      GalaxyLedger::Database.resolve_session_identifier(uuid_a).should eq(original_ledger_id)

      # Original session should still exist
      GalaxyLedger::Database.get_session_by_id(original_ledger_id).should_not be_nil

      # on-resume should have resolved and shown the data
      output = JSON.parse(result[:output])
      msg = output["systemMessage"].as_s
      msg.should contain("Resumed")
      msg.should contain("1 learning")
    end
  end

  describe "resume lifecycle with env var" do
    it "startup → resume → clear → resume all resolve to same session" do
      env_id = "env-lc2-#{rand(100000)}"

      # Step 1: on-startup with env var (creates session first time)
      hook_id_1 = "env-lc2-h1-#{rand(100000)}"
      result = run_binary(
        ["on-startup"],
        stdin: {"session_id" => hook_id_1}.to_json,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)
      ledger_id = GalaxyLedger::Database.resolve_session_identifier(hook_id_1).not_nil!

      # Step 2: /clear
      hook_id_2 = "env-lc2-h2-#{rand(100000)}"
      result = run_binary(
        ["on-clear"],
        stdin: {"session_id" => hook_id_2, "source" => "clear"}.to_json,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)
      GalaxyLedger::Database.resolve_session_identifier(hook_id_2).should eq(ledger_id)

      # Step 3: Exit and resume (new process)
      #   a. on-startup fires (env var already registered → resolves, no orphan)
      hook_id_3 = "env-lc2-h3-#{rand(100000)}"
      result = run_binary(
        ["on-startup"],
        stdin: {"session_id" => hook_id_3}.to_json,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)
      GalaxyLedger::Database.resolve_session_identifier(hook_id_3).should eq(ledger_id)

      #   b. on-resume fires
      hook_id_4 = "env-lc2-h4-#{rand(100000)}"
      result = run_binary(
        ["on-resume"],
        stdin: {"session_id" => hook_id_4}.to_json,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)
      GalaxyLedger::Database.resolve_session_identifier(hook_id_4).should eq(ledger_id)

      # Step 4: /clear after resume
      hook_id_5 = "env-lc2-h5-#{rand(100000)}"
      result = run_binary(
        ["on-clear"],
        stdin: {"session_id" => hook_id_5, "source" => "clear"}.to_json,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)
      GalaxyLedger::Database.resolve_session_identifier(hook_id_5).should eq(ledger_id)

      # Assert: single session throughout
      GalaxyLedger::Database.list_sessions.size.should eq(1)

      # All hook IDs and env var point to same session
      [hook_id_1, hook_id_2, hook_id_3, hook_id_4, hook_id_5, env_id].each do |id|
        GalaxyLedger::Database.resolve_session_identifier(id).should eq(ledger_id)
      end
    end
  end
end
