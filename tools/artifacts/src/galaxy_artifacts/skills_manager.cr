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
      This skill should be used when the user asks about produced documents,
      wants to see artifacts from the session, asks to "show me that report",
      "open the CSV", "what have we generated", "list artifacts", or wants
      to manage session-produced files.
    ---

    Manage and retrieve session artifacts. Artifacts are documents,
    data exports, diagrams, images, and other files produced during a
    session. They are automatically captured when created via the
    Write tool, or manually registered when created via Bash.

    ## When This Skill Triggers

    Use when the user asks about produced documents or files:
    - "Show me that report from earlier"
    - "What artifacts do we have?"
    - "Open the CSV we generated"
    - "List everything we've produced this session"
    - "Can you pull up that diagram?"

    ## Listing Artifacts

    Show all artifacts in the current session:

    ```bash
    galaxy-artifacts list --pid $LEDGER_PID
    ```

    Present the results as a clean table to the user with number,
    type, title, and size. If no artifacts exist, let the user know.

    ## Viewing Artifacts (Text-Based)

    For text-based artifacts (markdown, csv, text, mermaid, data),
    output content to stdout:

    ```bash
    galaxy-artifacts view --pid $LEDGER_PID N
    ```

    Good for when the user wants to reference content inline or when
    you need to read artifact content to answer a question about it.

    ## Opening Artifacts (Any Type)

    Opens in the appropriate native application (Preview for PDFs/
    images, default browser for HTML, configured editor for text):

    ```bash
    galaxy-artifacts open --pid $LEDGER_PID N
    ```

    Use this when the user says "open it" or "show me" and the
    artifact is binary (PDF, image) or they'd prefer a GUI view.

    ## Manual Save (Bash-Created Files Only)

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

    The source file is copied to artifact storage. The original is
    left in place. If the same source path was already saved in
    this session, the existing artifact is updated (not duplicated).

    ## Deleting Artifacts

    ```bash
    galaxy-artifacts delete --pid $LEDGER_PID N
    ```

    ## Referencing Artifacts

    When discussing prior work, reference artifacts by number:
    "Per artifact #2 (User Data Export), the revenue figures show..."

    If artifact content isn't in your context, use `view` to load
    it before responding.

    ## Important Notes

    - Artifacts are session-scoped — persist across /clear and
      /compact within the same session
    - Stored on filesystem with metadata in the artifacts database
    - Original file always left in place — storage is a copy
    - Binary artifacts (PDF, images) can only be opened, not viewed
      inline — use `open` for those
    - Auto-captured artifacts get a generated title from filename;
      manually saved artifacts should have descriptive titles
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
