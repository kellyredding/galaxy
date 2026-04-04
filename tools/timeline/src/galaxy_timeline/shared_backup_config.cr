require "json"

module GalaxyTimeline
  class SharedBackupConfig
    include JSON::Serializable

    property backups : BackupsSection = BackupsSection.new

    class BackupsSection
      include JSON::Serializable

      property enabled : Bool = true
      property retention_days : Int32 = 3
      property path : String = ""

      def initialize(
        @enabled = true,
        @retention_days = 3,
        @path = "",
      )
      end
    end

    def initialize(
      @backups = BackupsSection.new,
    )
    end

    def self.load : SharedBackupConfig
      shared_path = GALAXY_DIR / "config.json"
      if File.exists?(shared_path)
        SharedBackupConfig.from_json(
          File.read(shared_path),
        )
      else
        SharedBackupConfig.new
      end
    rescue
      SharedBackupConfig.new
    end

    def effective_backup_path : Path
      if backups.path.empty?
        GALAXY_DIR / "data" / "backups"
      else
        Path.new(backups.path)
      end
    end
  end
end
