require "file_utils"

module GalaxySnapshots
  # Manages installation and removal of snapshots-owned skills for Claude Code.
  # Skills are stored as SKILL.md files under Galaxy's territory and symlinked
  # into Claude Code's discovery path (~/.claude/skills/).
  module SkillsManager
    # Marker to identify Galaxy-managed symlinks (checked in readlink target)
    GALAXY_MARKER = ".claude/galaxy"

    SNAPSHOT_SKILL = <<-'SKILL'
    ---
    name: galaxy:snapshot
    description: >-
      This skill should be used when the user asks to "snapshot this",
      "save this exchange", "capture this interaction", "take a
      snapshot", "snapshot our progress", "remember this conversation",
      or wants to preserve important exchanges for future reference
      in the session.
    ---

    Capture and save verbatim conversation exchanges as a session
    snapshot. Snapshots preserve full-fidelity user/assistant
    exchanges and are automatically restored on context handoff
    (/clear, /compact).

    ## Workflow

    ### Step 1 — Determine Scope

    Identify which exchanges to capture. A snapshot should be a
    coherent, self-contained unit:
    - The current exchange (user request + your response)
    - The last N exchanges that form a logical unit
    - A specific exchange the user pointed to

    ### Step 2 — Generate Title

    Create a concise, descriptive title (5-10 words) that clearly
    identifies the snapshot content. Good examples:
    - "Caching strategy for user profiles"
    - "API rate limiting design decision"
    - "Style correction for prose writing"

    ### Step 3 — Format Content

    Format the exchanges as markdown with clear headers:

    ```markdown
    ## Exchange 1

    ### User
    [exact user message]

    ### Assistant
    [exact assistant response]

    ## Exchange 2
    ...
    ```

    Preserve the exact content verbatim — do not summarize or paraphrase.

    ### Step 4 — Save via CLI

    Pipe the formatted markdown to the CLI. The `$LEDGER_PID` comes
    from the "Ledger PID" value in your session context:

    ```bash
    galaxy-snapshots create \
      --pid $LEDGER_PID \
      --title "Generated title here" \
      --exchanges N \
      <<< "formatted markdown content"
    ```

    For multi-line content, use a heredoc:

    ```bash
    galaxy-snapshots create \
      --pid $LEDGER_PID \
      --title "Title" \
      --exchanges 2 \
      <<'SNAPSHOT_EOF'
    ## Exchange 1
    ...content...
    SNAPSHOT_EOF
    ```

    ### Step 5 — Confirm

    After the CLI returns success, confirm to the user:
    "Saved as snapshot #N: 'Title'"

    Creation automatically publishes a socket event so
    Galaxy.app opens the new snapshot in its reader —
    no separate show step is needed.

    ## Showing an Existing Snapshot

    To re-open an already-created snapshot in Galaxy.app's
    reader:

    ```bash
    galaxy-snapshots show --pid $LEDGER_PID N
    ```

    Use this whenever the user says "open", "show", "view",
    "pull up", or "show me" a specific snapshot by number
    or title. Do NOT use it immediately after `create` —
    creation already opens the snapshot.

    ## Viewing & Referencing Snapshots

    - Reference snapshots by number or title when justifying
      decisions: "Per snapshot #1 ('caching design'), we agreed..."
    - If the user asks to view a snapshot's content in your
      own context (for agent use, not user presentation), run:
      `galaxy-snapshots view --pid $LEDGER_PID N`
    - If the user asks to open a snapshot in an external
      editor (not the Galaxy.app reader), run:
      `galaxy-snapshots open --pid $LEDGER_PID N`
    - To list all snapshots:
      `galaxy-snapshots list --pid $LEDGER_PID`
    - To delete:
      `galaxy-snapshots delete --pid $LEDGER_PID N`

    ## Important Notes

    - Snapshots are session-scoped — they persist across /clear and
      /compact within the same session
    - If full snapshot content isn't in your context (over budget),
      use the view command to load it before responding
    - The agent formats the content — the CLI just stores it
    SKILL

    # All snapshots-managed skills: name => SKILL.md content
    SNAPSHOTS_SKILLS = {
      "galaxy:snapshot" => SNAPSHOT_SKILL,
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

    # Install all snapshots skills. Idempotent — overwrites content, re-creates
    # symlinks. Skips if a non-Galaxy file/symlink already exists at the
    # target path (won't clobber user-created skills).
    def self.install : Bool
      SNAPSHOTS_SKILLS.each do |name, content|
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

    # Remove all snapshots skills. Only removes Galaxy-owned symlinks and
    # source directories. Non-snapshots skills are left untouched.
    def self.uninstall : Bool
      SNAPSHOTS_SKILLS.each_key do |name|
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

    # Check installation status for all snapshots skills.
    def self.status : SkillsStatus
      skill_infos = SNAPSHOTS_SKILLS.map do |name, _content|
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
