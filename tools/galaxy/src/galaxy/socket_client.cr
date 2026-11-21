require "json"
require "socket"

module Galaxy
  # One request envelope out on galaxy.sock, one reply line back. Same envelope
  # shape every Galaxy tool sends, so the app decodes it with the decoder it
  # already has; a driver is not a ledger session, hence id 0 and no
  # identifiers.
  module SocketClient
    ENVELOPE_VERSION = 1
    WRITE_TIMEOUT    = 100.milliseconds
    READ_TIMEOUT     = 5.seconds

    def self.socket_path : String
      ENV.fetch("GALAXY_SOCKET_PATH", (GALAXY_DIR / "galaxy.sock").to_s)
    end

    def self.watch_socket_path : String
      ENV.fetch("GALAXY_WATCH_SOCKET_PATH", (GALAXY_DIR / "galaxy-watch.sock").to_s)
    end

    def self.build_envelope(event : String, detail : Hash(String, JSON::Any)) : String
      JSON.build do |json|
        json.object do
          json.field "v", ENVELOPE_VERSION
          json.field "event", event
          json.field "ledger_session_id", 0
          json.field "session_identifiers", [] of String
          json.field "ts", Time.utc.to_unix
          json.field "detail_data", detail
        end
      end
    end

    # The parsed reply object, or nil when nothing answered: Galaxy is not
    # running, or is a build whose socket does not know the request.
    def self.request(
      event : String,
      detail : Hash(String, JSON::Any),
      read_timeout : Time::Span = READ_TIMEOUT,
      path : String = socket_path,
    ) : JSON::Any?
      socket = UNIXSocket.new(path)
      begin
        socket.sync = true
        socket.write_timeout = WRITE_TIMEOUT
        socket.puts(build_envelope(event, detail))
        socket.read_timeout = read_timeout
        line = socket.gets(chomp: true)
        return nil if line.nil? || line.empty?
        reply = JSON.parse(line)
        reply.as_h? ? reply : nil
      ensure
        socket.close
      end
    rescue IO::Error | Socket::Error | JSON::ParseException
      nil
    end
  end
end
