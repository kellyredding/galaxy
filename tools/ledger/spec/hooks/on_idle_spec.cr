require "../spec_helper"

private def idle_input(sid : String, kind = "idle_prompt") : String
  {"session_id" => sid, "notification_type" => kind}.to_json
end

# A tracked turn whose start is `age` in the past.
private def write_aged_turn(sid : String, uuid : String, age : Time::Span)
  path = GalaxyLedger::Hooks::TurnState.state_path(sid)
  Dir.mkdir_p(path.parent)
  File.write(path, {
    "uuid"         => uuid,
    "user_message" => "an old turn",
    "initiated_at" => (Time.utc - age).to_rfc3339,
  }.to_json)
end

# The idle report as a turn end. An agent waiting for input is running
# no turn, so one still tracked here is stale — the phantom left by a
# notification answered inside the turn before it, or an abort Galaxy
# never saw.
describe GalaxyLedger::Hooks::OnIdle do
  describe "a turn still tracked" do
    it "closes one older than the idle threshold" do
      sid = "idle-stale-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(sid)
      write_aged_turn(sid, "stale-uuid", 5.minutes)
      flush_wal_for(sid)

      result = run_binary(["on-idle"], stdin: idle_input(sid))
      result[:status].should eq(0)

      GalaxyLedger::Hooks::TurnState.exists?(sid).should be_false
    ensure
      GalaxyLedger::Hooks::TurnState.delete(sid.not_nil!) if sid
    end

    it "records the close as abandoned, under its own source" do
      with_recorded_timeline do |log|
        sid = "idle-source-#{Random.rand(100000)}"
        GalaxyLedger::Database.create_session(sid)
        write_aged_turn(sid, "stale-uuid", 5.minutes)
        flush_wal_for(sid)

        run_binary(["on-idle"], stdin: idle_input(sid))

        recorded = File.read(log)
        recorded.should contain("turn:abandoned")
        recorded.should contain("--source galaxy-ledger/idle")
        recorded.should contain("turn--stale-uuid")
      end
    end

    # Whatever was set aside behind a stale turn is not waiting either:
    # an idle agent has nothing queued.
    it "discards a prompt set aside behind it" do
      sid = "idle-stash-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(sid)
      write_aged_turn(sid, "stale-uuid", 5.minutes)
      GalaxyLedger::Hooks::TurnState.write_pending(sid, "behind the phantom")
      flush_wal_for(sid)

      run_binary(["on-idle"], stdin: idle_input(sid))

      GalaxyLedger::Hooks::TurnState.take_pending(sid).should be_nil
    ensure
      if s = sid
        GalaxyLedger::Hooks::TurnState.delete(s)
        GalaxyLedger::Hooks::TurnState.delete_pending(s)
      end
    end

    # Idleness is reported a threshold after the agent stops, so a turn
    # younger than that began afterwards — something woke the agent as
    # the report was on its way.
    it "leaves one younger than the idle threshold" do
      sid = "idle-fresh-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(sid)
      write_aged_turn(sid, "fresh-uuid", 5.seconds)
      flush_wal_for(sid)

      run_binary(["on-idle"], stdin: idle_input(sid))

      GalaxyLedger::Hooks::TurnState.read(sid).not_nil!
        .uuid.should eq("fresh-uuid")
    ensure
      GalaxyLedger::Hooks::TurnState.delete(sid.not_nil!) if sid
    end
  end

  # A permission prompt is the agent mid-turn waiting on the user — the
  # opposite of idle. Closing a turn on one would end a live turn.
  it "leaves a turn alone for a notification that is not idle_prompt" do
    sid = "idle-permission-#{Random.rand(100000)}"
    GalaxyLedger::Database.create_session(sid)
    write_aged_turn(sid, "live-uuid", 5.minutes)
    flush_wal_for(sid)

    run_binary(["on-idle"], stdin: idle_input(sid, "permission_prompt"))

    GalaxyLedger::Hooks::TurnState.exists?(sid).should be_true
  ensure
    GalaxyLedger::Hooks::TurnState.delete(sid.not_nil!) if sid
  end

  it "exits cleanly with no turn tracked" do
    sid = "idle-none-#{Random.rand(100000)}"
    GalaxyLedger::Database.create_session(sid)
    flush_wal_for(sid)

    result = run_binary(["on-idle"], stdin: idle_input(sid))
    result[:status].should eq(0)
    GalaxyLedger::Hooks::TurnState.exists?(sid).should be_false
  end
end
