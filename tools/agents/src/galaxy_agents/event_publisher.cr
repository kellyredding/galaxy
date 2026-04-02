require "json"
require "socket"

module GalaxyAgents
  # Publishes lightweight event notifications over a Unix
  # domain socket to Galaxy.app for real-time UI updates.
  #
  # Events are thin signals with session identity and event
  # name. The app fetches fresh data after receiving an
  # event.
  #
  # All socket errors are silently rescued.
  module EventPublisher
    ENVELOPE_VERSION = 1

    SOCKET_PATH = GalaxyAgents::GALAXY_DIR / "galaxy.sock"

    WRITE_TIMEOUT = 100.milliseconds

    def self.build_envelope(
      event : String,
      ledger_session_id : Int64,
      session_identifiers : Array(String),
      ref : String? = nil,
    ) : String
      io = IO::Memory.new
      builder = JSON::Builder.new(io)
      builder.document do
        builder.object do
          builder.field("v", ENVELOPE_VERSION)
          builder.field("event", event)
          builder.field(
            "ledger_session_id",
            ledger_session_id,
          )
          builder.field("session_identifiers") do
            builder.array do
              session_identifiers.each do |sid|
                builder.scalar(sid)
              end
            end
          end
          builder.field("ts", Time.utc.to_unix)
          if r = ref
            builder.field("ref", r)
          end
        end
      end
      io.to_s
    end

    def self.publish(
      ledger_session_id : Int64,
      event : String,
      ref : String? = nil,
    ) : Bool
      identifiers = resolve_session_identifiers(
        ledger_session_id,
      )

      envelope = build_envelope(
        event: event,
        ledger_session_id: ledger_session_id,
        session_identifiers: identifiers,
        ref: ref,
      )

      send_to_socket(envelope)
    rescue
      false
    end

    def self.send_to_socket(
      envelope : String,
      socket_path : String = SOCKET_PATH.to_s,
    ) : Bool
      socket = UNIXSocket.new(socket_path)
      begin
        socket.sync = true
        socket.write_timeout = WRITE_TIMEOUT
        socket.puts(envelope)
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

    private def self.resolve_session_identifiers(
      ledger_session_id : Int64,
    ) : Array(String)
      output = IO::Memory.new
      status = Process.run(
        LEDGER_BIN.to_s,
        args: [
          "session-identifiers",
          "--json",
          "--ledger-session-id",
          ledger_session_id.to_s,
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
