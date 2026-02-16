module GalaxyLedger
  # Orchestrates installation of all Galaxy Ledger components (hooks + skills).
  # Provides a single entry point for the unified install/uninstall CLI commands.
  module InstallManager
    struct InstallResult
      getter hooks_ok : Bool
      getter skills_ok : Bool

      def initialize(@hooks_ok, @skills_ok)
      end

      def success? : Bool
        hooks_ok && skills_ok
      end
    end

    struct InstallStatus
      getter hooks : HooksManager::HookStatus
      getter skills : SkillsManager::SkillsStatus

      def initialize(@hooks, @skills)
      end

      def installed? : Bool
        hooks.installed && skills.installed
      end
    end

    def self.install : InstallResult
      hooks_ok = HooksManager.install
      skills_ok = SkillsManager.install
      InstallResult.new(hooks_ok: hooks_ok, skills_ok: skills_ok)
    end

    def self.uninstall : InstallResult
      hooks_ok = HooksManager.uninstall
      skills_ok = SkillsManager.uninstall
      InstallResult.new(hooks_ok: hooks_ok, skills_ok: skills_ok)
    end

    def self.status : InstallStatus
      InstallStatus.new(
        hooks: HooksManager.status,
        skills: SkillsManager.status,
      )
    end
  end
end
