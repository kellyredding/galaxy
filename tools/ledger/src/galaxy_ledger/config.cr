require "json"

module GalaxyLedger
  class Config
    include JSON::Serializable

    # Schema version for config migration tracking
    # This tracks which version of the schema this config was written with
    @[JSON::Field(key: "_schema_version")]
    property schema_version : String

    # CLI version (for display purposes)
    property version : String
    property thresholds : Thresholds
    property warnings : Warnings
    property extraction : Extraction
    property storage : Storage
    property restoration : Restoration
    property snapshots : Snapshots = Snapshots.new
    property backups : Backups = Backups.new

    class Thresholds
      include JSON::Serializable

      property warning : Int32
      property critical : Int32

      def initialize(@warning = 70, @critical = 85)
      end
    end

    class Warnings
      include JSON::Serializable

      @[JSON::Field(key: "at_warning_threshold")]
      property at_warning_threshold : Bool

      @[JSON::Field(key: "at_critical_threshold")]
      property at_critical_threshold : Bool

      def initialize(
        @at_warning_threshold = true,
        @at_critical_threshold = true,
      )
      end
    end

    class Extraction
      include JSON::Serializable

      @[JSON::Field(key: "on_stop")]
      property on_stop : Bool

      @[JSON::Field(key: "on_guideline_read")]
      property on_guideline_read : Bool

      def initialize(
        @on_stop = true,
        @on_guideline_read = true,
      )
      end
    end

    class Storage
      include JSON::Serializable

      @[JSON::Field(key: "postgres_enabled")]
      property postgres_enabled : Bool

      @[JSON::Field(key: "postgres_host_port")]
      property postgres_host_port : Int32

      @[JSON::Field(key: "embeddings_enabled")]
      property embeddings_enabled : Bool

      @[JSON::Field(key: "openai_api_key_env_var")]
      property openai_api_key_env_var : String

      def initialize(
        @postgres_enabled = false,
        @postgres_host_port = 5433,
        @embeddings_enabled = false,
        @openai_api_key_env_var = "GALAXY_OPENAI_API_KEY",
      )
      end
    end

    class Restoration
      include JSON::Serializable

      @[JSON::Field(key: "max_essential_tokens")]
      property max_essential_tokens : Int32

      @[JSON::Field(key: "tier1_limits")]
      property tier1_limits : Tier1Limits

      @[JSON::Field(key: "tier2_limits")]
      property tier2_limits : Tier2Limits

      def initialize(
        @max_essential_tokens = 2000,
        @tier1_limits = Tier1Limits.new,
        @tier2_limits = Tier2Limits.new,
      )
      end
    end

    class Tier1Limits
      include JSON::Serializable

      @[JSON::Field(key: "high_importance_decisions")]
      property high_importance_decisions : Int32

      def initialize(@high_importance_decisions = 10)
      end
    end

    class Tier2Limits
      include JSON::Serializable

      property learnings : Int32

      @[JSON::Field(key: "medium_importance_decisions")]
      property medium_importance_decisions : Int32

      def initialize(
        @learnings = 5,
        @medium_importance_decisions = 5,
      )
      end
    end

    class Snapshots
      include JSON::Serializable

      @[JSON::Field(key: "inline_char_cap")]
      property inline_char_cap : Int32

      @[JSON::Field(key: "max_per_session")]
      property max_per_session : Int32

      property editor : String

      def initialize(
        @inline_char_cap = 15000,
        @max_per_session = 10,
        @editor = "",
      )
      end
    end

    class Backups
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
      @version = VERSION,
      @thresholds = Thresholds.new,
      @warnings = Warnings.new,
      @extraction = Extraction.new,
      @storage = Storage.new,
      @restoration = Restoration.new,
      @snapshots = Snapshots.new,
      @backups = Backups.new,
    )
    end

    def self.default : Config
      Config.new
    end

    # Resolve the effective backup directory path.
    # Uses the configured path if set, otherwise defaults to DATA_DIR/backups.
    def effective_backup_path : Path
      if backups.path.empty?
        GalaxyLedger::DATA_DIR / "backups"
      else
        Path.new(backups.path)
      end
    end

    def self.load : Config
      ensure_config_dir

      unless File.exists?(CONFIG_FILE)
        config = default
        config.save
        return config
      end

      begin
        json_str = File.read(CONFIG_FILE)
        json = JSON.parse(json_str)

        # Run migrations if needed
        migrated_json, changed = Migrations.migrate_config(json)

        # Parse the (possibly migrated) config
        config = Config.from_json(migrated_json.to_json)

        # Ensure versions are current
        config.version = VERSION
        config.schema_version = VERSION

        # Save if migrations changed anything or if schema_version was missing
        if changed || json["_schema_version"]?.nil?
          config.save
        end

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
      when "thresholds"
        set_threshold(parts[1]?, value)
      when "warnings"
        set_warning(parts[1]?, value)
      when "extraction"
        set_extraction(parts[1]?, value)
      when "storage"
        set_storage(parts[1]?, value)
      when "restoration"
        set_restoration(parts[1]?, parts[2]?, value)
      when "snapshots"
        set_snapshots(parts[1]?, value)
      when "backups"
        set_backups(parts[1]?, value)
      else
        raise "Unknown setting: #{key}"
      end
    end

    def get(key : String) : String
      parts = key.split(".")

      case parts[0]
      when "version"
        version
      when "thresholds"
        get_threshold(parts[1]?)
      when "warnings"
        get_warning(parts[1]?)
      when "extraction"
        get_extraction(parts[1]?)
      when "storage"
        get_storage(parts[1]?)
      when "restoration"
        get_restoration(parts[1]?, parts[2]?)
      when "snapshots"
        get_snapshots(parts[1]?)
      when "backups"
        get_backups(parts[1]?)
      else
        raise "Unknown setting: #{key}"
      end
    end

    private def set_threshold(field : String?, value : String)
      raise "Missing threshold field (e.g., thresholds.warning)" unless field

      int_value = value.to_i? || raise "Invalid threshold value: #{value} (must be integer)"
      unless (0..100).includes?(int_value)
        raise "Threshold must be between 0 and 100"
      end

      case field
      when "warning"  then thresholds.warning = int_value
      when "critical" then thresholds.critical = int_value
      else
        raise "Unknown threshold field: thresholds.#{field}"
      end
    end

    private def get_threshold(field : String?) : String
      raise "Missing threshold field (e.g., thresholds.warning)" unless field

      case field
      when "warning"  then thresholds.warning.to_s
      when "critical" then thresholds.critical.to_s
      else
        raise "Unknown threshold field: thresholds.#{field}"
      end
    end

    private def set_warning(field : String?, value : String)
      raise "Missing warnings field (e.g., warnings.at_warning_threshold)" unless field

      bool_value = parse_bool(value)

      case field
      when "at_warning_threshold"  then warnings.at_warning_threshold = bool_value
      when "at_critical_threshold" then warnings.at_critical_threshold = bool_value
      else
        raise "Unknown warnings field: warnings.#{field}"
      end
    end

    private def get_warning(field : String?) : String
      raise "Missing warnings field (e.g., warnings.at_warning_threshold)" unless field

      case field
      when "at_warning_threshold"  then warnings.at_warning_threshold.to_s
      when "at_critical_threshold" then warnings.at_critical_threshold.to_s
      else
        raise "Unknown warnings field: warnings.#{field}"
      end
    end

    private def set_extraction(field : String?, value : String)
      raise "Missing extraction field (e.g., extraction.on_stop)" unless field

      bool_value = parse_bool(value)

      case field
      when "on_stop"           then extraction.on_stop = bool_value
      when "on_guideline_read" then extraction.on_guideline_read = bool_value
      else
        raise "Unknown extraction field: extraction.#{field}"
      end
    end

    private def get_extraction(field : String?) : String
      raise "Missing extraction field (e.g., extraction.on_stop)" unless field

      case field
      when "on_stop"           then extraction.on_stop.to_s
      when "on_guideline_read" then extraction.on_guideline_read.to_s
      else
        raise "Unknown extraction field: extraction.#{field}"
      end
    end

    private def set_storage(field : String?, value : String)
      raise "Missing storage field (e.g., storage.postgres_enabled)" unless field

      case field
      when "postgres_enabled"
        storage.postgres_enabled = parse_bool(value)
      when "postgres_host_port"
        int_value = value.to_i? || raise "Invalid port value: #{value} (must be integer)"
        storage.postgres_host_port = int_value
      when "embeddings_enabled"
        storage.embeddings_enabled = parse_bool(value)
      when "openai_api_key_env_var"
        storage.openai_api_key_env_var = value
      else
        raise "Unknown storage field: storage.#{field}"
      end
    end

    private def get_storage(field : String?) : String
      raise "Missing storage field (e.g., storage.postgres_enabled)" unless field

      case field
      when "postgres_enabled"       then storage.postgres_enabled.to_s
      when "postgres_host_port"     then storage.postgres_host_port.to_s
      when "embeddings_enabled"     then storage.embeddings_enabled.to_s
      when "openai_api_key_env_var" then storage.openai_api_key_env_var
      else
        raise "Unknown storage field: storage.#{field}"
      end
    end

    private def set_restoration(field : String?, subfield : String?, value : String)
      raise "Missing restoration field (e.g., restoration.max_essential_tokens)" unless field

      case field
      when "max_essential_tokens"
        int_value = value.to_i? || raise "Invalid value: #{value} (must be integer)"
        raise "max_essential_tokens must be positive" if int_value < 1
        restoration.max_essential_tokens = int_value
      when "tier1_limits"
        set_tier1_limit(subfield, value)
      when "tier2_limits"
        set_tier2_limit(subfield, value)
      else
        raise "Unknown restoration field: restoration.#{field}"
      end
    end

    private def set_tier1_limit(field : String?, value : String)
      raise "Missing tier1_limits field (e.g., restoration.tier1_limits.high_importance_decisions)" unless field

      int_value = value.to_i? || raise "Invalid value: #{value} (must be integer)"
      raise "Limit must be positive" if int_value < 1

      case field
      when "high_importance_decisions"
        restoration.tier1_limits.high_importance_decisions = int_value
      else
        raise "Unknown tier1_limits field: #{field}"
      end
    end

    private def set_tier2_limit(field : String?, value : String)
      raise "Missing tier2_limits field (e.g., restoration.tier2_limits.learnings)" unless field

      int_value = value.to_i? || raise "Invalid value: #{value} (must be integer)"
      raise "Limit must be positive" if int_value < 1

      case field
      when "learnings"
        restoration.tier2_limits.learnings = int_value
      when "medium_importance_decisions"
        restoration.tier2_limits.medium_importance_decisions = int_value
      else
        raise "Unknown tier2_limits field: #{field}"
      end
    end

    private def get_restoration(field : String?, subfield : String?) : String
      raise "Missing restoration field (e.g., restoration.max_essential_tokens)" unless field

      case field
      when "max_essential_tokens"
        restoration.max_essential_tokens.to_s
      when "tier1_limits"
        get_tier1_limit(subfield)
      when "tier2_limits"
        get_tier2_limit(subfield)
      else
        raise "Unknown restoration field: restoration.#{field}"
      end
    end

    private def get_tier1_limit(field : String?) : String
      raise "Missing tier1_limits field (e.g., restoration.tier1_limits.high_importance_decisions)" unless field

      case field
      when "high_importance_decisions"
        restoration.tier1_limits.high_importance_decisions.to_s
      else
        raise "Unknown tier1_limits field: #{field}"
      end
    end

    private def get_tier2_limit(field : String?) : String
      raise "Missing tier2_limits field (e.g., restoration.tier2_limits.learnings)" unless field

      case field
      when "learnings"
        restoration.tier2_limits.learnings.to_s
      when "medium_importance_decisions"
        restoration.tier2_limits.medium_importance_decisions.to_s
      else
        raise "Unknown tier2_limits field: #{field}"
      end
    end

    private def set_snapshots(field : String?, value : String)
      raise "Missing snapshots field (e.g., snapshots.inline_char_cap)" unless field

      case field
      when "inline_char_cap"
        int_value = value.to_i? || raise "Invalid value: #{value} (must be integer)"
        raise "Value must be positive" if int_value < 1
        snapshots.inline_char_cap = int_value
      when "max_per_session"
        int_value = value.to_i? || raise "Invalid value: #{value} (must be integer)"
        raise "Value must be positive" if int_value < 1
        snapshots.max_per_session = int_value
      when "editor"
        snapshots.editor = value
      else
        raise "Unknown snapshots field: snapshots.#{field}"
      end
    end

    private def get_snapshots(field : String?) : String
      raise "Missing snapshots field (e.g., snapshots.inline_char_cap)" unless field

      case field
      when "inline_char_cap" then snapshots.inline_char_cap.to_s
      when "max_per_session" then snapshots.max_per_session.to_s
      when "editor"          then snapshots.editor
      else
        raise "Unknown snapshots field: snapshots.#{field}"
      end
    end

    private def set_backups(field : String?, value : String)
      raise "Missing backups field (e.g., backups.enabled)" unless field

      case field
      when "enabled"
        backups.enabled = parse_bool(value)
      when "retention_days"
        int_value = value.to_i? || raise "Invalid value: #{value} (must be integer)"
        raise "Value must be >= 1" if int_value < 1
        backups.retention_days = int_value
      when "path"
        backups.path = value
      else
        raise "Unknown backups field: backups.#{field}"
      end
    end

    private def get_backups(field : String?) : String
      raise "Missing backups field (e.g., backups.enabled)" unless field

      case field
      when "enabled"        then backups.enabled.to_s
      when "retention_days" then backups.retention_days.to_s
      when "path"           then backups.path
      else
        raise "Unknown backups field: backups.#{field}"
      end
    end

    private def parse_bool(value : String) : Bool
      case value.downcase
      when "true", "1", "yes" then true
      when "false", "0", "no" then false
      else
        raise "Invalid boolean value: #{value} (must be true/false)"
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
