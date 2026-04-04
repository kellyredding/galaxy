require "json"

module GalaxySnapshots
  class Config
    include JSON::Serializable

    @[JSON::Field(key: "_schema_version")]
    property schema_version : String

    property inline_char_cap : Int32
    property max_per_session : Int32
    property editor : String

    def initialize(
      @schema_version = GalaxySnapshots::VERSION,
      @inline_char_cap = 15000,
      @max_per_session = 10,
      @editor = "",
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
