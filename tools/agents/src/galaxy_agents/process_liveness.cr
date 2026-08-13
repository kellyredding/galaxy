module GalaxyAgents
  # Whether the process that owned an agent is still running.
  #
  # A row is only sweepable when its owner is provably gone, so
  # every question here is deliberately conservative: anything
  # unknown answers "alive" and leaves the row untouched. An
  # over-eager sweep marks a live agent abandoned, and that damage
  # is permanent — `stop_agent` will not move a terminal row back.
  module ProcessLiveness
    # The command name a Claude Code session runs as. A pid alone
    # is not evidence: the OS recycles them, so an unrelated
    # process can inherit the number an agent was started under.
    CLAUDE_COMMAND = "claude"

    # Overridable because getting this wrong is expensive in one
    # direction: a session running under a wrapper or a renamed
    # binary would fail every name check, and reconcile would
    # sweep agents that are running perfectly well. One variable
    # is cheaper than discovering that a day later.
    def self.claude_command : String
      ENV.fetch("GALAXY_AGENTS_CLAUDE_COMMAND", CLAUDE_COMMAND)
    end

    # Is `pid` a live Claude Code process?
    def self.claude_alive?(
      pid : Int64?,
      expected : String = claude_command,
    ) : Bool
      return false if pid.nil?
      return false if pid <= 0
      return false unless exists?(pid)

      # The pid is live. Only a positive identification as some
      # OTHER command proves recycling — an unreadable name is
      # not evidence of anything and must leave the row alone.
      case name = command_name(pid)
      when nil      then true
      when expected then true
      else               false
      end
    end

    # Does any process hold this pid?
    #
    # `Process.exists?` is the right primitive rather than a raw
    # `kill(pid, 0)`: a bare kill fails with EPERM for a process
    # owned by another user, and reading that as "gone" would
    # sweep agents that are very much alive. Verified against pid
    # 1, which answers true.
    def self.exists?(pid : Int64) : Bool
      Process.exists?(pid.to_i)
    rescue
      # Unable to ask ⇒ unable to prove death.
      true
    end

    # The executable name for `pid`, or nil when it cannot be read.
    #
    # nil is not "not claude" — the caller must not sweep on it.
    # It is returned distinctly so a future caller cannot mistake
    # a failed lookup for a definite answer.
    def self.command_name(pid : Int64) : String?
      output = IO::Memory.new
      status = Process.run(
        "ps",
        args: ["-p", pid.to_s, "-o", "comm="],
        output: output,
        error: Process::Redirect::Close,
      )
      return nil unless status.success?

      name = output.to_s.strip
      return nil if name.empty?

      File.basename(name)
    rescue
      nil
    end
  end
end
