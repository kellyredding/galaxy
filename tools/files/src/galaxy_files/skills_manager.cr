module GalaxyFiles
  # Manages installation and removal of the files skill for Claude Code. The
  # skill is stored as a SKILL.md file under Galaxy's territory and symlinked
  # into Claude Code's discovery path (~/.claude/skills/).
  module SkillsManager
    # Marker to identify Galaxy-managed symlinks (checked in readlink target)
    GALAXY_MARKER = ".claude/galaxy"

    FILES_SKILL = <<-'SKILL'
    ---
    name: galaxy:files
    description: >-
      Open files for the user to read in Galaxy's Files tab, in a file set of
      their own that you put on screen — and list, view, show, rename or delete
      file sets. Use when the user asks to see files you have found or
      discussed ("open those files", "show me that file", "pull those up",
      "let me see them"), or asks what is open in their Files tab.
    ---

    # Open files for the user in a file set

    The Files tab is where the user reads files and leaves notes on them. Each
    Galaxy session has its own **file sets**: every set is its own strip of
    open tabs, and the user switches between them with ⌘P. There is always a
    **Default** set, which is the user's own — you can read it, but you never
    change it. When the user asks to see files, open them in a set of their
    own, so nothing they already had open is disturbed.

    Everything here goes through `galaxy-files`, which talks to Galaxy.app
    about **your session's** sets. Every command takes `--pid $LEDGER_PID` —
    the Ledger PID from your session context — so the app knows which session
    is asking.

    ## Opening files — the usual case

    When the user says "open those files" (or "show me that", "let me see
    them"), open every file you mean in **one call**:

    ```bash
    galaxy-files open --pid $LEDGER_PID '<set name>' <path> [<path> …]
    ```

    - **Name the set for the thread** — short and specific: `auth flow`,
      `retro notes`, `invoice bug`. Keep using that name for more files on the
      same subject: opening into a set that exists only adds tabs, and never
      closes or moves anything.
    - **Paths** may be absolute or relative to your working directory; `~`
      works.
    - The call makes the set if it doesn't exist, opens the files, and puts
      that set on screen in the Files tab with the first file showing. Nothing
      else is needed.
    - If the user is looking at a different session, the set is chosen in
      yours and the Files tab comes up the next time they switch to it — the
      output says which happened.
    - **Relay what it prints.** One line says what opened; each file it could
      not use gets a `Not opened:` line with the reason — missing, a folder,
      not a text file or an image, too large. Tell the user about those rather
      than dropping them.
    - It exits non-zero when nothing could be opened, and leaves no set behind.
      Say why.

    If you aren't sure which sets exist, run
    `galaxy-files list --pid $LEDGER_PID` first. When the user already has a
    set by the name you'd pick, choose another — unless they asked you to add
    to theirs.

    ## Reading what's open

    - `galaxy-files list --pid $LEDGER_PID` — every set in your session as
      JSON: its `name`, whether it is the `default`, its `origin` (`agent` for
      sets you made, `user` for the user's), how many `files` are open in it
      and how many unsent `notes` it holds, and which one is `selected`.
    - `galaxy-files view --pid $LEDGER_PID '<set name>'` — one set's open files
      in tab order, each with its note count and whether it is the file
      showing. The Default set can be viewed like any other; it is how you
      learn what the user is reading.

    ## Other changes

    - `galaxy-files show --pid $LEDGER_PID '<set name>'` — put a set back on
      screen, the Default set included.
    - `galaxy-files rename --pid $LEDGER_PID '<set name>' '<new name>'` — any
      set but Default.
    - `galaxy-files delete --pid $LEDGER_PID '<set name>'` — only a set **you
      made**, and only while it holds no unsent notes. Its tabs close; the
      files on disk are untouched. Delete a set only when the user asks, or to
      tidy up one you made that they are done with.

    ## Notes come back to you

    The user can select lines in any open file and leave notes on them. When
    they send them you receive one message — a review — where each note is
    numbered `[N]` and headed by its file's path and line range, with the
    quoted lines prefixed `>` and the note beneath. Answer it like any other
    request; "on 2" means note `[2]`.

    ## Don't

    - Don't open files the user hasn't asked to see: it changes what is on
      their screen.
    - Don't open files into Default, rename it or delete it — the command
      refuses; it is the user's own.
    - Don't try to delete a set the user made, or one holding notes — refused,
      and those notes are the user's unsent work.
    - Don't pass folders — open the files inside them.
    - Run `galaxy-files <command> --help` for the exact arguments rather than
      guessing.
    SKILL

    FILES_SKILLS = {
      "galaxy:files" => FILES_SKILL,
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

    # Install the skill. Idempotent — overwrites content, re-creates the
    # symlink. Skips if a non-Galaxy file or symlink already exists at the
    # target path (won't clobber user-created skills).
    def self.install : Bool
      FILES_SKILLS.each do |name, content|
        source_dir = SKILLS_DIR / name
        Dir.mkdir_p(source_dir)
        File.write(source_dir / "SKILL.md", content)
        install_symlink(source_dir, CLAUDE_SKILLS_DIR / name)
      end
      true
    rescue ex
      STDERR.puts "Error installing skills: #{ex.message}"
      false
    end

    # Remove the skill. Only removes Galaxy-owned symlinks and source
    # directories.
    def self.uninstall : Bool
      FILES_SKILLS.each_key do |name|
        source_dir = SKILLS_DIR / name
        symlink_path = CLAUDE_SKILLS_DIR / name

        if File.symlink?(symlink_path) && galaxy_symlink?(symlink_path)
          File.delete(symlink_path)
        end

        FileUtils.rm_rf(source_dir.to_s) if Dir.exists?(source_dir)
      end
      true
    rescue ex
      STDERR.puts "Error uninstalling skills: #{ex.message}"
      false
    end

    def self.status : SkillsStatus
      skill_infos = FILES_SKILLS.map do |name, _content|
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

    private def self.install_symlink(source_dir : Path, symlink_path : Path) : Nil
      Dir.mkdir_p(symlink_path.parent)

      if File.symlink?(symlink_path)
        if galaxy_symlink?(symlink_path)
          File.delete(symlink_path)
        else
          STDERR.puts "Warning: #{symlink_path} is a symlink not managed by Galaxy, skipping"
          return
        end
      elsif File.exists?(symlink_path) || Dir.exists?(symlink_path)
        STDERR.puts "Warning: #{symlink_path} already exists and is not a Galaxy symlink, skipping"
        return
      end

      File.symlink(source_dir.to_s, symlink_path.to_s)
    end

    private def self.galaxy_symlink?(symlink_path : Path) : Bool
      File.readlink(symlink_path.to_s).includes?(GALAXY_MARKER)
    rescue
      false
    end
  end
end
