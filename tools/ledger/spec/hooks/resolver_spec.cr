require "../spec_helper"

describe GalaxyLedger::Hooks::Resolver do
  describe ".resolve_session" do
    describe "resolution tiers" do
      it "resolves by env var (tier 1)" do
        session_id = "resolver-env-#{rand(100000)}"
        ledger_id = GalaxyLedger::Database.create_session(session_id)
        # Register env var mapping
        GalaxyLedger::Database.register_session_identifier(ledger_id, "env-durable-#{session_id}")

        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 99999_i64, # unregistered PID
          env_session_id: "env-durable-#{session_id}",
          stdin_session_id: "different-hook-id",
        )

        result.should eq(ledger_id)
      end

      it "resolves env var before PID when both match different sessions" do
        # Session A: registered with env var
        session_a_id = "resolver-tier-a-#{rand(100000)}"
        env_id = "resolver-tier-env-#{rand(100000)}"
        ledger_a = GalaxyLedger::Database.create_session(session_a_id)
        GalaxyLedger::Database.register_session_identifier(ledger_a, env_id)

        # Session B: registered with PID (stale)
        session_b_id = "resolver-tier-b-#{rand(100000)}"
        ledger_b = GalaxyLedger::Database.create_session(session_b_id, claude_pid: 50000_i64)

        # Resolve: env var should win over PID
        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 50000_i64,
          env_session_id: env_id,
          stdin_session_id: "some-hook-id",
        )

        result.should eq(ledger_a)
      end

      it "resolves by PID (tier 2) when env var fails" do
        session_id = "resolver-pid-#{rand(100000)}"
        ledger_id = GalaxyLedger::Database.create_session(session_id, claude_pid: 12345_i64)

        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 12345_i64,
          env_session_id: "no-match-env-id",
          stdin_session_id: "different-hook-id",
        )

        result.should eq(ledger_id)
      end

      it "resolves by hook session_id (tier 3) when env var and PID fail" do
        session_id = "resolver-hook-#{rand(100000)}"
        ledger_id = GalaxyLedger::Database.create_session(session_id)

        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 99999_i64, # unregistered PID
          env_session_id: "no-match-env-id",
          stdin_session_id: session_id,
        )

        result.should eq(ledger_id)
      end

      it "returns nil when all tiers fail and create_if_missing is false" do
        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 99999_i64,
          env_session_id: "no-match",
          stdin_session_id: "also-no-match",
          create_if_missing: false,
        )

        result.should be_nil
      end
    end

    describe "create_if_missing" do
      it "creates a new session when all tiers fail" do
        hook_session_id = "resolver-create-#{rand(100000)}"

        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 88888_i64,
          env_session_id: "env-for-create",
          stdin_session_id: hook_session_id,
          create_if_missing: true,
          cwd: "/tmp/test",
        )

        result.should_not be_nil
        result.not_nil!.should be > 0

        # Verify the session was created with the hook session_id as current
        session = GalaxyLedger::Database.get_session_by_id(result.not_nil!)
        session.should_not be_nil
        session.not_nil!.current_session_identifier.should eq(hook_session_id)
      end

      it "uses hook session_id (not env var) as current_session_identifier" do
        hook_session_id = "resolver-current-#{rand(100000)}"
        env_id = "resolver-env-durable-#{rand(100000)}"

        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 77777_i64,
          env_session_id: env_id,
          stdin_session_id: hook_session_id,
          create_if_missing: true,
          cwd: "/tmp/test",
        )

        session = GalaxyLedger::Database.get_session_by_id(result.not_nil!)
        session.not_nil!.current_session_identifier.should eq(hook_session_id)
      end

      it "does not create when stdin_session_id is nil" do
        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 66666_i64,
          env_session_id: "env-only",
          stdin_session_id: nil,
          create_if_missing: true,
        )

        result.should be_nil
      end

      it "does not create when stdin_session_id is empty" do
        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 55555_i64,
          env_session_id: "env-only",
          stdin_session_id: "",
          create_if_missing: true,
        )

        result.should be_nil
      end
    end

    describe "mapping registration" do
      it "registers all three mappings after env var resolution" do
        session_id = "resolver-reg-env-#{rand(100000)}"
        env_id = session_id # env var matches the original session_id
        hook_id = "resolver-reg-hook-#{rand(100000)}"
        ledger_id = GalaxyLedger::Database.create_session(session_id)

        GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 33333_i64, # new PID
          env_session_id: env_id,
          stdin_session_id: hook_id,
        )

        # New PID should be registered
        GalaxyLedger::Database.resolve_claude_pid(33333_i64).should eq(ledger_id)
        # Hook session_id should be registered
        GalaxyLedger::Database.resolve_session_identifier(hook_id).should eq(ledger_id)
      end

      it "registers all three mappings after PID resolution" do
        session_id = "resolver-reg-pid-#{rand(100000)}"
        env_id = "resolver-reg-env-#{rand(100000)}"
        hook_id = "resolver-reg-hook-#{rand(100000)}"
        ledger_id = GalaxyLedger::Database.create_session(session_id, claude_pid: 44444_i64)

        GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 44444_i64,
          env_session_id: env_id,
          stdin_session_id: hook_id,
        )

        # Env var should now be registered
        GalaxyLedger::Database.resolve_session_identifier(env_id).should eq(ledger_id)
        # Hook session_id should be registered
        GalaxyLedger::Database.resolve_session_identifier(hook_id).should eq(ledger_id)
        # PID still resolves
        GalaxyLedger::Database.resolve_claude_pid(44444_i64).should eq(ledger_id)
      end

      it "registers all three mappings after creation" do
        env_id = "resolver-reg3-env-#{rand(100000)}"
        hook_id = "resolver-reg3-hook-#{rand(100000)}"

        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 22222_i64,
          env_session_id: env_id,
          stdin_session_id: hook_id,
          create_if_missing: true,
          cwd: "/tmp/test",
        )

        ledger_id = result.not_nil!

        # All three should resolve
        GalaxyLedger::Database.resolve_claude_pid(22222_i64).should eq(ledger_id)
        GalaxyLedger::Database.resolve_session_identifier(env_id).should eq(ledger_id)
        GalaxyLedger::Database.resolve_session_identifier(hook_id).should eq(ledger_id)
      end
    end

    describe "stale PID cleanup" do
      it "re-registers PID to env var's session when PID was stale" do
        # Session A: correct session, registered with env var
        session_a_id = "stale-cleanup-a-#{rand(100000)}"
        env_id = "stale-cleanup-env-#{rand(100000)}"
        ledger_a = GalaxyLedger::Database.create_session(session_a_id)
        GalaxyLedger::Database.register_session_identifier(ledger_a, env_id)

        # Session B: stale session, registered with PID 50000
        session_b_id = "stale-cleanup-b-#{rand(100000)}"
        GalaxyLedger::Database.create_session(session_b_id, claude_pid: 50000_i64)

        # Resolve: env var should win, PID should be remapped to session A
        GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 50000_i64,
          env_session_id: env_id,
          stdin_session_id: "some-hook-id",
        )

        # PID should now map to session A (not B)
        GalaxyLedger::Database.resolve_claude_pid(50000_i64).should eq(ledger_a)
      end
    end

    describe "env var edge cases" do
      it "skips env var when nil" do
        session_id = "resolver-noenv-#{rand(100000)}"
        ledger_id = GalaxyLedger::Database.create_session(session_id)

        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 99999_i64,
          env_session_id: nil,
          stdin_session_id: session_id,
        )

        result.should eq(ledger_id)
      end

      it "skips env var when empty string" do
        session_id = "resolver-emptyenv-#{rand(100000)}"
        ledger_id = GalaxyLedger::Database.create_session(session_id)

        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 99999_i64,
          env_session_id: "",
          stdin_session_id: session_id,
        )

        result.should eq(ledger_id)
      end

      it "does not register env var mapping when env var is nil" do
        hook_id = "resolver-nilenv-#{rand(100000)}"

        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 11111_i64,
          env_session_id: nil,
          stdin_session_id: hook_id,
          create_if_missing: true,
          cwd: "/tmp/test",
        )

        ledger_id = result.not_nil!

        # PID and hook_id should resolve, but there's no env var to check
        GalaxyLedger::Database.resolve_claude_pid(11111_i64).should eq(ledger_id)
        GalaxyLedger::Database.resolve_session_identifier(hook_id).should eq(ledger_id)
      end
    end

    describe "resume continuity scenario" do
      it "maintains session continuity across resume (new PID, new hook session_id, same env var)" do
        # Initial session
        original_hook_id = "resume-original-#{rand(100000)}"
        env_id = "resume-durable-#{rand(100000)}"

        original_ledger_id = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 10001_i64,
          env_session_id: env_id,
          stdin_session_id: original_hook_id,
          create_if_missing: true,
          cwd: "/tmp/test",
        )
        original_ledger_id.should_not be_nil

        # Resume: new PID, new hook session_id, same env var
        resumed_hook_id = "resume-forked-#{rand(100000)}"

        resumed_ledger_id = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 10002_i64,             # new process
          env_session_id: env_id,            # same durable identity
          stdin_session_id: resumed_hook_id, # Claude forked to new UUID
          create_if_missing: true,
          cwd: "/tmp/test",
        )

        # Should resolve to the SAME session
        resumed_ledger_id.should eq(original_ledger_id)

        # New PID and new hook session_id should now map to the same session
        GalaxyLedger::Database.resolve_claude_pid(10002_i64).should eq(original_ledger_id)
        GalaxyLedger::Database.resolve_session_identifier(resumed_hook_id).should eq(original_ledger_id)
      end

      it "maintains continuity across resume + /clear" do
        env_id = "resume-clear-durable-#{rand(100000)}"
        hook_id_1 = "resume-clear-h1-#{rand(100000)}"
        pid_1 = 20001_i64

        # Initial session
        ledger_id = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: pid_1,
          env_session_id: env_id,
          stdin_session_id: hook_id_1,
          create_if_missing: true,
          cwd: "/tmp/test",
        ).not_nil!

        # /clear: same PID, new hook session_id
        hook_id_2 = "resume-clear-h2-#{rand(100000)}"
        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: pid_1,
          env_session_id: env_id,
          stdin_session_id: hook_id_2,
        )
        result.should eq(ledger_id)

        # Resume: new PID, new hook session_id, same env var
        pid_2 = 20002_i64
        hook_id_3 = "resume-clear-h3-#{rand(100000)}"
        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: pid_2,
          env_session_id: env_id,
          stdin_session_id: hook_id_3,
          create_if_missing: true,
          cwd: "/tmp/test",
        )
        result.should eq(ledger_id)

        # /clear in resumed session: same PID (pid_2), new hook session_id
        hook_id_4 = "resume-clear-h4-#{rand(100000)}"
        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: pid_2,
          env_session_id: env_id,
          stdin_session_id: hook_id_4,
        )
        result.should eq(ledger_id)

        # All four hook IDs, both PIDs, and env var should resolve to the same session
        GalaxyLedger::Database.resolve_session_identifier(hook_id_1).should eq(ledger_id)
        GalaxyLedger::Database.resolve_session_identifier(hook_id_2).should eq(ledger_id)
        GalaxyLedger::Database.resolve_session_identifier(hook_id_3).should eq(ledger_id)
        GalaxyLedger::Database.resolve_session_identifier(hook_id_4).should eq(ledger_id)
        GalaxyLedger::Database.resolve_session_identifier(env_id).should eq(ledger_id)
        GalaxyLedger::Database.resolve_claude_pid(pid_1).should eq(ledger_id)
        GalaxyLedger::Database.resolve_claude_pid(pid_2).should eq(ledger_id)
      end
    end

    describe "no env var scenario (no claude-persona)" do
      it "behaves like 2-tier resolution when env var is nil" do
        session_id = "no-persona-#{rand(100000)}"
        ledger_id = GalaxyLedger::Database.create_session(session_id, claude_pid: 30001_i64)

        # PID resolves
        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 30001_i64,
          env_session_id: nil,
          stdin_session_id: "some-hook-id",
        )
        result.should eq(ledger_id)
      end

      it "falls through to hook session_id when env var is nil and PID fails" do
        session_id = "no-persona-fallback-#{rand(100000)}"
        ledger_id = GalaxyLedger::Database.create_session(session_id)

        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 99999_i64,
          env_session_id: nil,
          stdin_session_id: session_id,
        )
        result.should eq(ledger_id)
      end

      it "creates session when env var is nil and nothing resolves" do
        hook_id = "no-persona-create-#{rand(100000)}"

        result = GalaxyLedger::Hooks::Resolver.resolve_session(
          claude_pid: 40001_i64,
          env_session_id: nil,
          stdin_session_id: hook_id,
          create_if_missing: true,
          cwd: "/tmp/test",
        )

        result.should_not be_nil
        result.not_nil!.should be > 0

        session = GalaxyLedger::Database.get_session_by_id(result.not_nil!)
        session.not_nil!.current_session_identifier.should eq(hook_id)
      end
    end
  end

  describe "ENV_SESSION_ID_KEY" do
    it "is CLAUDE_CLI_SESSION_ID" do
      GalaxyLedger::Hooks::Resolver::ENV_SESSION_ID_KEY.should eq("CLAUDE_CLI_SESSION_ID")
    end
  end
end
