require "json"

module Galaxy
  # One event notification for a driven session, as `galaxy session watch`
  # prints it and as galaxy-watch.sock sends it. A signal, not a payload:
  # `event_id` is the timeline row to read details from, null for events that
  # are not timeline rows (session.idle, session.metrics, permission_request).
  # The few events Galaxy raises with no row to read (session.input:failed,
  # session.resume:failed) carry their facts in `detail`.
  struct WatchLine
    include JSON::Serializable

    getter v : Int32 = 1
    @[JSON::Field(emit_null: true)]
    getter event_id : Int64?
    getter type : String
    getter session_id : String
    getter occurred_at : String
    getter detail : JSON::Any?

    def initialize(@event_id : Int64?, @type : String, @session_id : String, @occurred_at : String, @detail : JSON::Any? = nil)
    end

    # A line read off the watch socket, or nil for anything that is not one.
    def self.parse?(line : String) : WatchLine?
      from_json(line)
    rescue JSON::ParseException | JSON::SerializableError
      nil
    end

    # A timeline row (from `galaxy-timeline list --json`) as a watch line.
    def self.from_timeline(event : JSON::Any, session_id : String) : WatchLine?
      id = event["id"]?.try(&.as_i64?)
      type = event["event_type"]?.try(&.as_s?)
      return nil unless id && type
      new(id, type, session_id, iso8601(event["occurred_at"]?.try(&.as_s?) || ""))
    end

    # The timeline stores UTC as "YYYY-MM-DD HH:MM:SS"; lines carry ISO 8601.
    def self.iso8601(stored : String) : String
      return stored unless stored =~ /\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\z/
      stored.sub(' ', 'T') + "Z"
    end
  end

  # `--events turn:completed,lock:*`: exact types, or a prefix ending in `*`.
  # Empty matches everything.
  struct EventFilter
    getter patterns : Array(String)

    def initialize(spec : String? = nil)
      @patterns = (spec || "").split(',').map(&.strip).reject(&.empty?)
    end

    def match?(type : String) : Bool
      return true if @patterns.empty?
      @patterns.any? do |p|
        p.ends_with?('*') ? type.starts_with?(p.rchop('*')) : type == p
      end
    end
  end
end
