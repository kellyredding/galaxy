require "../spec_helper"

# The opener Galaxy.app reaches for the moment a turn is interrupted.
#
# No Stop hook fires on that path — measured — so without this the
# queued message's turn has no start until the agent produces its first
# line of text, seventeen seconds later in the sample that prompted it.
describe "CLI Integration: open-queued-turn" do
  describe "help" do
    it "shows help with --help flag" do
      result = run_binary(["open-queued-turn", "--help"])
      result[:output].should contain(
        "galaxy-ledger open-queued-turn",
      )
      result[:output].should contain("--session")
      result[:output].should contain("--source")
      result[:status].should eq(0)
    end

    it "shows help with -h flag" do
      result = run_binary(["open-queued-turn", "-h"])
      result[:output].should contain(
        "galaxy-ledger open-queued-turn",
      )
      result[:status].should eq(0)
    end
  end

  describe "flag validation" do
    it "errors when --session is missing" do
      result = run_binary(["open-queued-turn"])
      result[:error].should contain("--session is required")
      result[:status].should_not eq(0)
    end

    it "errors when --session resolves to no session" do
      result = run_binary(
        ["open-queued-turn", "--session", "nonexistent-id"],
      )
      result[:error].should contain("no session found")
      result[:status].should_not eq(0)
    end
  end

  describe "opening a turn" do
    it "opens the turn the stashed prompt becomes" do
      sid = "oqt-open-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(sid)
      GalaxyLedger::Hooks::TurnState.write_pending(sid, "Yep.")
      flush_wal_for(sid)

      with_queue_transcript([{"enqueue", "Yep."}]) do |t|
        result = run_binary([
          "open-queued-turn", "--session", sid,
          "--transcript-path", t,
        ])
        result[:status].should eq(0)
      end

      GalaxyLedger::Hooks::TurnState.read(sid).not_nil!
        .user_message.should eq("Yep.")
      GalaxyLedger::Hooks::TurnState
        .take_pending(sid).should be_nil
    ensure
      if s = sid
        GalaxyLedger::Hooks::TurnState.delete(s)
        GalaxyLedger::Hooks::TurnState.delete_pending(s)
      end
    end

    # Esc after a message was folded into the turn being interrupted.
    # The app cannot tell the two apart, which is the whole reason the
    # transcript is consulted here rather than trusted to the caller.
    it "opens nothing for a message the turn absorbed" do
      sid = "oqt-absorbed-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(sid)
      GalaxyLedger::Hooks::TurnState.write_pending(sid, "never mind")
      flush_wal_for(sid)

      with_queue_transcript([
        {"enqueue", "never mind"},
        {"remove", "never mind"},
      ]) do |t|
        result = run_binary([
          "open-queued-turn", "--session", sid,
          "--transcript-path", t,
        ])
        result[:status].should eq(0)
      end

      GalaxyLedger::Hooks::TurnState.exists?(sid).should be_false
      GalaxyLedger::Hooks::TurnState.take_pending(sid).should be_nil
    ensure
      if s = sid
        GalaxyLedger::Hooks::TurnState.delete(s)
        GalaxyLedger::Hooks::TurnState.delete_pending(s)
      end
    end

    # Esc with nothing queued is the ordinary case, and the app calls
    # this on every interrupt rather than deciding for itself.
    it "opens nothing when no prompt is set aside" do
      sid = "oqt-empty-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(sid)
      flush_wal_for(sid)

      with_queue_transcript([] of Tuple(String, String)) do |t|
        result = run_binary([
          "open-queued-turn", "--session", sid,
          "--transcript-path", t,
        ])
        result[:status].should eq(0)
      end

      GalaxyLedger::Hooks::TurnState.exists?(sid).should be_false
    ensure
      GalaxyLedger::Hooks::TurnState.delete(sid.not_nil!) if sid
    end

    it "leaves a turn that is already tracked alone" do
      sid = "oqt-tracked-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(sid)
      GalaxyLedger::Hooks::TurnState.write(sid, "live-uuid", "running")
      GalaxyLedger::Hooks::TurnState.write_pending(sid, "still waiting")
      flush_wal_for(sid)

      with_queue_transcript([{"enqueue", "still waiting"}]) do |t|
        result = run_binary([
          "open-queued-turn", "--session", sid,
          "--transcript-path", t,
        ])
        result[:status].should eq(0)
      end

      GalaxyLedger::Hooks::TurnState.read(sid).not_nil!
        .uuid.should eq("live-uuid")
      GalaxyLedger::Hooks::TurnState
        .take_pending(sid).should eq("still waiting")
    ensure
      if s = sid
        GalaxyLedger::Hooks::TurnState.delete(s)
        GalaxyLedger::Hooks::TurnState.delete_pending(s)
      end
    end

    # The source names what triggered the open, which is how the
    # interrupt path can be told from the others in the timeline.
    it "records the source the caller names" do
      with_recorded_timeline do |log|
        sid = "oqt-source-#{Random.rand(100000)}"
        GalaxyLedger::Database.create_session(sid)
        GalaxyLedger::Hooks::TurnState.write_pending(sid, "Yep.")
        flush_wal_for(sid)

        with_queue_transcript([{"enqueue", "Yep."}]) do |t|
          run_binary([
            "open-queued-turn", "--session", sid,
            "--transcript-path", t,
            "--source", "galaxy-app/interrupt",
          ])
        end

        recorded = File.read(log)
        recorded.should contain("turn:initiated")
        recorded.should contain("--source galaxy-app/interrupt")

        GalaxyLedger::Hooks::TurnState.delete(sid)
      end
    end
  end
end
