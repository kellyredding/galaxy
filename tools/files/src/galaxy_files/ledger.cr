module GalaxyFiles
  # Who is asking, the way Galaxy.app tells its sessions apart: a ledger session
  # id and the Claude session identifiers behind it. Resolved through
  # galaxy-ledger, as galaxy-artifacts does, rather than by reading its database.
  module Ledger
    # Carries the line to print, which is the ledger's own when it gave one.
    class Error < Exception
    end

    def self.session_id(pid : String) : Int64
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run(
        LEDGER_BIN.to_s,
        args: ["resolve-session", "--pid", pid],
        output: output,
        error: error,
      )
      unless status.success?
        message = error.to_s.strip
        raise Error.new(message.empty? ? "Error: failed to resolve PID #{pid}" : message)
      end
      output.to_s.strip.to_i64? ||
        raise Error.new("Error: invalid response from the ledger for PID #{pid}")
    rescue ex : IO::Error
      raise Error.new("Error: could not run #{LEDGER_BIN} (#{ex.message})")
    end

    # Empty rather than failing: the app tries the ledger id first, and says so
    # itself when it cannot place the session.
    def self.session_identifiers(ledger_session_id : Int64) : Array(String)
      output = IO::Memory.new
      status = Process.run(
        LEDGER_BIN.to_s,
        args: [
          "session-identifiers", "--json",
          "--ledger-session-id", ledger_session_id.to_s,
        ],
        output: output,
        error: Process::Redirect::Close,
      )
      return [] of String unless status.success?
      JSON.parse(output.to_s)["session_identifiers"].as_a.map(&.as_s)
    rescue
      [] of String
    end
  end
end
