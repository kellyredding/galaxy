require "file_utils"

module GalaxyLedger
  # Manages installation and removal of ledger-owned skills for Claude Code.
  # Skills are stored as SKILL.md files under Galaxy's territory and symlinked
  # into Claude Code's discovery path (~/.claude/skills/).
  module SkillsManager
    # Marker to identify Galaxy-managed symlinks (checked in readlink target)
    GALAXY_MARKER = "galaxy"

    HANDOFF_SKILL = <<-'SKILL'
    ---
    name: handoff
    description: Review and confirm context handoff after a session reset
    disable-model-invocation: true
    ---

    Review the Session Context Handoff that was injected into your
    context and present a clear summary to the user.

    ## Restore Working Directory (DO THIS FIRST)

    CRITICAL: Before doing anything else, you MUST restore the working
    directory. Run `pwd` to check your current directory, then compare
    it to the Working Directory from the handoff context. If they
    differ, `cd` to the handoff Working Directory immediately. Do NOT
    skip this step — the user needs to pick up exactly where they
    left off. Always report the directory change (or confirmation of
    match) in your summary.

    ## Present the Summary

    Focus on the Last Interaction above all else — this is what the
    user most needs to verify for continuity. Quote what they asked
    and what was accomplished.

    Then briefly note:
    - Which guideline files are active (just file paths, not full rules)
    - Any key decisions captured (with importance level)
    - Session file counts (how many edited/written vs read)

    End with a brief confirmation that context has been handed off
    and you're ready to continue.

    ## No Handoff Available

    If there is no Session Context Handoff in your context (fresh
    session, no clear has happened), tell the user there's nothing
    to hand off yet.

    ## Formatting

    Keep the output concise — this is a quick confirmation the user
    can scan in 5 seconds, not a data dump.
    SKILL

    SPEND_SKILL = <<-'SKILL'
    ---
    name: spend
    description: Show token and cost usage over time
    ---

    Show the user their Claude Code spending and usage data.

    ## Arguments

    The argument after `/spend` is the time period. If no argument
    is given, default to `mtd` (month to date).

    If the argument is `help`, show the available periods:
    `today`, `wtd`, `mtd` (default), `qtd`, `ytd`, `1y`, `all`,
    `YYYY-MM-DD..YYYY-MM-DD`

    ## Execution

    1. Parse the argument as the period
    2. Run `galaxy-ledger spend <period>` via Bash
    3. Display the output verbatim — preserve the sparklines, bar
       charts, and all formatting exactly as rendered by the CLI
    4. After the CLI output, add a brief analysis: trends,
       notable patterns, rate-of-change observations, or
       comparisons — whatever is interesting in the data
    SKILL

    # All ledger-managed skills: name => SKILL.md content
    LEDGER_SKILLS = {
      "handoff" => HANDOFF_SKILL,
      "spend"   => SPEND_SKILL,
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

    # Install all ledger skills. Idempotent — overwrites content, re-creates
    # symlinks. Skips if a non-Galaxy file/symlink already exists at the
    # target path (won't clobber user-created skills).
    def self.install : Bool
      LEDGER_SKILLS.each do |name, content|
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

    # Remove all ledger skills. Only removes Galaxy-owned symlinks and
    # source directories. Non-ledger skills are left untouched.
    def self.uninstall : Bool
      LEDGER_SKILLS.each_key do |name|
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

    # Check installation status for all ledger skills.
    def self.status : SkillsStatus
      skill_infos = LEDGER_SKILLS.map do |name, _content|
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
