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

    # Nothing is listening: Galaxy is not running.
    class NotRunning < Exception
    end

    # Galaxy took the request and did not answer in time. Unlike NotRunning,
    # the request may still have been carried out.
    class TimedOut < Exception
    end

    # Galaxy closed without a usable reply: a build whose socket does not
    # know the request.
    class NoReply < Exception
    end

    def self.request(
      event : String,
      detail : Hash(String, JSON::Any),
      read_timeout : Time::Span = READ_TIMEOUT,
      path : String = socket_path,
    ) : JSON::Any
      socket = begin
        UNIXSocket.new(path)
      rescue ex : Socket::Error | IO::Error
        raise NotRunning.new(ex.message)
      end
      begin
        socket.sync = true
        socket.write_timeout = WRITE_TIMEOUT
        socket.puts(build_envelope(event, detail))
        socket.read_timeout = read_timeout
        line = socket.gets(chomp: true)
        raise NoReply.new("no reply") if line.nil? || line.empty?
        reply = JSON.parse(line)
        raise NoReply.new("reply is not an object") unless reply.as_h?
        reply
      rescue ex : IO::TimeoutError
        raise TimedOut.new(ex.message)
      rescue ex : IO::Error | JSON::ParseException
        raise NoReply.new(ex.message)
      ensure
        socket.close rescue nil
      end
    end

    # As request, but nil whenever Galaxy did not answer, for callers that
    # carry on without it.
    def self.request?(
      event : String,
      detail : Hash(String, JSON::Any),
      path : String = socket_path,
    ) : JSON::Any?
      request(event, detail, path: path)
    rescue NotRunning | TimedOut | NoReply
      nil
    end
  end
end
