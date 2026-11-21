require "json"

module Galaxy
  # Reads a session's timeline through galaxy-timeline, which owns the
  # database. Rows come back in id order, so the last id is the next cursor.
  module TimelineReader
    DEFAULT_LIMIT = 500

    # Rows after `after_id`, or nil when galaxy-timeline could not be run.
    def self.events(
      ledger_session_id : Int64,
      after_id : Int64 = 0_i64,
      limit : Int32 = DEFAULT_LIMIT,
    ) : Array(JSON::Any)?
      output = IO::Memory.new
      status = Process.run(
        TIMELINE_BIN.to_s,
        args: [
          "list",
          "--ledger-session-id", ledger_session_id.to_s,
          "--after-id", after_id.to_s,
          "--limit", limit.to_s,
          "--json",
        ],
        output: output,
        error: Process::Redirect::Close,
      )
      return nil unless status.success?
      JSON.parse(output.to_s)["events"]?.try(&.as_a?)
    rescue File::NotFoundError | IO::Error | JSON::ParseException
      nil
    end

    # The newest row's id, 0 when the session has none yet, nil on failure.
    def self.latest_id(ledger_session_id : Int64) : Int64?
      output = IO::Memory.new
      status = Process.run(
        TIMELINE_BIN.to_s,
        args: [
          "list", "--ledger-session-id", ledger_session_id.to_s,
          "--after-id", "0", "--reverse", "--limit", "1", "--json",
        ],
        output: output,
        error: Process::Redirect::Close,
      )
      return nil unless status.success?
      events = JSON.parse(output.to_s)["events"]?.try(&.as_a?)
      return nil unless events
      events.first?.try(&.["id"]?.try(&.as_i64?)) || 0_i64
    rescue File::NotFoundError | IO::Error | JSON::ParseException
      nil
    end

    # A row with its detail_data string parsed, as `galaxy session read`
    # prints it.
    def self.readable(event : JSON::Any) : Hash(String, JSON::Any)
      detail = event["detail_data"]?.try(&.as_s?).try do |raw|
        JSON.parse(raw) rescue JSON::Any.new(raw)
      end
      {
        "id"          => event["id"]? || JSON::Any.new(nil),
        "type"        => event["event_type"]? || JSON::Any.new(nil),
        "occurred_at" => JSON::Any.new(WatchLine.iso8601(event["occurred_at"]?.try(&.as_s?) || "")),
        "source"      => event["source"]? || JSON::Any.new(nil),
        "detail"      => detail || JSON::Any.new(nil),
      }
    end
  end
end
