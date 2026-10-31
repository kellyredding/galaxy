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
