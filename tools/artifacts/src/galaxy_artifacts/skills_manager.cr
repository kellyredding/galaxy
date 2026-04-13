require "file_utils"

module GalaxyArtifacts
  # Manages installation and removal of artifacts-owned skills for Claude Code.
  # Skills are stored as SKILL.md files under Galaxy's territory and symlinked
  # into Claude Code's discovery path (~/.claude/skills/).
  module SkillsManager
    # Marker to identify Galaxy-managed symlinks (checked in readlink target)
    GALAXY_MARKER = ".claude/galaxy"

    ARTIFACT_SKILL = <<-'SKILL'
    ---
    name: galaxy:artifact
    description: >-
      This skill should be used when the user mentions artifacts
      in any way — creating, saving, opening, showing, viewing,
      refreshing, listing, or referencing session artifacts. Trigger
      phrases include "save this as an artifact", "create an
      artifact", "open artifact", "show me that report", "refresh
      the artifact", "list artifacts", "what artifacts do we have",
      "pull up that CSV", or any reference to session-produced files.
    ---

    Manage session artifacts — documents, data exports, diagrams,
    images, and other files produced during a session. Artifacts
    are automatically captured when created via the Write tool,
    or manually registered when created via Bash.

    ## Terminology

    When the user says "open", "show", "view", or "pull up" an
    artifact, they mean **show it in Galaxy.app**. Always use the
    `show` subcommand for this — never the `open` subcommand.

    ## Showing Artifacts

    Show an artifact in Galaxy.app's reader. This is the primary
    way users interact with artifacts. Galaxy.app handles all
    renderable types (markdown, source, CSV, HTML, images, etc.)
    and falls back to the macOS default app for unsupported types.

    ```bash
    galaxy-artifacts show --pid $LEDGER_PID N
    ```

    Use this whenever the user says "open", "show", "view",
    "pull up", or "show me" an artifact.

    ## Creating Artifacts

    Files created via the Write tool are captured automatically —
    do NOT manually save those. Only use manual save for files
    produced by Bash commands (e.g., pandoc, mermaid-cli, python
    scripts, curl downloads):

    ```bash
    galaxy-artifacts save --pid $LEDGER_PID \
      --title "Descriptive title" \
      --source-path /path/to/file \
      --description "Context about what this artifact contains"
    ```

    **Always show after creating.** Parse the artifact number
    from the save output (e.g., "Artifact #3 saved"), then:

    ```bash
    galaxy-artifacts show --pid $LEDGER_PID N
    ```

    The source file is copied to artifact storage. The original
    is left in place. If the same source path was already saved
    in this session, the existing artifact is updated (not
    duplicated).

    ## Refreshing Artifacts

    Re-sync an artifact from its original source file and show
    it in Galaxy.app. Use when the source file has been modified
    and the stored copy is stale:

    ```bash
    galaxy-artifacts refresh --pid $LEDGER_PID N
    ```

    This re-reads the source, updates the stored copy if content
    changed, and publishes a socket event so Galaxy.app opens
    the refreshed artifact automatically.

    ## Listing Artifacts

    Show all artifacts in the current session:

    ```bash
    galaxy-artifacts list --pid $LEDGER_PID
    ```

    Present the results as a clean table to the user with number,
    type, title, and size. If no artifacts exist, let the user
    know.

    ## Reading Artifact Content (Agent Use)

    Read text content into your context so you can answer
    questions about it. This is for agent use — not for
    presenting to the user (use `show` for that):

    ```bash
    galaxy-artifacts view --pid $LEDGER_PID N
    ```

    ## Deleting Artifacts

    ```bash
    galaxy-artifacts delete --pid $LEDGER_PID N
    ```

    ## Referencing Artifacts

    When discussing prior work, reference artifacts by number:
    "Per artifact #2 (User Data Export), the revenue figures
    show..."

    If artifact content isn't in your context, use `view` to
    load it before responding.

    ## Important Notes

    - Artifacts are session-scoped — persist across /clear and
      /compact within the same session
    - Stored on filesystem with metadata in the artifacts
      database
    - Original file always left in place — storage is a copy
    - Auto-captured artifacts get a generated title from
      filename; manually saved artifacts should have
      descriptive titles
    - Creating an artifact always implies showing it afterward
    SKILL

    ARTIFACTS_SKILLS = {
      "galaxy:artifact" => ARTIFACT_SKILL,
    }

    struct SkillInfo
      getter name : String
      getter installed : Bool
      getter source_path : Path
      getter symlink_path : Path

      def initialize(@name, @installed, @source_path, @symlink_path)
      end
    end

    struct SkillsStatus
      getter installed : Bool
      getter skills : Array(SkillInfo)

      def initialize(@installed, @skills)
      end
    end

    # Install all artifacts skills. Idempotent — overwrites content, re-creates
    # symlinks. Skips if a non-Galaxy file/symlink already exists at the
    # target path (won't clobber user-created skills).
    def self.install : Bool
      ARTIFACTS_SKILLS.each do |name, content|
        source_dir = SKILLS_DIR / name
        source_file = source_dir / "SKILL.md"
        symlink_path = CLAUDE_SKILLS_DIR / name

        # Write source file
        Dir.mkdir_p(source_dir)
        File.write(source_file, content)

        # Create/update symlink
        install_symlink(source_dir, symlink_path)
      end
      true
    rescue ex
      STDERR.puts "Error installing skills: #{ex.message}"
      false
    end

    # Remove all artifacts skills. Only removes Galaxy-owned symlinks and
    # source directories. Non-artifacts skills are left untouched.
    def self.uninstall : Bool
      ARTIFACTS_SKILLS.each_key do |name|
        source_dir = SKILLS_DIR / name
        symlink_path = CLAUDE_SKILLS_DIR / name

        # Remove symlink only if it points into Galaxy territory
        if File.symlink?(symlink_path) && galaxy_symlink?(symlink_path)
          File.delete(symlink_path)
        end

        # Remove source directory
        FileUtils.rm_rf(source_dir.to_s) if Dir.exists?(source_dir)
      end

      true
    rescue ex
      STDERR.puts "Error uninstalling skills: #{ex.message}"
      false
    end

    # Check installation status for all artifacts skills.
    def self.status : SkillsStatus
      skill_infos = ARTIFACTS_SKILLS.map do |name, _content|
        source_file = SKILLS_DIR / name / "SKILL.md"
        symlink_path = CLAUDE_SKILLS_DIR / name

        source_ok = File.exists?(source_file)
        symlink_ok = File.symlink?(symlink_path) && galaxy_symlink?(symlink_path)

        SkillInfo.new(
          name: name,
          installed: source_ok && symlink_ok,
          source_path: SKILLS_DIR / name,
          symlink_path: symlink_path,
        )
      end

      SkillsStatus.new(
        installed: skill_infos.all?(&.installed),
        skills: skill_infos,
      )
    end

    # Create or replace a symlink. Skips if a non-Galaxy entity already
    # exists at the target path.
    private def self.install_symlink(source_dir : Path, symlink_path : Path) : Nil
      Dir.mkdir_p(symlink_path.parent)

      if File.symlink?(symlink_path)
        if galaxy_symlink?(symlink_path)
          # Our symlink — delete and re-create to ensure correct target
          File.delete(symlink_path)
        else
          # Someone else's symlink — don't clobber
          STDERR.puts "Warning: #{symlink_path} is a symlink not managed by Galaxy, skipping"
          return
        end
      elsif File.exists?(symlink_path) || Dir.exists?(symlink_path)
        # Regular file or directory — don't clobber
        STDERR.puts "Warning: #{symlink_path} already exists and is not a Galaxy symlink, skipping"
        return
      end

      File.symlink(source_dir.to_s, symlink_path.to_s)
    end

    # Check if a symlink points into Galaxy's territory.
    private def self.galaxy_symlink?(symlink_path : Path) : Bool
      target = File.readlink(symlink_path.to_s)
      target.includes?(GALAXY_MARKER)
    rescue
      false
    end
  end
end
