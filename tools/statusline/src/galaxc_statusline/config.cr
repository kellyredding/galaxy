require "json"

module GalaxcStatusline
  class Config
    include JSON::Serializable

    VALID_COLORS = %w[
      red green yellow blue magenta cyan white
      bright_red bright_green bright_yellow bright_blue
      bright_magenta bright_cyan bright_white
      default
    ]

    VALID_BRANCH_STYLES    = %w[symbolic arrows minimal]
    VALID_DIRECTORY_STYLES = %w[full smart basename short]

    property version : String
    property colors : Colors
    property branch_style : String
    property context_thresholds : ContextThresholds
    property layout : Layout

    class Colors
      include JSON::Serializable

      property directory : String
      property branch : String
      property upstream_behind : String
      property upstream_ahead : String
      property upstream_synced : String
      property dirty : String
      property staged : String
      property stashed : String
      property context_normal : String
      property context_warning : String
      property context_critical : String
      property model : String
      property cost : String

      def initialize(
        @directory = "bold:yellow",
        @branch = "green",
        @upstream_behind = "cyan",
        @upstream_ahead = "cyan",
        @upstream_synced = "green",
        @dirty = "yellow",
        @staged = "green",
        @stashed = "red",
        @context_normal = "green",
        @context_warning = "yellow",
        @context_critical = "red",
        @model = "default",
        @cost = "default",
      )
      end
    end

    class ContextThresholds
      include JSON::Serializable

      property warning : Int32
      property critical : Int32

      def initialize(@warning = 60, @critical = 80)
      end
    end

    class Layout
      include JSON::Serializable

      property min_width : Int32
      property context_bar_min_width : Int32
      property context_bar_max_width : Int32
      property show_cost : Bool
      property show_model : Bool
      property directory_style : String

      def initialize(
        @min_width = 60,
        @context_bar_min_width = 10,
        @context_bar_max_width = 20,
        @show_cost = true,
        @show_model = true,
        @directory_style = "smart",
      )
      end
    end

    def initialize(
      @version = VERSION,
      @colors = Colors.new,
      @branch_style = "symbolic",
      @context_thresholds = ContextThresholds.new,
      @layout = Layout.new,
    )
    end

    def self.default : Config
      Config.new
    end

    def self.load : Config
      ensure_config_dir

      unless File.exists?(CONFIG_FILE)
        config = default
        config.save
        return config
      end

      begin
        json = File.read(CONFIG_FILE)
        config = Config.from_json(json)
        # Ensure version is current
        config.version = VERSION
        config
      rescue ex
        STDERR.puts "Warning: Could not parse config, using defaults: #{ex.message}"
        default
      end
    end

    def save
      ensure_config_dir
      File.write(CONFIG_FILE, to_pretty_json)
    end

    def to_pretty_json : String
      JSON.build(indent: "  ") do |json|
        to_json(json)
      end
    end

    def set(key : String, value : String)
      parts = key.split(".")

      case parts[0]
      when "colors"
        set_color(parts[1]?, value)
      when "branch_style"
        set_branch_style(value)
      when "context_thresholds"
        set_threshold(parts[1]?, value)
      when "layout"
        set_layout(parts[1]?, value)
      else
        raise "Unknown setting: #{key}"
      end
    end

    def get(key : String) : String
      parts = key.split(".")

      case parts[0]
      when "version"
        version
      when "colors"
        get_color(parts[1]?)
      when "branch_style"
        branch_style
      when "context_thresholds"
        get_threshold(parts[1]?)
      when "layout"
        get_layout(parts[1]?)
      else
        raise "Unknown setting: #{key}"
      end
    end

    private def set_color(field : String?, value : String)
      raise "Missing color field (e.g., colors.branch)" unless field
      validate_color(value)

      case field
      when "directory"        then colors.directory = value
      when "branch"           then colors.branch = value
      when "upstream_behind"  then colors.upstream_behind = value
      when "upstream_ahead"   then colors.upstream_ahead = value
      when "upstream_synced"  then colors.upstream_synced = value
      when "dirty"            then colors.dirty = value
      when "staged"           then colors.staged = value
      when "stashed"          then colors.stashed = value
      when "context_normal"   then colors.context_normal = value
      when "context_warning"  then colors.context_warning = value
      when "context_critical" then colors.context_critical = value
      when "model"            then colors.model = value
      when "cost"             then colors.cost = value
      else
        raise "Unknown color field: colors.#{field}"
      end
    end

    private def get_color(field : String?) : String
      raise "Missing color field (e.g., colors.branch)" unless field

      case field
      when "directory"        then colors.directory
      when "branch"           then colors.branch
      when "upstream_behind"  then colors.upstream_behind
      when "upstream_ahead"   then colors.upstream_ahead
      when "upstream_synced"  then colors.upstream_synced
      when "dirty"            then colors.dirty
      when "staged"           then colors.staged
      when "stashed"          then colors.stashed
      when "context_normal"   then colors.context_normal
      when "context_warning"  then colors.context_warning
      when "context_critical" then colors.context_critical
      when "model"            then colors.model
      when "cost"             then colors.cost
      else
        raise "Unknown color field: colors.#{field}"
      end
    end

    private def set_branch_style(value : String)
      unless VALID_BRANCH_STYLES.includes?(value)
        raise "Invalid branch_style: #{value} (must be: #{VALID_BRANCH_STYLES.join(", ")})"
      end
      @branch_style = value
    end

    private def set_threshold(field : String?, value : String)
      raise "Missing threshold field (e.g., context_thresholds.warning)" unless field

      int_value = value.to_i? || raise "Invalid threshold value: #{value} (must be integer)"
      unless (0..100).includes?(int_value)
        raise "Threshold must be between 0 and 100"
      end

      case field
      when "warning"  then context_thresholds.warning = int_value
      when "critical" then context_thresholds.critical = int_value
      else
        raise "Unknown threshold field: context_thresholds.#{field}"
      end
    end

    private def get_threshold(field : String?) : String
      raise "Missing threshold field (e.g., context_thresholds.warning)" unless field

      case field
      when "warning"  then context_thresholds.warning.to_s
      when "critical" then context_thresholds.critical.to_s
      else
        raise "Unknown threshold field: context_thresholds.#{field}"
      end
    end

    private def set_layout(field : String?, value : String)
      raise "Missing layout field (e.g., layout.min_width)" unless field

      case field
      when "min_width", "context_bar_min_width", "context_bar_max_width"
        int_value = value.to_i? || raise "Invalid layout value: #{value} (must be integer)"
        if int_value < 1
          raise "Layout value must be positive"
        end

        case field
        when "min_width"             then layout.min_width = int_value
        when "context_bar_min_width" then layout.context_bar_min_width = int_value
        when "context_bar_max_width" then layout.context_bar_max_width = int_value
        end
      when "show_cost", "show_model"
        bool_value = case value.downcase
                     when "true", "1", "yes" then true
                     when "false", "0", "no" then false
                     else
                       raise "Invalid boolean value: #{value} (must be true/false)"
                     end

        case field
        when "show_cost"  then layout.show_cost = bool_value
        when "show_model" then layout.show_model = bool_value
        end
      when "directory_style"
        unless VALID_DIRECTORY_STYLES.includes?(value)
          raise "Invalid directory_style: #{value} (must be: #{VALID_DIRECTORY_STYLES.join(", ")})"
        end
        layout.directory_style = value
      else
        raise "Unknown layout field: layout.#{field}"
      end
    end

    private def get_layout(field : String?) : String
      raise "Missing layout field (e.g., layout.min_width)" unless field

      case field
      when "min_width"             then layout.min_width.to_s
      when "context_bar_min_width" then layout.context_bar_min_width.to_s
      when "context_bar_max_width" then layout.context_bar_max_width.to_s
      when "show_cost"             then layout.show_cost.to_s
      when "show_model"            then layout.show_model.to_s
      when "directory_style"       then layout.directory_style
      else
        raise "Unknown layout field: layout.#{field}"
      end
    end

    private def validate_color(value : String)
      # Check for bold: prefix
      color = value.starts_with?("bold:") ? value[5..] : value

      unless VALID_COLORS.includes?(color)
        raise "Invalid color: #{value} (must be: #{VALID_COLORS.join(", ")} or bold:COLOR)"
      end
    end

    protected def self.ensure_config_dir
      Dir.mkdir_p(CONFIG_DIR) unless Dir.exists?(CONFIG_DIR)
    end

    private def ensure_config_dir
      Config.ensure_config_dir
    end
  end
end
