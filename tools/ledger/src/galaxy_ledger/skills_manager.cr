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
    `wtd`, `mtd` (default), `qtd`, `ytd`, `1y`, `all`,
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
    galaxy-ledger snapshot create \
      --pid $LEDGER_PID \
      --title "Generated title here" \
      --exchanges N \
      <<< "formatted markdown content"
    ```

    For multi-line content, use a heredoc:

    ```bash
    galaxy-ledger snapshot create \
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
    - If the user asks to view a snapshot in the terminal, run:
      `galaxy-ledger snapshot view --pid $LEDGER_PID N`
    - If the user asks to open a snapshot in an editor, run:
      `galaxy-ledger snapshot open --pid $LEDGER_PID N`
      This writes the snapshot to a stable temp file and opens it
      using the configured editor (config, $VISUAL, $EDITOR, or
      macOS `open`). No manual temp file handling needed.
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

    ARTIFACT_SKILL = <<-'SKILL'
    ---
    name: ledger:artifact
    description: >-
      This skill should be used when the user asks about produced documents,
      wants to see artifacts from the session, asks to "show me that report",
      "open the CSV", "what have we generated", "list artifacts", or wants
      to manage session-produced files.
    ---

    Manage and retrieve session artifacts stored in the Galaxy Ledger.
    Artifacts are documents, data exports, diagrams, images, and other
    files produced during a session. They are automatically captured
    when created via the Write tool, or manually registered when
    created via Bash.

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
    galaxy-ledger artifact list --pid $LEDGER_PID
    ```

    Present the results as a clean table to the user with number,
    type, title, and size. If no artifacts exist, let the user know.

    ## Viewing Artifacts (Text-Based)

    For text-based artifacts (markdown, csv, text, mermaid, data),
    output content to stdout:

    ```bash
    galaxy-ledger artifact view --pid $LEDGER_PID N
    ```

    Good for when the user wants to reference content inline or when
    you need to read artifact content to answer a question about it.

    ## Opening Artifacts (Any Type)

    Opens in the appropriate native application (Preview for PDFs/
    images, default browser for HTML, configured editor for text):

    ```bash
    galaxy-ledger artifact open --pid $LEDGER_PID N
    ```

    Use this when the user says "open it" or "show me" and the
    artifact is binary (PDF, image) or they'd prefer a GUI view.

    ## Manual Save (Bash-Created Files Only)

    Files created via the Write tool are captured automatically —
    do NOT manually save those. Only use manual save for files
    produced by Bash commands (e.g., pandoc, mermaid-cli, python
    scripts, curl downloads):

    ```bash
    galaxy-ledger artifact save --pid $LEDGER_PID \
      --title "Descriptive title" \
      --source-path /path/to/file \
      --description "Context about what this artifact contains"
    ```

    The source file is copied to artifact storage. The original is
    left in place. If the same source path was already saved in
    this session, the existing artifact is updated (not duplicated).

    ## Deleting Artifacts

    ```bash
    galaxy-ledger artifact delete --pid $LEDGER_PID N
    ```

    ## Referencing Artifacts

    When discussing prior work, reference artifacts by number:
    "Per artifact #2 (User Data Export), the revenue figures show..."

    If artifact content isn't in your context, use `view` to load
    it before responding.

    ## Important Notes

    - Artifacts are session-scoped — persist across /clear and
      /compact within the same session
    - Stored on filesystem with metadata in the Ledger database
    - Original file always left in place — storage is a copy
    - Binary artifacts (PDF, images) can only be opened, not viewed
      inline — use `open` for those
    - Auto-captured artifacts get a generated title from filename;
      manually saved artifacts should have descriptive titles
    SKILL

    PRUNE_SKILL = <<-'SKILL'
    ---
    name: ledger:prune
    description: >-
      This skill should be used when the user asks to "prune sessions",
      "clean up old data", "prune the ledger", "delete old session
      data", "free up ledger space", "how big is the ledger", "ledger
      maintenance", or wants to remove stale entries and files from
      old sessions.
    ---

    Prune stale entries and file-access records from old Galaxy Ledger
    sessions. Session records, daily usage metrics, snapshots, and
    artifacts are always preserved.

    ## Workflow

    ### Step 1 — Show Options

    Run `galaxy-ledger prune --summary` to get counts for all periods.

    Present the output to the user as a numbered list they can choose
    from:

    ```
    Here's what can be pruned (by last-active date):

     1. Older than 1 week:   12 sessions →    580 entries,    340 files
     2. Older than 2 weeks:  28 sessions →  1,200 entries,    890 files
     3. Older than 1 month:  45 sessions →  2,100 entries,  1,500 files
     ...

    Session records, daily usages, snapshots, and artifacts are always preserved.
    Which timeframe? (enter a number, or "none" to cancel)
    ```

    Skip rows where all counts are 0 — no point showing "Older than
    5 years: 0 sessions" if the ledger is 2 months old.

    If the user specified a period directly ("prune data older than
    6 months"), skip the summary and go straight to Step 2 with that
    period.

    ### Step 2 — Confirm

    After the user picks a number (or gave a specific period):

    Run `galaxy-ledger prune --older-than PERIOD` (preview mode) and
    show the detailed preview. Ask for explicit confirmation before
    proceeding:

    "This will prune 5,500 entries and 4,100 files across 120
    sessions. Session records, daily usages, snapshots, and artifacts
    are preserved. Go ahead?"

    ### Step 3 — Execute

    On confirmation, run:
    `galaxy-ledger prune --older-than PERIOD --apply`

    ### Step 4 — Report

    Present the results to the user:

    "Done — pruned 5,500 entries and 4,100 files across 120 sessions.
    Database: 85 MB → 52 MB."

    ## Period Mapping

    When the user picks a number, map to these CLI periods:
    1 → 1w, 2 → 2w, 3 → 1m, 4 → 2m, 5 → 3m, 6 → 6m, 7 → 1y,
    8 → 2y, 9 → 5y

    ## Important Notes

    - Always show the summary first for vague requests
    - Always confirm before applying — never auto-prune
    - If all counts are 0, tell the user there's nothing to prune
    - The CLI handles VACUUM automatically after pruning
    SKILL

    # All ledger-managed skills: name => SKILL.md content
    LEDGER_SKILLS = {
      "handoff"         => HANDOFF_SKILL,
      "spend"           => SPEND_SKILL,
      "ledger:snapshot" => SNAPSHOT_SKILL,
      "ledger:artifact" => ARTIFACT_SKILL,
      "ledger:prune"    => PRUNE_SKILL,
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
