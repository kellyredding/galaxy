require "json"

module GalaxyTimeline
  class Config
    include JSON::Serializable

    @[JSON::Field(key: "_schema_version")]
    property schema_version : String

    property enabled : Bool

    @[JSON::Field(key: "backups")]
    property backups : BackupsConfig

    def initialize(
      @schema_version = GalaxyTimeline::VERSION,
      @enabled = true,
      @backups = BackupsConfig.new,
    )
    end

    class BackupsConfig
      include JSON::Serializable

      property enabled : Bool
      property retention_days : Int32
      property path : String

      def initialize(
        @enabled = true,
        @retention_days = 3,
        @path = "",
      )
      end

      def backup_dir : Path
        if path.empty?
          GalaxyTimeline::DATA_DIR / "backups" / "timeline"
        else
          Path.new(path)
        end
      end
    end

    def effective_backup_path : Path
      backups.backup_dir
    end

    def self.load : Config
      path = CONFIG_FILE
      if File.exists?(path)
        Config.from_json(File.read(path))
      else
        config = Config.new
        save(config)
        config
      end
    rescue
      Config.new
    end

    def self.save(config : Config) : Bool
      Dir.mkdir_p(CONFIG_DIR) unless Dir.exists?(CONFIG_DIR)
      File.write(CONFIG_FILE, config.to_pretty_json)
      true
    rescue
      false
    end

    def save : Bool
      Config.save(self)
    end
  end
end
