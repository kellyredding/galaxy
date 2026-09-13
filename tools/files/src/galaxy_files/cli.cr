module GalaxyFiles
  # `galaxy-files`: an agent's hands on its Galaxy session's file sets —
  # opening files for the user in a set of their own and putting it on screen,
  # reading what every set holds, and the few changes an agent may make.
  #
  # Every rule lives in Galaxy.app, in the Files surface Galactic shares with
  # Assist Ant: which sets an agent may change, what counts as opened, and the
  # words it is told back. This command works out which session is asking,
  # shapes the request and prints the answer — a read's JSON untouched, a
  # change's `message` — so the two apps' commands differ only in spelling.
  module CLI
    def self.run(args : Array(String))
      command = args.first?
      rest = args.size > 1 ? args[1..] : [] of String

      case command
      when "list"   then list(rest)
      when "view"   then view(rest)
      when "open"   then open(rest)
      when "show"   then show(rest)
      when "rename" then rename(rest)
        # Assist Ant's word for the same request, so an agent that learned it
        # there is not refused here.
      when "delete", "remove" then delete(rest)
      when "install"
        if SkillsManager.install
          puts "galaxy-files: skills installed"
        else
          STDERR.puts "Error: install failed"
          exit(1)
        end
      when "uninstall"
        if SkillsManager.uninstall
          puts "galaxy-files: skills uninstalled"
        else
          STDERR.puts "Error: uninstall failed"
          exit(1)
        end
      when "version", "-v", "--version"
        puts "galaxy-files #{VERSION}"
      when nil, "help", "-h", "--help"
        puts help
      else
        STDERR.puts "Error: Unknown command '#{command}'"
        STDERR.puts "Run 'galaxy-files --help' for usage"
        exit(1)
      end
    end

    private def self.list(args : Array(String))
      return puts(list_help) if help?(args)
      pid, words = parse(args, "list")
      abort_usage("list takes no arguments", "list") unless words.empty?
      reply, _ = request(pid, "list", {} of String => JSON::Any)
      puts reply
    end

    private def self.view(args : Array(String))
      return puts(view_help) if help?(args)
      pid, words = parse(args, "view")
      name = one_name(words, "view")
      reply, _ = request(pid, "view", {"name" => JSON::Any.new(name)})
      puts reply
    end

    private def self.open(args : Array(String))
      return puts(open_help) if help?(args)
      pid, words = parse(args, "open")
      name = words.shift? || ""
      abort_usage("a set name is required", "open") if name.strip.empty?
      abort_usage("name at least one file to open", "open") if words.empty?

      paths = words.map { |path| JSON::Any.new(absolute(path)) }
      print_message(request(pid, "open", {
        "name"  => JSON::Any.new(name),
        "paths" => JSON::Any.new(paths),
      })[1])
    end

    private def self.show(args : Array(String))
      return puts(show_help) if help?(args)
      pid, words = parse(args, "show")
      name = one_name(words, "show")
      print_message(request(pid, "show", {"name" => JSON::Any.new(name)})[1])
    end

    private def self.rename(args : Array(String))
      return puts(rename_help) if help?(args)
      pid, words = parse(args, "rename")
      unless words.size == 2
        abort_usage("rename takes the set's name and its new name", "rename")
      end
      print_message(request(pid, "rename", {
        "name"     => JSON::Any.new(words[0]),
        "new_name" => JSON::Any.new(words[1]),
      })[1])
    end

    private def self.delete(args : Array(String))
      return puts(delete_help) if help?(args)
      pid, words = parse(args, "delete")
      name = one_name(words, "delete")
      print_message(request(pid, "remove", {"name" => JSON::Any.new(name)})[1])
    end

    # Ask the app about the session behind `pid`, or print one line and exit
    # non-zero. A refusal is relayed verbatim: only the app knows whose set is
    # whose.
    private def self.request(
      pid : String, operation : String, detail : Hash(String, JSON::Any),
    ) : Tuple(String, JSON::Any)
      ledger_session_id = Ledger.session_id(pid)
      envelope = SocketClient.build_envelope(
        event: "file_set.#{operation}",
        ledger_session_id: ledger_session_id,
        session_identifiers: Ledger.session_identifiers(ledger_session_id),
        detail: detail,
      )
      reply = SocketClient.request(envelope)
      if reply.nil? || reply.empty?
        STDERR.puts "Error: no reply from Galaxy (is the app running?)"
        exit(1)
      end
      ack = JSON.parse(reply)
      unless ack["ok"]?.try(&.as_bool?)
        STDERR.puts "Error: #{ack["error"]?.try(&.as_s?) || "request failed"}"
        exit(1)
      end
      {reply, ack}
    rescue ex : Ledger::Error
      STDERR.puts ex.message
      exit(1)
    rescue JSON::ParseException
      STDERR.puts "Error: Galaxy's reply could not be read"
      exit(1)
    end

    # The sentence the app composed, which names what actually happened rather
    # than what was asked for.
    private def self.print_message(ack : JSON::Any)
      puts ack["message"]?.try(&.as_s?) || "Done."
    end

    # The asking agent's pid and everything that is not a flag. `--` ends the
    # flags, so a path may begin with a dash.
    private def self.parse(
      args : Array(String), sub : String,
    ) : Tuple(String, Array(String))
      pid = ""
      words = [] of String
      flags_done = false
      i = 0
      while i < args.size
        arg = args[i]
        if flags_done
          words << arg
        elsif arg == "--"
          flags_done = true
        elsif arg == "--pid"
          abort_usage("--pid requires a value", sub) unless i + 1 < args.size
          i += 1
          pid = args[i]
        elsif arg.starts_with?("--pid=")
          pid = arg.lchop("--pid=")
        elsif arg.starts_with?("-") && arg.size > 1
          abort_usage("unknown flag '#{arg}'", sub)
        else
          words << arg
        end
        i += 1
      end
      if pid.empty?
        abort_usage("--pid is required (the Ledger PID from your session context)", sub)
      end
      {pid, words}
    end

    private def self.one_name(words : Array(String), sub : String) : String
      abort_usage("#{sub} takes one set name", sub) unless words.size == 1
      abort_usage("the set name is empty", sub) if words[0].strip.empty?
      words[0]
    end

    # Answered before anything is parsed, so help needs no pid.
    private def self.help?(args : Array(String)) : Bool
      args.take_while { |arg| arg != "--" }.any? { |arg| arg == "-h" || arg == "--help" }
    end

    # The app cannot know where the agent is, so a relative path is made
    # absolute here, and `~` expanded for a path quoted past the shell.
    private def self.absolute(path : String) : String
      Path.new(path).expand(base_dir, home: true).to_s
    end

    # The shell's spelling of the working directory when it names the same
    # place: it keeps a symlinked folder's name, which the process's own
    # working directory has already resolved away.
    private def self.base_dir : String
      current = Dir.current
      pwd = ENV["PWD"]?
      return current unless pwd && Path.new(pwd).absolute?
      File.same?(pwd, current, follow_symlinks: true) ? pwd : current
    rescue
      Dir.current
    end

    private def self.abort_usage(message : String, sub : String) : NoReturn
      STDERR.puts "Error: #{message}"
      STDERR.puts "Run 'galaxy-files #{sub} --help' for usage"
      exit(1)
    end

    private def self.help : String
      <<-HELP
      galaxy-files — open files for the user in Galaxy's Files tab

      USAGE:
        galaxy-files <command> --pid PID [arguments]

      COMMANDS:
        list                   Every file set in your session, as JSON.
        view NAME              One set's open files, as JSON.
        open NAME PATH...      Open files in a set (made if new) and show it.
        show NAME              Put a set on screen.
        rename NAME NEW_NAME   Rename a set.
        delete NAME            Delete a set you made that holds no notes.
        install | uninstall    Install or remove the galaxy:files skill.
        version                Print the version.

      Every command that talks to the app needs --pid, the Ledger PID from your
      session context, so Galaxy knows which session is asking. Each Galaxy
      session has its own file sets, and the Default set is the user's own: you
      can view it and show it, but not change it. Set names are matched without
      regard to case.

      Run 'galaxy-files <command> --help' for details.
      HELP
    end

    private def self.list_help : String
      <<-HELP
      galaxy-files list — every file set in your session, as JSON

      USAGE:
        galaxy-files list --pid PID

      DESCRIPTION:
        Prints {"ok":true,"sets":[…]}, one entry per set: its name, whether it
        is the default, its origin ("agent" for sets you made, "user" for the
        user's), how many files are open in it, how many unsent notes it holds,
        and whether it is the selected set.
      HELP
    end

    private def self.view_help : String
      <<-HELP
      galaxy-files view — one set's open files, as JSON

      USAGE:
        galaxy-files view --pid PID NAME

      DESCRIPTION:
        Prints the set's summary, the folder it browses from, and its open
        files in tab order, each with its unsent note count and whether it is
        the file showing. Any set can be viewed, the Default set too.

      EXAMPLES:
        galaxy-files view --pid $LEDGER_PID Default
        galaxy-files view --pid $LEDGER_PID 'auth flow'
      HELP
    end

    private def self.open_help : String
      <<-HELP
      galaxy-files open — open files in a set and put it on screen

      USAGE:
        galaxy-files open --pid PID NAME PATH [PATH...]

      DESCRIPTION:
        Makes the set when none has that name (marked as made by you), opens
        each file in it, and puts the set on screen in the Files tab with the
        first file showing. Opening into a set that exists only adds tabs:
        nothing is closed or moved. The Default set is the user's own and is
        refused.

        When the user is looking at another session, the set is chosen in
        yours and comes up the next time they switch to it; the output says
        which happened.

        Paths may be relative to the current directory, and '~' is expanded.
        Folders, missing files, and files that are neither text nor an image
        are not opened; each is named with its reason. When nothing can be
        opened the command exits non-zero and no set is left behind.

        Put '--' before a path that begins with a dash.

      EXAMPLES:
        galaxy-files open --pid $LEDGER_PID 'auth flow' app/models/user.rb spec/models/user_spec.rb
        galaxy-files open --pid $LEDGER_PID 'build notes' ~/projects/my-app/NOTES.md
      HELP
    end

    private def self.show_help : String
      <<-HELP
      galaxy-files show — put a set on screen

      USAGE:
        galaxy-files show --pid PID NAME

      DESCRIPTION:
        Switches your session's Files tab to the set and brings the tab
        forward, or, when the user is in another session, has it come up at
        their next visit. Works for any set, the Default set included.
      HELP
    end

    private def self.rename_help : String
      <<-HELP
      galaxy-files rename — rename a set

      USAGE:
        galaxy-files rename --pid PID NAME NEW_NAME

      DESCRIPTION:
        Any set but Default can be renamed. Names are unique within a session,
        compared without regard to case or surrounding spaces.
      HELP
    end

    private def self.delete_help : String
      <<-HELP
      galaxy-files delete — delete a set you made

      USAGE:
        galaxy-files delete --pid PID NAME

      DESCRIPTION:
        Closes the set's tabs and removes it; the files on disk are not
        touched. Only a set you made can be deleted, and only while it holds no
        unsent notes. The Default set and sets the user made are refused.
        'remove' is accepted as another name for this command.
      HELP
    end
  end
end
