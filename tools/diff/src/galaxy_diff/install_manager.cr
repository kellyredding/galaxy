module GalaxyDiff
  module InstallManager
    def self.install : Bool
      SkillsManager.install
    end

    def self.uninstall : Bool
      SkillsManager.uninstall
    end
  end
end
