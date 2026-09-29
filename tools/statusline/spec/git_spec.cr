require "./spec_helper"

# Helper to create a temporary git repo for testing
private def create_temp_git_repo : String
  temp_dir = File.tempname("git-test", nil)
  Dir.mkdir(temp_dir)

  # Initialize git repo
  Process.run("git", ["init"], chdir: temp_dir, output: Process::Redirect::Close, error: Process::Redirect::Close)
  Process.run("git", ["config", "user.email", "test@test.com"], chdir: temp_dir, output: Process::Redirect::Close, error: Process::Redirect::Close)
  Process.run("git", ["config", "user.name", "Test"], chdir: temp_dir, output: Process::Redirect::Close, error: Process::Redirect::Close)

  # Create initial commit so we have a branch
  File.write(Path[temp_dir] / "README.md", "# Test")
  Process.run("git", ["add", "README.md"], chdir: temp_dir, output: Process::Redirect::Close, error: Process::Redirect::Close)
  Process.run("git", ["commit", "-m", "Initial commit"], chdir: temp_dir, output: Process::Redirect::Close, error: Process::Redirect::Close)

  temp_dir
end

private def cleanup_temp_dir(dir : String)
  FileUtils.rm_rf(dir) if Dir.exists?(dir)
end

describe GalaxyStatusline::Git do
  describe "#in_git_repo?" do
    it "returns true for a git repository" do
      dir = create_temp_git_repo
      begin
        git = GalaxyStatusline::Git.new(dir)
        git.in_git_repo?.should eq(true)
      ensure
        cleanup_temp_dir(dir)
      end
    end

    it "returns false for a non-git directory" do
      temp_dir = File.tempname("non-git", nil)
      Dir.mkdir(temp_dir)

      begin
        git = GalaxyStatusline::Git.new(temp_dir)
        git.in_git_repo?.should eq(false)
      ensure
        cleanup_temp_dir(temp_dir)
      end
    end

    it "returns false for nil directory" do
      git = GalaxyStatusline::Git.new(nil)
      git.in_git_repo?.should eq(false)
    end
  end

  describe "#branch" do
    it "returns the current branch name" do
      dir = create_temp_git_repo
      begin
        git = GalaxyStatusline::Git.new(dir)
        # Default branch could be main or master depending on git config
        branch = git.branch
        branch.should_not be_nil
        ["main", "master"].should contain(branch)
      ensure
        cleanup_temp_dir(dir)
      end
    end
  end

  describe "#dirty" do
    it "returns false for clean repo" do
      dir = create_temp_git_repo
      begin
        git = GalaxyStatusline::Git.new(dir)
        git.dirty.should eq(false)
      ensure
        cleanup_temp_dir(dir)
      end
    end

    it "returns true for modified tracked files" do
      dir = create_temp_git_repo
      begin
        # Modify a tracked file
        File.write(Path[dir] / "README.md", "# Modified")

        git = GalaxyStatusline::Git.new(dir)
        git.dirty.should eq(true)
      ensure
        cleanup_temp_dir(dir)
      end
    end

    it "returns true for untracked files" do
      dir = create_temp_git_repo
      begin
        # Create an untracked file
        File.write(Path[dir] / "untracked.txt", "new file")

        git = GalaxyStatusline::Git.new(dir)
        git.dirty.should eq(true)
      ensure
        cleanup_temp_dir(dir)
      end
    end

    it "returns true for untracked directories" do
      dir = create_temp_git_repo
      begin
        # Create an untracked directory with a file
        untracked_dir = Path[dir] / "new_directory"
        Dir.mkdir(untracked_dir)
        File.write(untracked_dir / "file.txt", "content")

        git = GalaxyStatusline::Git.new(dir)
        git.dirty.should eq(true)
      ensure
        cleanup_temp_dir(dir)
      end
    end

    it "ignores files in .gitignore" do
      dir = create_temp_git_repo
      begin
        # Create .gitignore
        File.write(Path[dir] / ".gitignore", "ignored.txt\n")
        Process.run("git", ["add", ".gitignore"], chdir: dir, output: Process::Redirect::Close, error: Process::Redirect::Close)
        Process.run("git", ["commit", "-m", "Add gitignore"], chdir: dir, output: Process::Redirect::Close, error: Process::Redirect::Close)

        # Create an ignored file
        File.write(Path[dir] / "ignored.txt", "should be ignored")

        git = GalaxyStatusline::Git.new(dir)
        git.dirty.should eq(false)
      ensure
        cleanup_temp_dir(dir)
      end
    end
  end

  describe "#staged" do
    it "returns false when nothing is staged" do
      dir = create_temp_git_repo
      begin
        git = GalaxyStatusline::Git.new(dir)
        git.staged.should eq(false)
      ensure
        cleanup_temp_dir(dir)
      end
    end

    it "returns true when files are staged" do
      dir = create_temp_git_repo
      begin
        # Create and stage a new file
        File.write(Path[dir] / "staged.txt", "staged content")
        Process.run("git", ["add", "staged.txt"], chdir: dir, output: Process::Redirect::Close, error: Process::Redirect::Close)

        git = GalaxyStatusline::Git.new(dir)
        git.staged.should eq(true)
      ensure
        cleanup_temp_dir(dir)
      end
    end

    it "reads a staged file edited again as both staged and dirty" do
      dir = create_temp_git_repo
      begin
        File.write(Path[dir] / "README.md", "# Staged")
        Process.run("git", ["add", "README.md"], chdir: dir, output: Process::Redirect::Close, error: Process::Redirect::Close)
        File.write(Path[dir] / "README.md", "# Staged, then edited")

        git = GalaxyStatusline::Git.new(dir)
        git.staged.should eq(true)
        git.dirty.should eq(true)
      ensure
        cleanup_temp_dir(dir)
      end
    end

    it "reads a staged file with a clean worktree as staged only" do
      dir = create_temp_git_repo
      begin
        File.write(Path[dir] / "README.md", "# Staged")
        Process.run("git", ["add", "README.md"], chdir: dir, output: Process::Redirect::Close, error: Process::Redirect::Close)

        git = GalaxyStatusline::Git.new(dir)
        git.staged.should eq(true)
        git.dirty.should eq(false)
      ensure
        cleanup_temp_dir(dir)
      end
    end
  end

  describe "reading without writing" do
    # The statusline renders on every turn in the repo an agent is committing
    # in, so a read that takes index.lock fails the agent's write.
    it "never rewrites the index, even for a file whose stat changed" do
      dir = create_temp_git_repo
      begin
        File.touch(Path[dir] / "README.md", Time.utc + 5.seconds)
        index = Path[dir] / ".git" / "index"
        before = File.read(index)

        git = GalaxyStatusline::Git.new(dir)
        git.dirty.should eq(false)
        File.read(index).should eq(before)
      ensure
        cleanup_temp_dir(dir)
      end
    end
  end

  describe ".parse_status" do
    it "reads untracked as dirty" do
      GalaxyStatusline::Git.parse_status("?? new.txt\n").should eq({true, false})
    end

    it "reads the index column as staged and the worktree column as dirty" do
      GalaxyStatusline::Git.parse_status("M  a.txt\n").should eq({false, true})
      GalaxyStatusline::Git.parse_status(" M a.txt\n").should eq({true, false})
      GalaxyStatusline::Git.parse_status("MM a.txt\n").should eq({true, true})
      GalaxyStatusline::Git.parse_status(" D gone.txt\n").should eq({true, false})
      GalaxyStatusline::Git.parse_status("R  old -> new\n").should eq({false, true})
    end

    it "reads nothing as clean" do
      GalaxyStatusline::Git.parse_status("").should eq({false, false})
    end
  end
end
