require "json"

module GalaxyTimeline
  class Config
    include JSON::Serializable

    @[JSON::Field(key: "_schema_version")]
    property schema_version : String

    property enabled : Bool

    def initialize(
      @schema_version = GalaxyTimeline::VERSION,
      @enabled = true,
    )
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
