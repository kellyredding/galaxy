require "json"

module GalaxyLedger
  # Reads context status from session-specific bridge files (written by statusline)
  class ContextStatus
    include JSON::Serializable

    property session_id : String?
    property timestamp : Int64?
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
    end

    class Model
      include JSON::Serializable

      property id : String?
      property display_name : String?
    end

    class Context
      include JSON::Serializable

      property percentage : Float64?
      property tokens_used : Int64?
      property tokens_max : Int64?
    end

    class Cost
      include JSON::Serializable

      property usd : Float64?
      property lines_added : Int32?
      property lines_removed : Int32?
    end

    # Convenience accessors
    def percentage : Float64?
      context.try(&.percentage)
    end

    def tokens_used : Int64?
      context.try(&.tokens_used)
    end

    def tokens_max : Int64?
      context.try(&.tokens_max)
    end

    def cost_usd : Float64?
      cost.try(&.usd)
    end

    def lines_added : Int32?
      cost.try(&.lines_added)
    end

    def lines_removed : Int32?
      cost.try(&.lines_removed)
    end

    def model_id : String?
      model.try(&.id)
    end

    def model_display_name : String?
      model.try(&.display_name)
    end

    # Read context status for a specific session
    def self.read(session_id : String) : ContextStatus?
      return nil if session_id.empty?

      begin
        status_file = GalaxyLedger.context_status_path(session_id)
        return nil unless File.exists?(status_file)

        ContextStatus.from_json(File.read(status_file))
      rescue
        nil
      end
    end

    def self.exists?(session_id : String) : Bool
      return false if session_id.empty?
      File.exists?(GalaxyLedger.context_status_path(session_id))
    end
  end
end
