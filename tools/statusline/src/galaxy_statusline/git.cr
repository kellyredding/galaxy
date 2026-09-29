module GalaxyStatusline
  class Git
    getter branch : String?
    getter ahead : Int32
    getter behind : Int32
    getter dirty : Bool
    getter staged : Bool
    getter stashed : Bool
    getter? in_git_repo : Bool

    def initialize(directory : String?)
      @branch = nil
      @ahead = 0
      @behind = 0
      @dirty = false
      @staged = false
      @stashed = false
      @in_git_repo = false

      return unless directory

      # Check if we're in a git repo
      return unless git_repo?(directory)

      @in_git_repo = true
      @branch = get_branch(directory)
      @ahead, @behind = get_ahead_behind(directory)
      @dirty, @staged = get_dirty_staged(directory)
      @stashed = has_stash?(directory)
    end

    def synced? : Bool
      @ahead == 0 && @behind == 0
    end

    def has_upstream? : Bool
      @ahead > 0 || @behind > 0 || synced?
    end

    private def git_repo?(dir : String) : Bool
      result = run_git(dir, ["rev-parse", "--is-inside-work-tree"])
      result[:success] && result[:output].strip == "true"
    end

    private def get_branch(dir : String) : String?
      result = run_git(dir, ["rev-parse", "--abbrev-ref", "HEAD"])
      return nil unless result[:success]

      branch = result[:output].strip
      return nil if branch.empty?

      # Handle detached HEAD
      if branch == "HEAD"
        # Try to get short commit hash
        result = run_git(dir, ["rev-parse", "--short", "HEAD"])
        return result[:success] ? ":" + result[:output].strip : nil
      end

      branch
    end

    private def get_ahead_behind(dir : String) : Tuple(Int32, Int32)
      result = run_git(dir, ["rev-list", "--count", "--left-right", "@{upstream}...HEAD"])
      return {0, 0} unless result[:success]

      parts = result[:output].strip.split(/\s+/)
      return {0, 0} unless parts.size == 2

      behind = parts[0].to_i? || 0
      ahead = parts[1].to_i? || 0
      {ahead, behind}
    end

    # One `status --porcelain`, never `diff --quiet`: MEASURED on git 2.54.0,
    # `diff --quiet` rewrites .git/index for a file whose stat changed,
    # taking index.lock despite --no-optional-locks.
    private def get_dirty_staged(dir : String) : Tuple(Bool, Bool)
      result = run_git(dir, ["status", "--porcelain=v1", "--ignore-submodules=dirty"])
      return {false, false} unless result[:success]
      self.class.parse_status(result[:output])
    end

    # {dirty, staged} from porcelain v1's two columns: X is the index against
    # HEAD, Y the worktree against the index, and `??` an untracked path.
    def self.parse_status(output : String) : Tuple(Bool, Bool)
      dirty = false
      staged = false
      output.each_line do |line|
        next if line.size < 2
        x, y = line[0], line[1]
        if x == '?'
          dirty = true
        else
          staged ||= x != ' '
          dirty ||= y != ' '
        end
      end
      {dirty, staged}
    end

    private def has_stash?(dir : String) : Bool
      result = run_git(dir, ["rev-parse", "--verify", "refs/stash"])
      result[:success]
    end

    private def run_git(dir : String, args : Array(String)) : NamedTuple(success: Bool, output: String)
      io = IO::Memory.new
      err = IO::Memory.new

      # --no-optional-locks makes status skip the opportunistic index.lock
      # it takes to refresh the stat cache (a worktree `diff` refreshes
      # regardless). The statusline renders on every turn against the repo
      # the agent is working in; a refresh races the agent's own git write.
      status = Process.run(
        "git",
        args: ["--no-optional-locks"] + args,
        chdir: dir,
        output: io,
        error: err
      )

      {success: status.success?, output: io.to_s}
    rescue
      {success: false, output: ""}
    end
  end
end
