module GalaxyLedger
  module Hooks
    # Shared 3-tier session resolution and mapping registration.
    #
    # Resolution order:
    #   1. PID (Process.ppid) → resolve_claude_pid
    #   2. CLAUDE_CLI_SESSION_ID env var → resolve_session_identifier
    #   3. Hook's stdin session_id → resolve_session_identifier
    #
    # After resolving (or creating), registers mappings for all available
    # inputs so future lookups from any tier succeed.
    module Resolver
      # Environment variable name for the durable session identity
      # set by Claude Persona via Claude Code's settings env mechanism.
      ENV_SESSION_ID_KEY = "CLAUDE_CLI_SESSION_ID"

      # Resolve to an existing ledger_session_id, optionally creating a new
      # session as a last resort.
      #
      # - create_if_missing: when true (on_startup, on_session_start), creates
      #   a new session if all resolution tiers fail.
      # - cwd: passed to create_session when creating.
      #
      # Returns nil if nothing resolves and create_if_missing is false.
      def self.resolve_session(
        claude_pid : Int64,
        env_session_id : String? = nil,
        stdin_session_id : String? = nil,
        create_if_missing : Bool = false,
        cwd : String? = nil,
      ) : Int64?
        # 1. PID
        ledger_session_id = Database.resolve_claude_pid(claude_pid)

        # 2. Env var (CLAUDE_CLI_SESSION_ID)
        unless ledger_session_id
          if env_id = env_session_id
            ledger_session_id = Database.resolve_session_identifier(env_id) unless env_id.empty?
          end
        end

        # 3. Hook session_id
        unless ledger_session_id
          if sid = stdin_session_id
            ledger_session_id = Database.resolve_session_identifier(sid) unless sid.empty?
          end
        end

        # 4. Create if requested (on_startup, on_session_start)
        if create_if_missing && !ledger_session_id
          current_session_id = stdin_session_id
          if current_session_id && !current_session_id.empty?
            ledger_session_id = Database.create_session(
              current_session_id,
              claude_pid: claude_pid,
              cwd: cwd,
            )
          end
        end

        # Register all available mappings.
        # create_session already registers the hook session_id and PID internally;
        # the subsequent register_* calls are harmless (INSERT OR IGNORE/REPLACE).
        # The env var registration is the net-new mapping create_session doesn't know about.
        if lid = ledger_session_id
          if lid > 0
            Database.register_claude_pid(lid, claude_pid)
            if env_id = env_session_id
              Database.register_session_identifier(lid, env_id) unless env_id.empty?
            end
            if sid = stdin_session_id
              Database.register_session_identifier(lid, sid) unless sid.empty?
            end
          end
        end

        ledger_session_id
      end
    end
  end
end
