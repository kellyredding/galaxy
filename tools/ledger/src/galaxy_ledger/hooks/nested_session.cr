module GalaxyLedger
  module Hooks
    # Whether the `claude` that fired a hook is running inside a session the
    # ledger already tracks — a plugin hook's `claude -p`, an agent shelling
    # out to one.
    #
    # Such a process inherits the outer session's CLAUDE_CLI_SESSION_ID, which
    # OnStartup would read as a resume: the child's identifier and pid would
    # join the outer session, its prompt would open a turn that abandons the
    # outer session's live one, and its exit would record session:ended there.
    module NestedSession
      MAX_DEPTH = 32

      record ProcessInfo, ppid : Int64, comm : String

      # Swappable so specs can describe a process tree without building one.
      class_property lookup : Proc(Int64, ProcessInfo?) = ->(pid : Int64) { NestedSession.process_info(pid) }
      class_property tracked : Proc(Int64, Bool) = ->(pid : Int64) { !Database.resolve_claude_pid(pid).nil? }

      def self.nested?(claude_pid : Int64 = Process.ppid.to_i64) : Bool
        # Every hook after a session's first lands here, so this is the path
        # that has to stay cheap: one lookup, no process walk.
        return false if tracked.call(claude_pid)

        info = lookup.call(claude_pid)
        return false unless info

        MAX_DEPTH.times do
          pid = info.ppid
          return false if pid <= 1

          info = lookup.call(pid)
          return false unless info
          return true if claude?(info.comm) && tracked.call(pid)
        end

        false
      end

      # Exact, not a substring: every Claude Persona session runs under a
      # `claude-persona` parent, which a substring match would count as an
      # outer session and stop tracking.
      def self.claude?(comm : String) : Bool
        File.basename(comm) == "claude"
      end

      # `comm` is whatever path the process was executed by, so it can be a
      # bare name or a full path.
      def self.process_info(pid : Int64) : ProcessInfo?
        output = IO::Memory.new
        status = Process.run(
          "ps",
          args: ["-o", "ppid=,comm=", "-p", pid.to_s],
          output: output,
          error: Process::Redirect::Close,
        )
        return nil unless status.success?

        ppid_text, _, comm = output.to_s.strip.partition(/\s+/)
        ppid = ppid_text.to_i64?
        return nil unless ppid
        ProcessInfo.new(ppid, comm.strip)
      rescue
        nil
      end
    end
  end
end
