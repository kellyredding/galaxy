require "../spec_helper"

describe GalaxyLedger::Hooks::TurnState do
  test_session_id = "turn-state-test-#{Random.rand(100000)}"

  after_each do
    GalaxyLedger::Hooks::TurnState.delete(test_session_id)
  end

  describe ".write and .read" do
    it "round-trips uuid, user_message, and initiated_at" do
      GalaxyLedger::Hooks::TurnState.write(
        test_session_id,
        "test-uuid-123",
        "Hello, how are you?",
      )

      state = GalaxyLedger::Hooks::TurnState.read(
        test_session_id,
      )
      state.should_not be_nil
      state = state.not_nil!

      state.uuid.should eq("test-uuid-123")
      state.user_message.should eq("Hello, how are you?")
      state.initiated_at.should_not be_empty
    end

    it "generates a valid RFC3339 initiated_at timestamp" do
      GalaxyLedger::Hooks::TurnState.write(
        test_session_id,
        "uuid-ts-test",
        "test message",
      )

      state = GalaxyLedger::Hooks::TurnState.read(
        test_session_id,
      ).not_nil!

      # Should parse without error
      time = Time.parse_rfc3339(state.initiated_at)
      time.should be_a(Time)
    end
  end

  describe ".read" do
    it "returns nil when file does not exist" do
      state = GalaxyLedger::Hooks::TurnState.read(
        "nonexistent-session-id",
      )
      state.should be_nil
    end

    it "returns nil for malformed JSON" do
      path = GalaxyLedger::Hooks::TurnState.state_path(
        test_session_id,
      )
      Dir.mkdir_p(path.parent)
      File.write(path, "not valid json")

      state = GalaxyLedger::Hooks::TurnState.read(
        test_session_id,
      )
      state.should be_nil
    end

    it "returns nil for JSON missing required fields" do
      path = GalaxyLedger::Hooks::TurnState.state_path(
        test_session_id,
      )
      Dir.mkdir_p(path.parent)
      File.write(path, %({"uuid": "abc"}))

      state = GalaxyLedger::Hooks::TurnState.read(
        test_session_id,
      )
      state.should be_nil
    end
  end

  describe ".write (overwrite)" do
    it "overwrites existing state file" do
      GalaxyLedger::Hooks::TurnState.write(
        test_session_id,
        "first-uuid",
        "first message",
      )
      GalaxyLedger::Hooks::TurnState.write(
        test_session_id,
        "second-uuid",
        "second message",
      )

      state = GalaxyLedger::Hooks::TurnState.read(
        test_session_id,
      ).not_nil!

      state.uuid.should eq("second-uuid")
      state.user_message.should eq("second message")
    end
  end

  describe ".delete" do
    it "removes the state file" do
      GalaxyLedger::Hooks::TurnState.write(
        test_session_id,
        "delete-test",
        "will be deleted",
      )

      GalaxyLedger::Hooks::TurnState.exists?(
        test_session_id,
      ).should be_true

      GalaxyLedger::Hooks::TurnState.delete(test_session_id)

      GalaxyLedger::Hooks::TurnState.exists?(
        test_session_id,
      ).should be_false
    end

    it "does not raise when file does not exist" do
      GalaxyLedger::Hooks::TurnState.delete(
        "nonexistent-session-id",
      )
      # Should not raise
    end
  end

  describe ".exists?" do
    it "returns false when file does not exist" do
      GalaxyLedger::Hooks::TurnState.exists?(
        "nonexistent-session-id",
      ).should be_false
    end

    it "returns true when file exists" do
      GalaxyLedger::Hooks::TurnState.write(
        test_session_id,
        "exists-test",
        "test",
      )

      GalaxyLedger::Hooks::TurnState.exists?(
        test_session_id,
      ).should be_true
    end
  end

  describe ".close_orphan" do
    it "deletes the state file when present" do
      GalaxyLedger::Hooks::TurnState.write(
        test_session_id,
        "orphan-uuid-123",
        "orphan message",
      )

      GalaxyLedger::Hooks::TurnState.exists?(
        test_session_id,
      ).should be_true

      GalaxyLedger::Hooks::TurnState.close_orphan(
        test_session_id,
        999_i64,
      )

      GalaxyLedger::Hooks::TurnState.exists?(
        test_session_id,
      ).should be_false
    end

    it "is a no-op when no state file exists" do
      GalaxyLedger::Hooks::TurnState.exists?(
        test_session_id,
      ).should be_false

      # Should not raise
      GalaxyLedger::Hooks::TurnState.close_orphan(
        test_session_id,
        999_i64,
      )
    end

    it "does not raise when galaxy-timeline is unavailable" do
      GalaxyLedger::Hooks::TurnState.write(
        test_session_id,
        "orphan-uuid-456",
        "orphan message 2",
      )

      # Should not raise even if galaxy-timeline fails
      GalaxyLedger::Hooks::TurnState.close_orphan(
        test_session_id,
        999_i64,
      )

      # State file should still be deleted (cleanup
      # happens after the Process.run call)
      GalaxyLedger::Hooks::TurnState.exists?(
        test_session_id,
      ).should be_false
    end
  end

  describe "pending prompts" do
    pending_sid = "pending-test-#{Random.rand(100000)}"

    after_each do
      GalaxyLedger::Hooks::TurnState.delete_pending(pending_sid)
    end

    it "returns nil when nothing is set aside" do
      GalaxyLedger::Hooks::TurnState
        .take_pending(pending_sid).should be_nil
    end

    it "returns the prompt that was set aside" do
      GalaxyLedger::Hooks::TurnState.write_pending(
        pending_sid, "queued while busy",
      )

      GalaxyLedger::Hooks::TurnState
        .take_pending(pending_sid)
        .should eq("queued while busy")
    end

    # Two openers can race on one session. A prompt claimed twice
    # would label two turns with the same message.
    it "yields the prompt to one caller only" do
      GalaxyLedger::Hooks::TurnState.write_pending(
        pending_sid, "claimed once",
      )

      GalaxyLedger::Hooks::TurnState
        .take_pending(pending_sid).should eq("claimed once")
      GalaxyLedger::Hooks::TurnState
        .take_pending(pending_sid).should be_nil
    end

    it "discards without claiming" do
      GalaxyLedger::Hooks::TurnState.write_pending(
        pending_sid, "superseded",
      )
      GalaxyLedger::Hooks::TurnState.delete_pending(pending_sid)

      GalaxyLedger::Hooks::TurnState
        .take_pending(pending_sid).should be_nil
    end

    it "keeps the stash apart from turn state" do
      GalaxyLedger::Hooks::TurnState.write_pending(
        pending_sid, "set aside",
      )

      # A stashed prompt is not a turn — `exists?` must stay false or
      # the guard that reads it would think a turn were running.
      GalaxyLedger::Hooks::TurnState
        .exists?(pending_sid).should be_false
    end
  end

  describe ".claude_process?" do
    it "is false for a pid that is gone" do
      # Reaped, so the number is free — the closest thing to a
      # guaranteed-dead pid without inventing one.
      proc = Process.new("/bin/echo", args: ["-n"],
        output: Process::Redirect::Close)
      dead_pid = proc.pid.to_i64
      proc.wait

      GalaxyLedger::Hooks::TurnState
        .claude_process?(dead_pid).should be_false
    end

    # The reason the command name is checked rather than mere
    # existence: the OS recycles pids, and a dead session whose
    # number was reused would otherwise read as alive forever.
    it "is false for a live pid running something else" do
      GalaxyLedger::Hooks::TurnState
        .claude_process?(1_i64).should be_false
    end

    it "is true for a live process named claude" do
      with_fake_claude do |pid|
        GalaxyLedger::Hooks::TurnState
          .claude_process?(pid).should be_true
      end
    end
  end

  describe ".sweep_orphans" do
    it "keeps state whose identifier is current and alive" do
      with_fake_claude do |pid|
        sid = "sweep-live-#{Random.rand(100000)}"
        GalaxyLedger::Database.create_session(sid, claude_pid: pid)
        GalaxyLedger::Hooks::TurnState.write(sid, "u", "live turn")

        GalaxyLedger::Hooks::TurnState.sweep_orphans

        GalaxyLedger::Hooks::TurnState.exists?(sid).should be_true
        GalaxyLedger::Hooks::TurnState.delete(sid)
      end
    end

    # The case liveness alone gets wrong: a resume mints a new
    # identifier, so the session is alive while this file belongs to
    # an incarnation it has moved on from.
    it "sweeps state under a superseded identifier" do
      with_fake_claude do |pid|
        current = "sweep-current-#{Random.rand(100000)}"
        old = "sweep-old-#{Random.rand(100000)}"
        lsid = GalaxyLedger::Database.create_session(
          current, claude_pid: pid)
        GalaxyLedger::Database.register_session_identifier(lsid, old)
        GalaxyLedger::Hooks::TurnState.write(old, "u", "stranded")

        GalaxyLedger::Hooks::TurnState.sweep_orphans

        GalaxyLedger::Hooks::TurnState.exists?(old).should be_false
      end
    end

    it "sweeps state whose session has no live process" do
      sid = "sweep-dead-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(sid, claude_pid: 1_i64)
      GalaxyLedger::Hooks::TurnState.write(sid, "u", "dead session")

      GalaxyLedger::Hooks::TurnState.sweep_orphans

      GalaxyLedger::Hooks::TurnState.exists?(sid).should be_false
    end

    # The hole an unresolvable identifier would otherwise leave: it
    # cannot be current, so it must sweep, or it lives forever.
    it "sweeps state for an identifier it cannot resolve" do
      sid = "sweep-unknown-#{Random.rand(100000)}"
      GalaxyLedger::Hooks::TurnState.write(sid, "u", "no session")

      GalaxyLedger::Hooks::TurnState.sweep_orphans

      GalaxyLedger::Hooks::TurnState.exists?(sid).should be_false
    end

    it "discards the stashed prompt alongside the state" do
      sid = "sweep-stash-#{Random.rand(100000)}"
      GalaxyLedger::Hooks::TurnState.write(sid, "u", "orphan")
      GalaxyLedger::Hooks::TurnState.write_pending(sid, "orphaned too")

      GalaxyLedger::Hooks::TurnState.sweep_orphans

      GalaxyLedger::Hooks::TurnState.exists?(sid).should be_false
      GalaxyLedger::Hooks::TurnState.take_pending(sid).should be_nil
    end
  end

  describe ".dir" do
    it "creates the directory if it does not exist" do
      dir = GalaxyLedger::Hooks::TurnState.dir
      Dir.exists?(dir).should be_true
    end

    it "returns a path under GALAXY_DIR" do
      dir = GalaxyLedger::Hooks::TurnState.dir
      dir.to_s.should contain("galaxy")
      dir.to_s.should contain("turn-state")
    end
  end
end
