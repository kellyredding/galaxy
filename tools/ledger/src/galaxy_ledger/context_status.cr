require "json"

module GalaxyLedger
  # Reads context status from session-specific bridge files (written by statusline)
  # Supports both old (minimal) and new (enhanced) formats for backward compatibility
  class ContextStatus
    include JSON::Serializable

    # New enhanced format fields
    property session_id : String?
    property timestamp : Int64?
    property cwd : String?
    property workspace : Workspace?
    property claude_version : String?
    property context : Context?
    property cost : Cost?

    # Model can be either a string (old format) or object (new format)
    # We use JSON::Any to handle both, then provide accessor methods
    @[JSON::Field(key: "model")]
    property raw_model : JSON::Any?

    # Old format field (for backward compatibility)
    # In old format, percentage was at top level; in new format it's in context
    @[JSON::Field(key: "percentage")]
    property legacy_percentage : Float64?

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

    # Get the model object (new format) or construct one from string (old format)
    def model : Model?
      return nil unless rm = raw_model

      if rm.as_s?
        # Old format: model was a string
        Model.from_json(%({"id": #{rm.to_json}}))
      elsif rm.as_h?
        # New format: model is an object
        Model.from_json(rm.to_json)
      else
        nil
      end
    end

    # Get model ID (works for both formats)
    def model_id : String?
      if rm = raw_model
        if id = rm.as_s?
          id
        elsif rm.as_h?
          rm["id"]?.try(&.as_s?)
        else
          nil
        end
      end
    end

    # Get model display name (new format only)
    def model_display_name : String?
      if rm = raw_model
        if rm.as_h?
          rm["display_name"]?.try(&.as_s?)
        else
          nil
        end
      end
    end

    # Get percentage (handles both old and new format)
    def percentage : Float64?
      context.try(&.percentage) || legacy_percentage
    end

    # Get tokens used (new format only)
    def tokens_used : Int64?
      context.try(&.tokens_used)
    end

    # Get tokens max (new format only)
    def tokens_max : Int64?
      context.try(&.tokens_max)
    end

    # Get cost in USD (new format only)
    def cost_usd : Float64?
      cost.try(&.usd)
    end

    # Get lines added (new format only)
    def lines_added : Int32?
      cost.try(&.lines_added)
    end

    # Get lines removed (new format only)
    def lines_removed : Int32?
      cost.try(&.lines_removed)
    end

    # Check if this is the new enhanced format
    def enhanced_format? : Bool
      !context.nil? || !session_id.nil?
    end

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
