require "file_utils"

module Galaxy
  # `galaxy update`: installs a release through install.sh, or, with --local,
  # packages a checkout and installs that archive through the same script.
  module Updater
    extend self

    record Options,
      local : Bool = false,
      local_path : String? = nil,
      version : String? = nil,
      preview : Bool = false,
      force : Bool = false,
      help : Bool = false

    class ArgumentError < Exception; end

    # The words `preview`, `force` and `help` are kept from the old updater so
    # existing habits and docs keep working.
    def parse(args : Array(String)) : Options
      opts = Options.new
      i = 0
      while i < args.size
        arg = args[i]
        case arg
        when "--local", "local"
          opts = opts.copy_with(local: true)
          if (nxt = args[i + 1]?) && !nxt.starts_with?("-") && !%w[preview force help].includes?(nxt)
            opts = opts.copy_with(local_path: nxt)
            i += 1
          end
        when "--version"
          value = args[i + 1]? || raise ArgumentError.new("--version needs a version, like 0.1.0")
          opts = opts.copy_with(version: value.lchop("v"))
          i += 1
        when "--preview", "preview" then opts = opts.copy_with(preview: true)
        when "--force", "force"     then opts = opts.copy_with(force: true)
        when "--help", "-h", "help" then opts = opts.copy_with(help: true)
        else
          raise ArgumentError.new("Unknown update option '#{arg}'")
        end
        i += 1
      end
      if opts.local && opts.version
        raise ArgumentError.new("--local builds your checkout; it cannot be combined with --version")
      end
      opts
    end

    # The Galaxy checkout to package: the given path, else the git root of
    # the working directory. Nil when that is not a Galaxy repo.
    def resolve_repo(path : String?, cwd : String = Dir.current) : Path?
      start = path ? File.expand_path(path, cwd) : cwd
      return nil unless Dir.exists?(start)

      output = IO::Memory.new
      status = Process.run(
        "git", ["-C", start, "rev-parse", "--show-toplevel"],
        output: output, error: Process::Redirect::Close,
      )
      return nil unless status.success?

      root = Path.new(output.to_s.strip)
      galaxy_repo?(root) ? root : nil
    end

    def galaxy_repo?(root : Path) : Bool
      File.exists?(root / "bin" / "package") && File.exists?(root / "install.sh")
    end

    # Flags for install.sh, in its own spelling.
    def install_args(opts : Options) : Array(String)
      args = [] of String
      if v = opts.version
        args.concat(["--version", v])
      end
      args << "--preview" if opts.preview
      args << "--force" if opts.force
      args
    end

    def run(opts : Options) : Int32
      opts.local ? run_local(opts) : run_release(opts)
    end

    # The script is fetched before bash runs it: piped straight into bash, a
    # failed download is an empty script, which bash runs and exits 0.
    private def run_release(opts : Options) : Int32
      script = IO::Memory.new
      fetched = execute("curl", ["-fsSL", INSTALL_SCRIPT_URL], output: script)
      return 1 unless fetched
      unless fetched.success?
        STDERR.puts "Error: could not download the installer from #{INSTALL_SCRIPT_URL} (#{describe(fetched)})."
        return 1
      end

      script.rewind
      installed = execute("bash", ["-s", "--"] + install_args(opts), input: script)
      installed ? CLI.exit_code_for(installed) : 1
    end

    # Nil, with the reason on stderr, when the command cannot be started.
    private def execute(command : String, args : Array(String),
                        input : Process::Stdio = Process::Redirect::Inherit,
                        output : Process::Stdio = Process::Redirect::Inherit) : Process::Status?
      Process.run(command, args, input: input, output: output, error: :inherit)
    rescue error : File::Error
      STDERR.puts "Error: could not run #{command}: #{error.message}"
      nil
    end

    private def describe(status : Process::Status) : String
      if code = status.exit_code?
        "exit #{code}"
      elsif signal = status.exit_signal?
        "signal #{signal}"
      else
        status.to_s
      end
    end

    private def run_local(opts : Options) : Int32
      repo = resolve_repo(opts.local_path)
      unless repo
        where = opts.local_path || Dir.current
        STDERR.puts "Error: #{where} is not inside a Galaxy checkout (no bin/package and install.sh)."
        return 1
      end

      out_dir = Path.new(Dir.tempdir) / "galaxy-local-#{Process.pid}"
      begin
        package = Process.run(
          (repo / "bin" / "package").to_s, ["--local", "--out", out_dir.to_s],
          input: :inherit, output: :inherit, error: :inherit,
        )
        return CLI.exit_code_for(package) unless package.success?

        archive = out_dir / "galaxy-darwin-arm64.tar.gz"
        CLI.exit_code_for(
          Process.run(
            "bash", [(repo / "install.sh").to_s, "--from", archive.to_s] + install_args(opts),
            input: :inherit, output: :inherit, error: :inherit,
          )
        )
      ensure
        FileUtils.rm_rf(out_dir.to_s)
      end
    end

    def help_text : String
      <<-HELP
      galaxy update - Install the latest Galaxy, or your local changes

      Usage:
        galaxy update                   Install the latest release
        galaxy update --version X.Y.Z   Install that release
        galaxy update --local [PATH]    Build and install a Galaxy checkout
                                        (PATH, else the repo you are in),
                                        uncommitted changes included
        galaxy update preview           Show what would change, change nothing
        galaxy update force             Reinstall even when up to date
        galaxy update help              Show this help

      Updates the CLI tools and ~/Applications/Galaxy.app. A running Galaxy
      keeps running; restart it when you are ready to switch.

      Releases install through #{INSTALL_SCRIPT_URL}
      HELP
    end
  end
end
