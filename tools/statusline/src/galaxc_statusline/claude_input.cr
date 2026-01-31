require "json"

module GalaxcStatusline
  # Parses the JSON input from Claude Code's status line hook
  class ClaudeInput
    include JSON::Serializable

    @[JSON::Field(key: "hook_event_name")]
    property hook_event_name : String?

    @[JSON::Field(key: "session_id")]
    property session_id : String?

    property cwd : String?
    property model : Model?
    property workspace : Workspace?
    property version : String?
    property cost : Cost?

    @[JSON::Field(key: "context_window")]
    property context_window : ContextWindow?

    class Model
      include JSON::Serializable

      property id : String?

      @[JSON::Field(key: "display_name")]
      property display_name : String?
    end

    class Workspace
      include JSON::Serializable

      @[JSON::Field(key: "current_dir")]
      property current_dir : String?

      @[JSON::Field(key: "project_dir")]
      property project_dir : String?
    end

    class Cost
      include JSON::Serializable

      @[JSON::Field(key: "total_cost_usd")]
      property total_cost_usd : Float64?

      @[JSON::Field(key: "total_lines_added")]
      property total_lines_added : Int32?

      @[JSON::Field(key: "total_lines_removed")]
      property total_lines_removed : Int32?
    end

    class ContextWindow
      include JSON::Serializable

      @[JSON::Field(key: "used_percentage")]
      property used_percentage : Float64?

      @[JSON::Field(key: "total_input_tokens")]
      property total_input_tokens : Int64?

      @[JSON::Field(key: "context_window_size")]
      property context_window_size : Int64?
    end

    def self.parse(json : String) : ClaudeInput
      ClaudeInput.from_json(json)
    end

    # Helper methods for safe access
    def current_directory : String?
      workspace.try(&.current_dir) || cwd
    end

    def model_name : String?
      model.try(&.display_name)
    end

    def total_cost : Float64?
      cost.try(&.total_cost_usd)
    end

    def context_percentage : Float64?
      context_window.try(&.used_percentage)
    end
  end
end
