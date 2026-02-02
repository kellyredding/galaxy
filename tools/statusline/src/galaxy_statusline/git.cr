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
      @dirty = has_dirty?(directory)
      @staged = has_staged?(directory)
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

    private def has_dirty?(dir : String) : Bool
      # Check for modified tracked files
      diff_result = run_git(dir, ["diff", "--quiet"])
      return true unless diff_result[:success]

      # Check for untracked files
      untracked_result = run_git(dir, ["ls-files", "--others", "--exclude-standard"])
      return true unless untracked_result[:output].strip.empty?

      false
    end

    private def has_staged?(dir : String) : Bool
      result = run_git(dir, ["diff", "--cached", "--quiet"])
      !result[:success]
    end

    private def has_stash?(dir : String) : Bool
      result = run_git(dir, ["rev-parse", "--verify", "refs/stash"])
      result[:success]
    end

    private def run_git(dir : String, args : Array(String)) : NamedTuple(success: Bool, output: String)
      io = IO::Memory.new
      err = IO::Memory.new

      status = Process.run(
        "git",
        args: args,
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
