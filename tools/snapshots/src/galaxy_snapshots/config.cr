require "json"

module GalaxySnapshots
  class Config
    include JSON::Serializable

    @[JSON::Field(key: "_schema_version")]
    property schema_version : String

    property inline_char_cap : Int32
    property max_per_session : Int32
    property editor : String

    @[JSON::Field(key: "backups")]
    property backups : BackupsConfig

    def initialize(
      @schema_version = GalaxySnapshots::VERSION,
      @inline_char_cap = 15000,
      @max_per_session = 10,
      @editor = "",
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
          GalaxySnapshots::DATA_DIR / "backups" / "snapshots"
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
