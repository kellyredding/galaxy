require "json"
require "set"
require "socket"

module Galaxy
  # Follows one driven session's events: subscribe on galaxy-watch.sock, fill
  # the gap from the timeline, then print each live notification. The stream
  # only says that something happened, and the timeline holds what happened,
  # so a dropped connection loses nothing: it reconnects and backfills from
  # the highest event id it printed.
  #
  # Known gap: a notification that never arrived, for an id lower than one
  # already printed, is not recovered by the backfill. Ids are global across
  # sessions, so there is no way to tell such a hole from another session's
  # rows.
  class WatchClient
    enum Outcome
      Matched      # `wait` saw its event
      TimedOut     # `wait --timeout` ran out
      Failed       # Galaxy refused the subscription
      OutputClosed # whoever read the output went away
    end

    # Rows per backfill call; a full page means there may be more.
    BACKFILL_PAGE = 5000

    # Rows after the cursor, nil when they could not be read.
    alias Backfill = Int64 -> Array(WatchLine)?
    # The newest row id, 0 when nothing is recorded yet, nil when unknown.
    alias Latest = -> Int64?

    # Raised out of `emit` so a dead reader ends the run instead of reading
    # as a dropped Galaxy connection and reconnecting forever.
    private class OutputClosed < Exception
    end

    def initialize(
      @session_id : String,
      @output : IO,
      @filter : EventFilter,
      @backfill : Backfill,
      @latest : Latest,
      @socket_path : String = SocketClient.watch_socket_path,
      @stop_on_first : Bool = false,
      # A Time.monotonic reading to give up at.
      @deadline : Time::Span? = nil,
      @sleeper : Proc(Time::Span, Nil) = ->(span : Time::Span) { sleep(span); nil },
      @initial_backoff : Time::Span = 500.milliseconds,
      @max_backoff : Time::Span = 10.seconds,
      @log : IO = STDERR,
    )
      @seen = Set(Int64).new
      @waiting_logged = false
    end

    def run(after : Int64? = nil) : Outcome
      cursor = after
      backoff = @initial_backoff

      loop do
        socket : UNIXSocket? = nil
        begin
          sock = UNIXSocket.new(@socket_path)
          socket = sock
          sock.sync = true
          sock.puts({"v" => 1, "subscribe" => @session_id}.to_json)

          # Closed before any reply: Galaxy quitting mid-handshake, so retry.
          ack = read_line(sock) || raise IO::EOFError.new("closed before subscribing")
          return Outcome::Failed unless subscribed?(ack)
          backoff = @initial_backoff
          @waiting_logged = false

          # Without a cursor, start from the newest row now, so a reconnect
          # later knows where this run began.
          cursor ||= @latest.call
          if c = cursor
            return Outcome::Matched if backfill_from(c)
          end

          while raw = read_line(sock)
            next unless line = WatchLine.parse?(raw)
            return Outcome::Matched if emit(line)
          end
        rescue OutputClosed
          return Outcome::OutputClosed
        rescue IO::TimeoutError
          return Outcome::TimedOut
        rescue Socket::Error | IO::Error
          unless @waiting_logged
            @log.puts "galaxy session watch: Galaxy is not reachable at #{@socket_path}, retrying"
            @waiting_logged = true
          end
        ensure
          socket.try(&.close) rescue nil
        end

        cursor = [cursor, @seen.max?].compact.max?
        return Outcome::TimedOut if expired?
        @sleeper.call(capped(backoff))
        backoff = {backoff * 2, @max_backoff}.min
      end
    end

    # Pages through every row after `cursor`. True when `wait` matched.
    private def backfill_from(cursor : Int64) : Bool
      c = cursor
      loop do
        lines = @backfill.call(c)
        unless lines
          @log.puts "galaxy session watch: could not read the timeline after event #{c}; events in that gap are missing"
          return false
        end
        lines.each { |line| return true if emit(line) }
        return false if lines.size < BACKFILL_PAGE
        c = lines.compact_map(&.event_id).max? || return false
      end
    end

    private def emit(line : WatchLine) : Bool
      if id = line.event_id
        return false if @seen.includes?(id)
        @seen << id
      end
      return false unless @filter.match?(line.type)
      begin
        @output.puts(line.to_json)
        @output.flush
      rescue IO::Error
        raise OutputClosed.new
      end
      @stop_on_first
    end

    private def subscribed?(ack : String) : Bool
      reply = JSON.parse(ack)
      if error = reply["error"]?.try(&.as_s?)
        @log.puts "Error: #{error}"
        return false
      end
      return true if reply["subscribed"]?.try(&.as_s?) == @session_id
      @log.puts "Error: unexpected reply from galaxy-watch.sock: #{ack}"
      false
    rescue JSON::ParseException
      @log.puts "Error: unexpected reply from galaxy-watch.sock: #{ack}"
      false
    end

    private def read_line(sock : UNIXSocket) : String?
      if deadline = @deadline
        remaining = deadline - Time.monotonic
        raise IO::TimeoutError.new("wait timed out") if remaining <= Time::Span.zero
        sock.read_timeout = remaining
      end
      sock.gets(chomp: true)
    end

    private def expired? : Bool
      if deadline = @deadline
        Time.monotonic >= deadline
      else
        false
      end
    end

    private def capped(span : Time::Span) : Time::Span
      if deadline = @deadline
        {span, deadline - Time.monotonic}.min
      else
        span
      end
    end
  end
end
