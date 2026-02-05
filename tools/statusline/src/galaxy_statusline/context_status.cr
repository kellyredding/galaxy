require "json"

module GalaxyStatusline
  # Writes context status to a session-specific bridge file for other Galaxy tools (e.g., ledger)
  # Contains full Claude Code payload for rich cross-tool integration
  class ContextStatus
    include JSON::Serializable

    property session_id : String?
    property timestamp : Int64
    property cwd : String?
    property workspace : Workspace?
    property model : Model?
    property claude_version : String?
    property context : Context?
    property cost : Cost?

    class Workspace
      include JSON::Serializable

      property current_dir : String?
      property project_dir : String?

      def initialize(@current_dir, @project_dir)
      end
    end

    class Model
      include JSON::Serializable

      property id : String?
      property display_name : String?

      def initialize(@id, @display_name)
      end
    end

    class Context
      include JSON::Serializable

      property percentage : Float64?
      property tokens_used : Int64?
      property tokens_max : Int64?

      def initialize(@percentage, @tokens_used, @tokens_max)
      end
    end

    class Cost
      include JSON::Serializable

      property usd : Float64?
      property lines_added : Int32?
      property lines_removed : Int32?

      def initialize(@usd, @lines_added, @lines_removed)
      end
    end

    def initialize(
      @session_id : String?,
      @cwd : String?,
      @workspace : Workspace?,
      @model : Model?,
      @claude_version : String?,
      @context : Context?,
      @cost : Cost?
    )
      @timestamp = Time.utc.to_unix
    end

    # Write the context status to a session-specific bridge file
    # Silently fails if it can't write (graceful degradation)
    def self.write(input : ClaudeInput)
      # Must have a session_id to write session-specific file
      session_id = input.session_id
      return unless session_id

      # Build workspace object if available
      workspace = if ws = input.workspace
                    Workspace.new(ws.current_dir, ws.project_dir)
                  end

      # Build model object if available
      model = if m = input.model
                Model.new(m.id, m.display_name)
              end

      # Build context object from context_window
      context = if cw = input.context_window
                  Context.new(cw.used_percentage, cw.total_input_tokens, cw.context_window_size)
                end

      # Build cost object if available
      cost = if c = input.cost
               Cost.new(c.total_cost_usd, c.total_lines_added, c.total_lines_removed)
             end

      status = new(
        session_id: session_id,
        cwd: input.cwd,
        workspace: workspace,
        model: model,
        claude_version: input.version,
        context: context,
        cost: cost
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
