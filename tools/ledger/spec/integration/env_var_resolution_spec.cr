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

      # Env var should resolve to the same session
      ledger_id_from_env = GalaxyLedger::Database.resolve_session_identifier(env_id)
      ledger_id_from_hook = GalaxyLedger::Database.resolve_session_identifier(hook_id)
      ledger_id_from_env.should_not be_nil
      ledger_id_from_env.should eq(ledger_id_from_hook)
    end

    it "resolves existing session via env var on resume (new hook session_id)" do
      # Simulate initial session
      original_hook_id = "env-resume-orig-#{rand(100000)}"
      env_id = "env-resume-durable-#{rand(100000)}"
      original_ledger_id = GalaxyLedger::Database.create_session(original_hook_id)
      GalaxyLedger::Database.register_session_identifier(original_ledger_id, env_id)

      # Simulate resume: new hook session_id, same env var
      resumed_hook_id = "env-resume-forked-#{rand(100000)}"
      hook_input = {"session_id" => resumed_hook_id}.to_json

      result = run_binary(
        ["on-startup"],
        stdin: hook_input,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)

      # Should have resolved to the original session (not created a new one)
      resumed_ledger_id = GalaxyLedger::Database.resolve_session_identifier(resumed_hook_id)
      resumed_ledger_id.should eq(original_ledger_id)

      # current_session_identifier should be updated to the new hook_id
      session = GalaxyLedger::Database.get_session_by_id(original_ledger_id)
      session.not_nil!.current_session_identifier.should eq(resumed_hook_id)
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

  describe "on-session-start" do
    it "resolves via env var when PID does not match (resume scenario)" do
      # Create original session with env var mapping
      original_hook_id = "env-ss-orig-#{rand(100000)}"
      env_id = "env-ss-durable-#{rand(100000)}"
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

      # Simulate on-session-start with new hook session_id but same env var
      new_hook_id = "env-ss-cleared-#{rand(100000)}"
      hook_input = {
        "session_id" => new_hook_id,
        "source"     => "clear",
      }.to_json

      result = run_binary(
        ["on-session-start"],
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

      # Step 2: /clear → on-session-start (new hook session_id, same process)
      hook_id_2 = "env-lc-h2-#{rand(100000)}"
      result = run_binary(
        ["on-session-start"],
        stdin: {"session_id" => hook_id_2, "source" => "clear"}.to_json,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)

      # Should still be the same session with the learning entry
      output = JSON.parse(result[:output])
      msg = output["systemMessage"].as_s
      msg.should contain("1 learning")

      # Step 3: Resume → on-startup (new hook session_id, same env var)
      hook_id_3 = "env-lc-h3-#{rand(100000)}"
      result = run_binary(
        ["on-startup"],
        stdin: {"session_id" => hook_id_3}.to_json,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)

      # Should resolve to same session (shows data counts in systemMessage)
      output = JSON.parse(result[:output])
      msg = output["systemMessage"].as_s
      msg.should contain("1 learning")

      # Step 4: /clear after resume → on-session-start (another new hook session_id)
      hook_id_4 = "env-lc-h4-#{rand(100000)}"
      result = run_binary(
        ["on-session-start"],
        stdin: {"session_id" => hook_id_4, "source" => "clear"}.to_json,
        extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
      )
      result[:status].should eq(0)

      # Still the same session
      GalaxyLedger::Database.resolve_session_identifier(hook_id_4).should eq(ledger_id)

      # All four hook IDs and the env var should point to the same session
      GalaxyLedger::Database.resolve_session_identifier(hook_id_1).should eq(ledger_id)
      GalaxyLedger::Database.resolve_session_identifier(hook_id_2).should eq(ledger_id)
      GalaxyLedger::Database.resolve_session_identifier(hook_id_3).should eq(ledger_id)
      GalaxyLedger::Database.resolve_session_identifier(hook_id_4).should eq(ledger_id)
      GalaxyLedger::Database.resolve_session_identifier(env_id).should eq(ledger_id)
    end
  end
end
