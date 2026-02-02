require "json"

module GalaxyStatusline
  # Writes context status to a session-specific bridge file for other Galaxy tools (e.g., ledger)
  # Note: session_id is NOT stored in the file - it's implicit from the folder path
  class ContextStatus
    include JSON::Serializable

    property percentage : Float64?
    property timestamp : Int64
    property model : String?

    def initialize(@percentage, @model)
      @timestamp = Time.utc.to_unix
    end

    # Write the context status to a session-specific bridge file
    # Silently fails if it can't write (graceful degradation)
    def self.write(input : ClaudeInput)
      # Must have a session_id to write session-specific file
      session_id = input.session_id
      return unless session_id

      status = new(
        percentage: input.context_percentage,
        model: input.model.try(&.id)
      )

      begin
        # Build session-specific path
        session_dir = SESSIONS_DIR / session_id
        status_file = session_dir / CONTEXT_STATUS_FILENAME

        # Create session directory just-in-time if it doesn't exist
        Dir.mkdir_p(session_dir) unless Dir.exists?(session_dir)

        # Write the status file atomically (write to temp, then rename)
        temp_file = status_file.to_s + ".tmp"
        File.write(temp_file, status.to_pretty_json)
        File.rename(temp_file, status_file.to_s)
      rescue
        # Silently fail - this is non-critical functionality
        # The statusline should render even if we can't write the bridge file
      end
    end

    # Read context status for a specific session
    # Returns nil if session folder or file doesn't exist (graceful degradation)
    def self.read(session_id : String) : ContextStatus?
      return nil if session_id.empty?

      begin
        session_dir = SESSIONS_DIR / session_id
        status_file = session_dir / CONTEXT_STATUS_FILENAME

        # If session folder or file doesn't exist, return nil
        return nil unless File.exists?(status_file)

        json = File.read(status_file)
        ContextStatus.from_json(json)
      rescue
        # Silently fail - return nil if we can't read
        nil
      end
    end

    # Get the path to a session's context status file
    def self.path_for_session(session_id : String) : Path
      SESSIONS_DIR / session_id / CONTEXT_STATUS_FILENAME
    end

    # Get the path to a session's directory
    def self.session_dir(session_id : String) : Path
      SESSIONS_DIR / session_id
    end

    def to_pretty_json : String
      JSON.build(indent: "  ") do |json|
        to_json(json)
      end
    end
  end
end
