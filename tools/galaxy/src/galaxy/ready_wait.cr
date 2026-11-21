require "json"

module Galaxy
  # What `session new` and `resume` make of the event that ends their wait:
  # `session:input-ready` (the session can take its first prompt, after any
  # opening turn) or `session:exited` (it went away first).
  module ReadyWait
    INPUT_READY = "session:input-ready"
    EXITED      = "session:exited"
    FILTER      = "#{INPUT_READY},#{EXITED}"

    record Ready, opening_event_id : Int64?
    record NotReady, message : String, exit_code : Int32

    def self.decide(type : String, detail : JSON::Any?) : Ready | NotReady
      fields = detail.try(&.as_h?) || {} of String => JSON::Any
      return Ready.new(fields["opening_event_id"]?.try(&.as_i64?)) unless type == EXITED

      facts = [] of String
      fields["exit_code"]?.try(&.as_i?).try { |code| facts << "exit code #{code}" }
      fields["initiated_by"]?.try(&.as_s?).try { |by| facts << "stopped by #{by}" }
      reason = facts.empty? ? "" : " (#{facts.join(", ")})"
      NotReady.new("the session exited before it was ready for input#{reason}", 1)
    end
  end
end
