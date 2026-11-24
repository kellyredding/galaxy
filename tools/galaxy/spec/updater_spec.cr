require "./spec_helper"

describe Galaxy::Updater do
  describe ".parse" do
    it "installs the latest release with no arguments" do
      opts = Galaxy::Updater.parse([] of String)
      opts.local.should be_false
      opts.version.should be_nil
    end

    it "reads --local with and without a path" do
      Galaxy::Updater.parse(["--local"]).local_path.should be_nil
      opts = Galaxy::Updater.parse(["--local", "~/src/galaxy"])
      opts.local.should be_true
      opts.local_path.should eq("~/src/galaxy")
    end

    it "does not take a following option word as the --local path" do
      opts = Galaxy::Updater.parse(["--local", "preview"])
      opts.local_path.should be_nil
      opts.preview.should be_true
    end

    it "strips a leading v from --version" do
      Galaxy::Updater.parse(["--version", "v0.1.0"]).version.should eq("0.1.0")
    end

    it "keeps the old preview, force and help words" do
      opts = Galaxy::Updater.parse(%w[preview force])
      opts.preview.should be_true
      opts.force.should be_true
      Galaxy::Updater.parse(["help"]).help.should be_true
    end

    it "refuses --local together with --version" do
      expect_raises(Galaxy::Updater::ArgumentError, /cannot be combined/) do
        Galaxy::Updater.parse(["--local", "--version", "0.1.0"])
      end
    end

    it "refuses an unknown option" do
      expect_raises(Galaxy::Updater::ArgumentError, /Unknown update option/) do
        Galaxy::Updater.parse(["--everything"])
      end
    end
  end

  describe ".install_args" do
    it "spells options the way install.sh reads them" do
      opts = Galaxy::Updater.parse(["--version", "0.1.0", "preview", "force"])
      Galaxy::Updater.install_args(opts).should eq(
        ["--version", "0.1.0", "--preview", "--force"])
    end
  end

  describe ".resolve_repo" do
    it "finds the git root of a Galaxy checkout from a subdirectory" do
      with_repo(galaxy: true) do |root|
        sub = root / "tools" / "x"
        Dir.mkdir_p(sub)
        Galaxy::Updater.resolve_repo(nil, sub.to_s).should eq(Path.new(File.realpath(root)))
      end
    end

    it "accepts a path relative to the working directory" do
      with_repo(galaxy: true) do |root|
        Galaxy::Updater.resolve_repo(root.basename, root.parent.to_s)
          .should eq(Path.new(File.realpath(root)))
      end
    end

    it "refuses a git repo that is not Galaxy" do
      with_repo(galaxy: false) do |root|
        Galaxy::Updater.resolve_repo(nil, root.to_s).should be_nil
      end
    end

    it "refuses a directory outside any git repo" do
      dir = Path.new(Dir.tempdir) / "galaxy-not-a-repo-#{Random.rand(100000)}"
      Dir.mkdir_p(dir)
      begin
        Galaxy::Updater.resolve_repo(nil, dir.to_s).should be_nil
      ensure
        FileUtils.rm_rf(dir.to_s)
      end
    end
  end

  describe ".run" do
    it "reports a packaging step killed by a signal as 128 + the signal" do
      with_repo(galaxy: true) do |root|
        package = root / "bin" / "package"
        File.write(package, "#!/bin/sh\nkill -TERM $$\n")
        File.chmod(package, 0o755)

        opts = Galaxy::Updater.parse(["--local", root.to_s])
        Galaxy::Updater.run(opts).should eq(128 + Signal::TERM.value)
      end
    end
  end

  describe "galaxy update (the dev binary, with a stand-in curl)" do
    it "runs the downloaded installer with install.sh's flags and exits with its code" do
      pending!("Binary not built") unless File.exists?(UPDATE_BINARY)
      with_fake_curl(%(echo "installer $*"\nexit 7)) do |env|
        code, stdout, stderr = run_update(["--version", "v0.2.0", "preview"], env)
        stderr.should contain("curl -fsSL #{Galaxy::INSTALL_SCRIPT_URL}\n")
        stdout.should eq("installer --version 0.2.0 --preview\n")
        code.should eq(7)
      end
    end

    it "refuses, running nothing, when the installer does not download" do
      pending!("Binary not built") unless File.exists?(UPDATE_BINARY)
      with_fake_curl(nil) do |env|
        code, stdout, stderr = run_update([] of String, env)
        code.should eq(1)
        stdout.should be_empty
        stderr.should contain(
          "Error: could not download the installer from #{Galaxy::INSTALL_SCRIPT_URL} (exit 22).")
      end
    end
  end
end

UPDATE_BINARY = File.expand_path(File.join(__DIR__, "../build/galaxy"))

# A `curl` that prints its arguments to stderr and answers with the given
# installer script, or, given nil, exits 22 as `curl -f` does on an HTTP error.
def with_fake_curl(installer : String?, &)
  root = Path.new(Dir.tempdir) / "galaxy-fake-curl-#{Random.rand(100000)}"
  Dir.mkdir_p(root / "bin")
  body = if installer
           "#!/bin/sh\necho \"curl $*\" >&2\ncat <<'EOF'\n#{installer}\nEOF\n"
         else
           "#!/bin/sh\necho \"curl: (22) The requested URL returned error: 404\" >&2\nexit 22\n"
         end
  File.write(root / "bin" / "curl", body)
  File.chmod(root / "bin" / "curl", 0o755)
  begin
    yield({
      "PATH"       => "#{root / "bin"}:/usr/bin:/bin",
      "HOME"       => root.to_s,
      "GALAXY_DIR" => (root / "galaxy").to_s,
    })
  ensure
    FileUtils.rm_rf(root.to_s)
  end
end

def run_update(args : Array(String), env : Hash(String, String)) : {Int32, String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(UPDATE_BINARY, ["update"] + args,
    output: stdout, error: stderr, env: env, clear_env: true)
  {Galaxy::CLI.exit_code_for(status), stdout.to_s, stderr.to_s}
end

def with_repo(galaxy : Bool, &)
  root = Path.new(Dir.tempdir) / "galaxy-repo-#{Random.rand(100000)}"
  Dir.mkdir_p(root / "bin")
  Process.run("git", ["init", "-q", root.to_s])
  if galaxy
    File.write(root / "bin" / "package", "#!/bin/sh\n")
    File.write(root / "install.sh", "#!/bin/sh\n")
  end
  begin
    yield root
  ensure
    FileUtils.rm_rf(root.to_s)
  end
end
