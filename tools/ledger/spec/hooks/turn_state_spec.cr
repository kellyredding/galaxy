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
