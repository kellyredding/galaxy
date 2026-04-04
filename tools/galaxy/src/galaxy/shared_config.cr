require "json"

module Galaxy
  class SharedConfig
    include JSON::Serializable

    @[JSON::Field(key: "_schema_version")]
    property schema_version : String

    property backups : BackupsConfig

    class BackupsConfig
      include JSON::Serializable

      property enabled : Bool
      @[JSON::Field(key: "retention_days")]
      property retention_days : Int32
      property path : String

      def initialize(
        @enabled = true,
        @retention_days = 3,
        @path = "",
      )
      end
    end

    def initialize(
      @schema_version = VERSION,
      @backups = BackupsConfig.new,
    )
    end

    def self.default : SharedConfig
      SharedConfig.new
    end

    # Resolve effective backup directory.
    # Empty path defaults to GALAXY_DIR/data/backups.
    def effective_backup_path : Path
      if backups.path.empty?
        GALAXY_DIR / "data" / "backups"
      else
        Path.new(backups.path)
      end
    end

    def self.load : SharedConfig
      unless File.exists?(CONFIG_FILE)
        config = default
        config.save
        return config
      end

      SharedConfig.from_json(File.read(CONFIG_FILE))
    rescue ex
      STDERR.puts(
        "Warning: Could not parse config, " \
        "using defaults: #{ex.message}"
      )
      default
    end

    def save
      Dir.mkdir_p(GALAXY_DIR) unless Dir.exists?(GALAXY_DIR)
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
      when "backups"
        set_backups(parts[1]?, value)
      else
        raise "Unknown setting: #{key}"
      end
    end

    def get(key : String) : String
      parts = key.split(".")

      case parts[0]
      when "backups"
        get_backups(parts[1]?)
      else
        raise "Unknown setting: #{key}"
      end
    end

    private def set_backups(field : String?, value : String)
      raise(
        "Missing backups field " \
        "(e.g., backups.enabled)"
      ) unless field

      case field
      when "enabled"
        backups.enabled = parse_bool(value)
      when "retention_days"
        int_value = value.to_i? || raise(
          "Invalid value: #{value} (must be integer)"
        )
        raise "Value must be >= 1" if int_value < 1
        backups.retention_days = int_value
      when "path"
        backups.path = value
      else
        raise "Unknown backups field: backups.#{field}"
      end
    end

    private def get_backups(field : String?) : String
      raise(
        "Missing backups field " \
        "(e.g., backups.enabled)"
      ) unless field

      case field
      when "enabled"
        backups.enabled.to_s
      when "retention_days"
        backups.retention_days.to_s
      when "path"
        backups.path
      else
        raise "Unknown backups field: backups.#{field}"
      end
    end

    private def parse_bool(value : String) : Bool
      case value.downcase
      when "true", "1", "yes" then true
      when "false", "0", "no" then false
      else
        raise(
          "Invalid boolean value: #{value} " \
          "(must be true/false)"
        )
      end
    end
  end
end
