require "../spec_helper"

# The hook that opens a turn nobody else will.
#
# Its whole job is conditional: do nothing when a turn is already
# tracked (the overwhelmingly common case, several times per assistant
# message), and open one when none is. Both halves are asserted here,
# because a hook that fired always would double-count every turn and a
# hook that fired never would leave the bug exactly as it was.
describe GalaxyLedger::Hooks::OnMessageDisplay do
  describe "GALAXY_SKIP_HOOKS" do
    it "returns early when set to 1" do
      ENV["GALAXY_SKIP_HOOKS"] = "1"
      sid = "md-skip-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(sid)

      result = run_binary(
        ["on-message-display"],
        stdin: {"session_id" => sid}.to_json,
        extra_env: {"GALAXY_SKIP_HOOKS" => "1"},
      )

      result[:status].should eq(0)
      GalaxyLedger::Hooks::TurnState.exists?(sid).should be_false
    ensure
      ENV.delete("GALAXY_SKIP_HOOKS")
    end
  end

  describe "when a turn is already tracked" do
    # The fast path. Overwriting here would orphan the running turn's
    # turn:initiated and relabel it with nothing.
    it "leaves existing turn state untouched" do
      sid = "md-existing-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(sid)
      GalaxyLedger::Hooks::TurnState.write(sid, "original-uuid", "original")

      run_binary(
        ["on-message-display"],
        stdin: {"session_id" => sid}.to_json,
      )

      state = GalaxyLedger::Hooks::TurnState.read(sid).not_nil!
      state.uuid.should eq("original-uuid")
      state.user_message.should eq("original")
    ensure
      GalaxyLedger::Hooks::TurnState.delete(sid.not_nil!) if sid
    end

    it "does not claim a stashed prompt" do
      sid = "md-nostash-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(sid)
      GalaxyLedger::Hooks::TurnState.write(sid, "uuid", "running")
      GalaxyLedger::Hooks::TurnState.write_pending(sid, "still waiting")

      run_binary(
        ["on-message-display"],
        stdin: {"session_id" => sid}.to_json,
      )

      # The stash belongs to the turn after this one.
      GalaxyLedger::Hooks::TurnState
        .take_pending(sid).should eq("still waiting")
    ensure
      if s = sid
        GalaxyLedger::Hooks::TurnState.delete(s)
        GalaxyLedger::Hooks::TurnState.delete_pending(s)
      end
    end
  end

  describe "when no turn is tracked" do
    it "opens one" do
      sid = "md-open-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(sid)

      run_binary(
        ["on-message-display"],
        stdin: {"session_id" => sid}.to_json,
      )

      GalaxyLedger::Hooks::TurnState.exists?(sid).should be_true
    ensure
      GalaxyLedger::Hooks::TurnState.delete(sid.not_nil!) if sid
    end

    # The point of the stash: the prompt was set aside at submit time
    # precisely so the turn it becomes can carry it.
    it "labels the turn with the stashed prompt" do
      sid = "md-claim-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(sid)
      GalaxyLedger::Hooks::TurnState.write_pending(sid, "queued prompt")

      run_binary(
        ["on-message-display"],
        stdin: {"session_id" => sid}.to_json,
      )

      GalaxyLedger::Hooks::TurnState.read(sid).not_nil!
        .user_message.should eq("queued prompt")
      # Claimed, not copied.
      GalaxyLedger::Hooks::TurnState.take_pending(sid).should be_nil
    ensure
      GalaxyLedger::Hooks::TurnState.delete(sid.not_nil!) if sid
    end

    # A turn with no text is still worth having: it is what makes the
    # dot pulse and the bar appear.
    it "opens a turn even with nothing stashed" do
      sid = "md-nostashopen-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(sid)

      run_binary(
        ["on-message-display"],
        stdin: {"session_id" => sid}.to_json,
      )

      GalaxyLedger::Hooks::TurnState.read(sid).not_nil!
        .user_message.should eq("")
    ensure
      GalaxyLedger::Hooks::TurnState.delete(sid.not_nil!) if sid
    end
  end

  describe "when the session cannot be resolved" do
    # No session means no ledger_session_id to record against. Writing
    # state anyway would leave a file that suppresses the real turn
    # when the session does appear.
    it "records nothing" do
      sid = "md-unknown-#{Random.rand(100000)}"

      result = run_binary(
        ["on-message-display"],
        stdin: {"session_id" => sid}.to_json,
      )

      result[:status].should eq(0)
      GalaxyLedger::Hooks::TurnState.exists?(sid).should be_false
    end
  end

  describe "malformed input" do
    it "exits cleanly with no session_id" do
      result = run_binary(
        ["on-message-display"],
        stdin: {"hook_event_name" => "MessageDisplay"}.to_json,
      )
      result[:status].should eq(0)
    end

    it "exits cleanly on unparseable stdin" do
      result = run_binary(
        ["on-message-display"],
        stdin: "not json at all",
      )
      result[:status].should eq(0)
    end
  end
end
