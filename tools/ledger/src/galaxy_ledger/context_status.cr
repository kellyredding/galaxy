require "json"

module GalaxyLedger
  # Reads context status from session-specific bridge files (written by statusline)
  class ContextStatus
    include JSON::Serializable

    property percentage : Float64?
    property session_id : String?
    property timestamp : Int64?
    property model : String?

    # Read context status for a specific session
    # Returns nil if session folder or file doesn't exist (graceful degradation)
    def self.read(session_id : String) : ContextStatus?
      return nil if session_id.empty?

      begin
        status_file = GalaxyLedger.context_status_path(session_id)

        # If session folder or file doesn't exist, return nil
        return nil unless File.exists?(status_file)

        json = File.read(status_file)
        ContextStatus.from_json(json)
      rescue
        # Silently fail - return nil if we can't read
        nil
      end
    end

    # Check if context status exists for a session
    def self.exists?(session_id : String) : Bool
      return false if session_id.empty?
      File.exists?(GalaxyLedger.context_status_path(session_id))
    end
  end
end
