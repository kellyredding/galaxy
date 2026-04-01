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
    context, restore full working state, and present a summary.

    Follow these steps in order. Do not skip or reorder steps.

    ## Step 1 — Restore Working Directory

    Run `pwd` to check your current directory, then compare it to
    the Working Directory from the handoff context. If they differ,
    `cd` to the handoff Working Directory immediately. Report the
    result (changed or already correct) in your summary.

    ## Step 2 — Re-Read All Guideline Files

    If the handoff context includes a "Required Reading" section,
    you MUST use the Read tool to re-read every file listed there
    before responding to the user. These are the guideline files
    that were active during the session — they contain rules,
    conventions, and constraints you are expected to follow.

    Do not summarize from memory. Do not skip files because they
    seem familiar. The original files are the source of truth —
    you have not read them yet in this context.

    Read them now, silently. Do not narrate each file read to the
    user.

    ## Step 3 — Read Recent Turns

    Run this command to retrieve the last 5 turn events (replace
    PID with the Ledger PID from the handoff context):

        galaxy-timeline list --pid PID \
          --event-type turn:completed,turn:failed,turn:abandoned,turn:interrupted \
          --limit 5 --reverse --json

    Parse each event's `detail_data` JSON for:
    - `user_message`: what the user asked
    - `assistant_response`: what was accomplished (may be absent
      on failed/abandoned turns)
    - `follow_up_messages`: mid-turn user messages

    Read the full sequence to understand the narrative arc of
    recent work — what the user was doing, what was accomplished,
    and where they left off. If work was incomplete or the
    previous agent left next-step instructions, continue that
    work immediately. If all work was completed, proceed to the
    summary.

    ## Step 4 — Present the Summary

    Focus on the last substantive interaction above all else —
    this is what the user most needs to verify for continuity.
    Quote what they asked and what was accomplished.

    Then briefly note:
    - Guideline files restored (count + file paths, not full
      rules)
    - Any key decisions captured (with importance level)
    - Session file counts (how many edited/written vs read)

    End with a brief confirmation that context has been handed
    off and you're ready to continue.

    ## No Handoff Available

    If there is no Session Context Handoff in your context (fresh
    session, no clear has happened), tell the user there's nothing
    to hand off yet.

    ## Formatting

    Keep the summary output concise — this is a quick confirmation
    the user can scan in 5 seconds, not a data dump. The file reads
    in Step 2 and turn queries in Step 3 are silent background
    work, not part of the output.
    SKILL

    SPEND_SKILL = <<-'SKILL'
    ---
    name: spend
    description: Show token and cost usage over time
    ---

    Show the user their Claude Code spending and usage data.

    ## Arguments

    The argument after `/spend` is the time period. If no argument
    is given, default to `30d` (last 30 days).

    If the argument is `help`, show the available periods:
    `wtd`, `30d` (default), `mtd`, `qtd`, `ytd`, `1y`, `all`,
    `YYYY-MM-DD..YYYY-MM-DD`

    ## Execution

    1. Parse the argument as the period
    2. Run `galaxy-ledger spend <period>` via Bash
    3. **MANDATORY — transcribe the full raw CLI output in a code
       block.** Copy every line of the command output into a fenced
       code block in your response. Do NOT summarize, paraphrase,
       or skip this step. The user must see the exact CLI output
       (sparklines, bar charts, formatting) before anything else.
    4. After the code block, add a brief analysis: trends,
       notable patterns, rate-of-change observations, or
       comparisons — whatever is interesting in the data
    SKILL

    RESUME_SKILL = <<-'SKILL'
    ---
    name: galaxy:resume
    description: Restore working directory and confirm session state after resume
    disable-model-invocation: true
    ---

    Restore session state after a resume. This is lighter than a
    full /handoff — conversation history is already restored by
    Claude Code's --resume flag.

    Follow these steps in order. Do not skip or reorder steps.

    ## Step 1 — Restore Working Directory

    Run `pwd` to check your current directory, then compare it
    to the Working directory from the Galaxy Ledger context
    injected above (look for `**Working directory**` under
    `## Galaxy Ledger`).

    If they differ, `cd` to the Working directory immediately.

    If no Working directory is present in the context, skip
    this step.

    ## Step 2 — Brief Check-In

    Present a one-line confirmation:
    - Working directory status (restored or already correct)
    - Git branch (from the ledger context if available)

    Do NOT re-read guideline files or present a full handoff
    summary — the conversation history is intact on resume.
    Keep this fast and minimal.
    SKILL

    # All ledger-managed skills: name => SKILL.md content
    LEDGER_SKILLS = {
      "handoff"       => HANDOFF_SKILL,
      "spend"         => SPEND_SKILL,
      "galaxy:resume" => RESUME_SKILL,
    }

    # Old skill names to clean up on install (renamed or removed)
    OLD_SKILL_NAMES = [
      "ledger:snapshot",
      "ledger:artifact",
      "ledger:prune",
      "ledger:name",
      "galaxy:artifact", # Moved to galaxy-artifacts tool
      "ledger:resume",   # Renamed to galaxy:resume
    ]

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
      # Clean up old skill names (renamed or removed skills)
      OLD_SKILL_NAMES.each do |old_name|
        old_source = SKILLS_DIR / old_name
        old_symlink = CLAUDE_SKILLS_DIR / old_name

        if File.symlink?(old_symlink) && galaxy_symlink?(old_symlink)
          File.delete(old_symlink)
        end
        FileUtils.rm_rf(old_source.to_s) if Dir.exists?(old_source)
      end

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
      # Uninstall current skills
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

      # Also clean up any old skill names
      OLD_SKILL_NAMES.each do |old_name|
        old_source = SKILLS_DIR / old_name
        old_symlink = CLAUDE_SKILLS_DIR / old_name

        if File.symlink?(old_symlink) && galaxy_symlink?(old_symlink)
          File.delete(old_symlink)
        end
        FileUtils.rm_rf(old_source.to_s) if Dir.exists?(old_source)
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
