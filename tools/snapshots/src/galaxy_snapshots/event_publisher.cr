require "json"
require "socket"

module GalaxySnapshots
  # Publishes lightweight event notifications over a Unix domain socket
  # to Galaxy.app for real-time UI updates.
  #
  # Events are thin signals — they carry session identity and event name
  # but no enrichment data. The app fetches fresh data after receiving an event.
  #
  # Session identifiers are resolved by delegating to the galaxy-ledger CLI,
  # since the snapshots tool does not have direct access to the ledger database.
  #
  # All socket errors are silently rescued. The tool works identically
  # whether or not Galaxy.app is running.
  module EventPublisher
    # Current envelope schema version
    ENVELOPE_VERSION = 1

    # Socket path for Galaxy.app listener
    SOCKET_PATH = GalaxySnapshots::GALAXY_DIR / "galaxy.sock"

    # Write timeout (100ms)
    WRITE_TIMEOUT = 100.milliseconds

    # Build a JSON envelope string for the given event.
    # Returns the JSON line (without trailing newline).
    #
    # `detail_data` accepts a pre-serialized JSON string
    # — the caller builds the detail payload with its own
    # JSON::Builder and this method splices it in. Kept as
    # String rather than a typed struct so new events can
    # ship new fields without widening a schema here.
    def self.build_envelope(
      event : String,
      ledger_session_id : Int64,
      session_identifiers : Array(String),
      ref : String? = nil,
      detail_data : String? = nil,
    ) : String
      io = IO::Memory.new
      builder = JSON::Builder.new(io)
      builder.document do
        builder.object do
          builder.field("v", ENVELOPE_VERSION)
          builder.field("event", event)
          builder.field("ledger_session_id", ledger_session_id)
          builder.field("session_identifiers") do
            builder.array do
              session_identifiers.each { |sid| builder.scalar(sid) }
            end
          end
          builder.field("ts", Time.utc.to_unix)
          if r = ref
            builder.field("ref", r)
          end
          if dd = detail_data
            builder.field("detail_data", JSON.parse(dd))
          end
        end
      end
      io.to_s
    end

    # Publish an event to Galaxy.app via the Unix domain socket.
    #
    # Resolves session_identifiers via the ledger CLI, builds the JSON
    # envelope, and writes it to the socket. All errors are silently
    # rescued — ENOENT (no socket), ECONNREFUSED (app not listening),
    # EPIPE (broken connection), timeout, and any other IO error.
    #
    # Returns true if the event was successfully written, false otherwise.
    # The return value is informational only — callers should never
    # branch on it.
    def self.publish(
      ledger_session_id : Int64,
      event : String,
      ref : String? = nil,
      detail_data : String? = nil,
    ) : Bool
      identifiers = resolve_session_identifiers(ledger_session_id)

      envelope = build_envelope(
        event: event,
        ledger_session_id: ledger_session_id,
        session_identifiers: identifiers,
        ref: ref,
        detail_data: detail_data,
      )

      send_to_socket(envelope)
    rescue
      false
    end

    # Low-level socket write. Connects, writes the JSON line, closes.
    # Separated from publish for testability.
    def self.send_to_socket(
      envelope : String,
      socket_path : String = SOCKET_PATH.to_s,
    ) : Bool
      socket = UNIXSocket.new(socket_path)
      begin
        socket.sync = true
        socket.write_timeout = WRITE_TIMEOUT
        socket.puts(envelope)
        # Read the server's close to ensure data was received before
        # we close our end. This blocks until NWListener processes the
        # data and closes the connection (isComplete=true), or until
        # read_timeout. Prevents the FIN/RST race where close()
        # destroys the socket before NWListener reads from it.
        socket.read_timeout = WRITE_TIMEOUT
        buf = Bytes.new(1)
        socket.read(buf) rescue nil
        true
      ensure
        socket.close
      end
    rescue
      false
    end

    # Resolve session identifiers by delegating to the galaxy-ledger CLI.
    # Returns empty array if ledger is unavailable or session not found.
    private def self.resolve_session_identifiers(
      ledger_session_id : Int64,
    ) : Array(String)
      output = IO::Memory.new
      status = Process.run(
        LEDGER_BIN.to_s,
        args: [
          "session-identifiers",
          "--json",
          "--ledger-session-id", ledger_session_id.to_s,
        ],
        output: output,
        error: Process::Redirect::Close,
      )
      return [] of String unless status.success?

      json = JSON.parse(output.to_s)
      json["session_identifiers"].as_a.map(&.as_s)
    rescue
      [] of String
    end
  end
end
