require "file_utils"

module GalaxyDiff
  # Manages installation and removal of diff-owned skills for Claude Code.
  # Skills are stored as SKILL.md files under Galaxy's territory and symlinked
  # into Claude Code's discovery path (~/.claude/skills/).
  module SkillsManager
    # Marker to identify Galaxy-managed symlinks (checked in readlink target)
    GALAXY_MARKER = ".claude/galaxy"

    DIFF_SKILL = <<-'SKILL'
    ---
    name: galaxy:diff
    description: >-
      Use when the user wants to capture, review, or annotate code
      changes. Trigger phrases include "capture this diff",
      "snapshot these changes", "review my changes", "diff
      artifact", "create a diff", "show me what changed", or any
      reference to reviewing code diffs in Galaxy.
    ---

    Capture git diffs as annotatable artifacts in Galaxy.app.
    Diffs are stored as `.gdiff` structured snapshots with full
    file contents, syntax highlighting, and line-level
    annotation support.

    ## Capturing a Diff

    Pipeline: `galaxy-diff capture` produces structured JSON,
    piped into `galaxy-artifacts save` for storage.

    ```bash
    galaxy-diff capture [options] | galaxy-artifacts save \
      --pid $LEDGER_PID \
      --filename "DESCRIPTIVE-NAME.gdiff" \
      --title "DESCRIPTIVE TITLE" \
      --artifact-type diff \
      --description "CONTEXT"
    ```

    `save` automatically publishes the show event so Galaxy.app
    opens the new diff in its reader — no separate show step
    is needed. To re-open an existing diff later, use
    `galaxy-artifacts show --pid $LEDGER_PID N`.

    ## Capture Options

    ```bash
    # Limit to specific paths (anything after `--`):
    galaxy-diff capture -- tools/diff GalaxyApp

    # Working tree changes vs HEAD (default):
    galaxy-diff capture

    # Staged changes only:
    galaxy-diff capture --to staged

    # Between two commits:
    galaxy-diff capture --from abc123 --to def456

    # From a specific base:
    galaxy-diff capture --from main
    ```

    ## Naming Guidelines

    **Filename**: A short slug describing WHAT changed, not
    WHERE (branch and ref info are already captured in the
    `.gdiff` metadata). Use lowercase with hyphens. Always
    end with `.gdiff`.

    **Title**: A human-readable version of the filename.
    Should make sense in a list of artifacts without needing
    to open the diff.

    When multiple diffs exist for the same branch or commit
    range, each MUST be distinguishable by name alone. Name
    based on the content/purpose of the changes — think of
    it like writing a commit message for that slice of work:

    ```bash
    # ✅ Good — each is independently identifiable
    --filename "add-timezone-model.gdiff" \
    --title "Add timezone model and migration"

    --filename "wire-dropdown-to-form.gdiff" \
    --title "Wire timezone dropdown to admin form"

    # ❌ Bad — indistinguishable and opaque
    --filename "kr-timezone-fix01.gdiff"
    --filename "kr-timezone-fix01-v2.gdiff"
    ```

    ## What Gets Captured

    The `.gdiff` format includes:
    - Full file contents (before and after) for context
    - Parsed hunk data with line-level change tracking
    - File status (added, modified, deleted, renamed)
    - Whether a file is binary, and its before/after byte
      sizes when it is
    - Syntax highlighting language per file
    - Branch, commit refs, and repository metadata

    Binary files carry no contents — only a size pair, shown
    in the reader as `N bytes -> M bytes`. This is deliberate:
    raw bytes cannot be represented in a JSON string, and
    embedding them produced an artifact the reader could not
    parse at all. Content that is not valid UTF-8 is treated
    the same way even when git calls it text.

    ## When a Capture Is Too Large

    `save` prints a `Note:` when a `.gdiff` exceeds what the
    diff reader will open (5 MB). The artifact is still
    stored, but the reader will decline it.

    The fix is to narrow the capture rather than abandon it —
    pass paths after `--` and save the pieces as separate
    artifacts:

    ```bash
    galaxy-diff capture -- tools/diff | galaxy-artifacts save \
      --pid $LEDGER_PID --filename "changes-tools.gdiff" \
      --title "Changes: tools" --artifact-type diff

    galaxy-diff capture -- GalaxyApp | galaxy-artifacts save \
      --pid $LEDGER_PID --filename "changes-app.gdiff" \
      --title "Changes: app" --artifact-type diff
    ```

    Size runs ahead of intuition because the format stores
    full before *and* after contents plus hunk lines — roughly
    two to three times the changed content. A wide branch
    review reaches the cap on text alone.

    `save` refuses outright — rather than warning — a `.gdiff`
    that is not valid UTF-8 or not valid JSON. That is a
    malformed capture, and storing one only defers the failure
    to whoever opens it later.

    ## Reviewing in Galaxy.app

    Once captured and shown, the diff renders as file cards
    with:
    - Full syntax-highlighted source code
    - Green/red diff overlay on changed lines
    - Character-level change highlighting within lines
    - Line-level annotations (select lines → annotate)

    Annotations flow through the standard artifact review
    pipeline — "Review with Claude" works as with any artifact.
    SKILL

    DIFF_SKILLS = {
      "galaxy:diff" => DIFF_SKILL,
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

    # Install all diff skills. Idempotent — overwrites content, re-creates
    # symlinks. Skips if a non-Galaxy file/symlink already exists at the
    # target path (won't clobber user-created skills).
    def self.install : Bool
      DIFF_SKILLS.each do |name, content|
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

    # Remove all diff skills. Only removes Galaxy-owned symlinks and
    # source directories. Non-diff skills are left untouched.
    def self.uninstall : Bool
      DIFF_SKILLS.each_key do |name|
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

    # Check installation status for all diff skills.
    def self.status : SkillsStatus
      skill_infos = DIFF_SKILLS.map do |name, _content|
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
