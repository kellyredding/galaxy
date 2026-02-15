require "json"

module GalaxyLedger
  # Parses context status JSON received via stdin from the statusline tool.
  # Contains session metrics (context percentage, tokens, cost, model, etc.)
  # used by the update-session-metrics CLI command.
  class ContextStatus
    include JSON::Serializable

    property session_id : String?
    property timestamp : Int64?
    property cwd : String?
    property git_branch : String?
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

    def project_dir : String?
      workspace.try(&.project_dir)
    end
  end
end
