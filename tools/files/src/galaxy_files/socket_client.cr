module GalaxyFiles
  # One request envelope out, one reply line back. The envelope carries the same
  # identity every Galaxy event does, so the app places it the same way.
  module SocketClient
    ENVELOPE_VERSION = 1
    WRITE_TIMEOUT    = 100.milliseconds
    READ_TIMEOUT     = 5.seconds

    def self.build_envelope(
      event : String,
      ledger_session_id : Int64,
      session_identifiers : Array(String),
      detail : Hash(String, JSON::Any),
    ) : String
      JSON.build do |json|
        json.object do
          json.field "v", ENVELOPE_VERSION
          json.field "event", event
          json.field "ledger_session_id", ledger_session_id
          json.field "session_identifiers", session_identifiers
          json.field "ts", Time.utc.to_unix
          json.field "detail_data", detail
        end
      end
    end

    # The reply line, or nil when nothing answered: the app is not running, or
    # is a build whose socket does not reply.
    def self.request(
      envelope : String,
      socket_path : String = SOCKET_PATH.to_s,
    ) : String?
      socket = UNIXSocket.new(socket_path)
      begin
        socket.sync = true
        socket.write_timeout = WRITE_TIMEOUT
        socket.puts(envelope)
        socket.read_timeout = READ_TIMEOUT
        socket.gets(chomp: true)
      ensure
        socket.close
      end
    rescue
      nil
    end
  end
end
