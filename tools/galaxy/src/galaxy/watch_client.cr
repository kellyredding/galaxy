require "json"
require "set"
require "socket"

module Galaxy
  # Follows one driven session's events: subscribe on galaxy-watch.sock, fill
  # the gap from the timeline, then print each live notification.
  #
  # Only a timeline read moves the resume point. Notifications can arrive out
  # of row order, so the highest id printed says nothing about the rows below
  # it; a read does, because the timeline numbers rows as they are written.
  # After a reconnect the backfill starts from the last read and prints only
  # what has not been printed.
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
      @resume_point = nil.as(Int64?)
    end

    def run(after : Int64? = nil) : Outcome
      @resume_point = after
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

          @resume_point ||= starting_point
          if from = @resume_point
            return Outcome::Matched if backfill_from(from)
          end

          while raw = read_line(sock)
            next unless line = WatchLine.parse?(raw)
            next if covered?(line)
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

        return Outcome::TimedOut if expired?
        @sleeper.call(capped(backoff))
        backoff = {backoff * 2, @max_backoff}.min
      end
    end

    # Where a run with no resume point yet begins. Live events already printed
    # mean the timeline could not be asked before: start below the first of
    # them, so whatever came between is read rather than skipped. Otherwise,
    # the newest row now.
    private def starting_point : Int64?
      if first = @seen.min?
        first - 1
      else
        @latest.call
      end
    end

    # Pages through every row after `from`, printing what has not been printed
    # and moving the resume point to the newest row read. True when `wait`
    # matched.
    private def backfill_from(from : Int64) : Bool
      c = from
      loop do
        lines = @backfill.call(c)
        unless lines
          @log.puts "galaxy session watch: could not read the timeline after event #{c}; will read it again on the next reconnect"
          return false
        end
        lines.each { |line| return true if emit(line) }
        newest = lines.compact_map(&.event_id).max?
        advance(newest) if newest
        return false if lines.size < BACKFILL_PAGE || newest.nil?
        c = newest
      end
    end

    # Rows at or below the resume point have all been read and printed, so
    # their ids no longer need remembering.
    private def advance(to : Int64)
      return if (rp = @resume_point) && rp >= to
      @resume_point = to
      @seen.reject! { |id| id <= to }
    end

    # A live notification for a row the last read already covered.
    private def covered?(line : WatchLine) : Bool
      id = line.event_id
      rp = @resume_point
      !id.nil? && !rp.nil? && id <= rp
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
