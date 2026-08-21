require "json"

module GalaxyLedger
  # Reads what Galaxy.app has written about its own sessions.
  #
  # The app is the only thing that knows whether a queue can drain. Its inbox
  # lives in memory and a refused send reaches no terminal, so neither half of
  # "a stranded queue" is visible from the ledger database — and a check built
  # where the readiness event is *emitted* reads healthy while the app is
  # dropping it, which is the failure this exists to catch. So the answer has
  # to come from the app's own writing.
  module AppState
    # Where Galaxy.app persists session state.
    STATE_PATH = Path.home / "Library" / "Application Support" /
                 "Galaxy" / "sessions.json"

    # Beyond this, a reading is old enough to say so rather than report it
    # as current. The app writes on a debounce measured in seconds, so a
    # minute means nothing has been persisted through a whole cycle.
    STALE_AFTER = 60.seconds

    # The block reason a person can truthfully resolve.
    #
    # Mirrors `Session.SubmitBlock.neverReady.rawValue`. Every other value is
    # either transient or owes an ordered command, and releasing one of those
    # by hand overtakes it.
    RECOVERABLE_REASON = "never-reported-ready"

    # One session, as the app last described it.
    record Session,
      ledger_session_id : Int64?,
      session_ref : String?,
      claude_session_id : String?,
      inbox_depth : Int32,
      block_reason : String? do
      # Holding messages it cannot send.
      def stranded? : Bool
        inbox_depth > 0 && !block_reason.nil?
      end

      def recoverable? : Bool
        block_reason == RECOVERABLE_REASON
      end

      def label : String
        ref = session_ref || claude_session_id || "?"
        id = ledger_session_id
        id ? "#{ref} (#{id})" : ref
      end
    end

    # A whole reading, with the two facts that decide whether to trust it.
    record Reading,
      sessions : Array(Session),
      age : Time::Span,
      app_running : Bool do
      def stale? : Bool
        age > STALE_AFTER
      end

      def stranded : Array(Session)
        sessions.select(&.stranded?)
      end
    end

    # Whether the app is up.
    #
    # Checked because a closed app and a stranded queue produce an identical
    # file, and calling the second one when it is the first sends a reader
    # looking for a bug that is not there.
    def self.app_running? : Bool
      File.exists?(EventPublisher::SOCKET_PATH.to_s)
    end

    # Read the app's state, or nil when there is nothing readable there.
    def self.read : Reading?
      path = STATE_PATH.to_s
      return nil unless File.exists?(path)

      raw = File.read(path)
      age = Time.utc - File.info(path).modification_time
      parsed = JSON.parse(raw)

      sessions = [] of Session
      parsed["sidebarItems"]?.try &.as_a?.try &.each do |item|
        node = item["session"]?
        next unless node
        sessions << Session.new(
          ledger_session_id: node["ledgerSessionId"]?.try &.as_i64?,
          session_ref: node["sessionRef"]?.try &.as_s?,
          claude_session_id: node["claudeSessionId"]?.try &.as_s?,
          inbox_depth: node["inboxDepth"]?.try(&.as_i?) || 0,
          block_reason: node["submitBlockReason"]?.try &.as_s?,
        )
      end

      Reading.new(sessions: sessions, age: age, app_running: app_running?)
    rescue JSON::ParseException
      nil
    end

    # Find one session by whichever identifier the caller has.
    def self.find(
      reading : Reading,
      ledger_session_id : Int64?,
      claude_session_id : String? = nil,
    ) : Session?
      reading.sessions.find do |s|
        (!ledger_session_id.nil? &&
          s.ledger_session_id == ledger_session_id) ||
          (!claude_session_id.nil? &&
            s.claude_session_id == claude_session_id)
      end
    end
  end
end
