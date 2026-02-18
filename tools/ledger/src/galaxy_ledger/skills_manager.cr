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

    SNAPSHOT_SKILL = <<-'SKILL'
    ---
    name: ledger:snapshot
    description: >-
      This skill should be used when the user asks to "snapshot this",
      "save this exchange", "capture this interaction", "take a
      snapshot", "snapshot our progress", "remember this conversation",
      or wants to preserve important exchanges for future reference in
      the session.
    ---

    Capture and save verbatim conversation exchanges as a session
    snapshot in the Galaxy Ledger. Snapshots preserve full-fidelity
    user/assistant exchanges and are automatically restored on
    context handoff (/clear, /compact).

    ## Workflow

    ### Step 1 — Determine Scope

    Based on the user's request, determine how many exchanges back
    to capture. An "exchange" is one user message plus all assistant
    responses before the next user message.

    IMPORTANT: The exchange where the user asked for the snapshot
    is NEVER counted. It is purely operational. Start counting
    backward from the exchange immediately before the snapshot
    request. Any follow-up exchanges for scope negotiation (e.g.,
    the user adjusting your suggestion) are also excluded.

    - If explicit ("snapshot the last 3 exchanges"), use that number
    - If vague ("snapshot this"), make your best guess and ALWAYS
      confirm with the user by listing the user prompts that would
      be included:

      ```
      I'd suggest snapshotting the last 2 exchanges:

      1. Your message: "Let's design the caching layer..."
      2. Your message: "What about Redis vs Memcached..."

      (Each includes my full response.) Does that look right, or
      should I go further back / trim it down?
      ```

    Always confirm scope with the user before proceeding, even when
    the number seems obvious. Truncate listed user messages to ~80
    chars if long.

    ### Step 2 — Generate Title

    Generate a concise, descriptive title (e.g., "Caching layer
    design discussion", "Ruby style correction on trailing commas").
    No user prompting — just pick something reasonable. Timestamps
    provide ordering context.

    ### Step 3 — Format Content

    Format the selected exchanges as clean markdown:

    ```markdown
    ## Exchange 1

    ### User
    [Full user message text]

    ### Assistant
    [Full assistant text response — no tool calls, no thinking blocks]

    ---

    ## Exchange 2
    ...
    ```

    ### Step 4 — Save via CLI

    Pipe the formatted markdown to the CLI. The `$LEDGER_PID` comes
    from the "Ledger PID" value in your session context:

    ```bash
    galaxy-ledger snapshot save \
      --pid $LEDGER_PID \
      --title "Generated title here" \
      --exchanges N \
      <<< "formatted markdown content"
    ```

    For multi-line content, use a heredoc:

    ```bash
    galaxy-ledger snapshot save \
      --pid $LEDGER_PID \
      --title "Title" \
      --exchanges 2 \
      <<'SNAPSHOT_EOF'
    ## Exchange 1
    ...content...
    SNAPSHOT_EOF
    ```

    ### Step 5 — Confirm

    Report to the user: snapshot number, title, exchange count, and
    approximate size. Example:

    "Saved as snapshot #3 — 'Caching layer design discussion'
    (2 exchanges, ~3.2k chars)"

    ## Viewing & Referencing Snapshots

    - Reference snapshots by number or title when justifying
      decisions: "Per snapshot #1 ('caching design'), we agreed..."
    - If the user asks to view a snapshot, run:
      `galaxy-ledger snapshot view --pid $LEDGER_PID N`
    - If the user asks to open a snapshot in an editor, view the
      content via CLI, write it to a temp file (e.g.,
      `/tmp/galaxy-snapshot-N-title-slug.md`), and open with the
      appropriate editor command per the user's guidelines
    - To list all snapshots:
      `galaxy-ledger snapshot list --pid $LEDGER_PID`
    - To delete:
      `galaxy-ledger snapshot delete --pid $LEDGER_PID N`

    ## Important Notes

    - Snapshots are session-scoped — they persist across /clear and
      /compact within the same session
    - If full snapshot content isn't in your context (over budget),
      use the view command to load it before responding
    - The agent formats the content — the CLI just stores it
    SKILL

    # All ledger-managed skills: name => SKILL.md content
    LEDGER_SKILLS = {
      "handoff"         => HANDOFF_SKILL,
      "spend"           => SPEND_SKILL,
      "ledger:snapshot" => SNAPSHOT_SKILL,
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
