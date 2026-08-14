require "spec"
require "file_utils"

# Use an isolated ~/.claude-equivalent directory for tests
# so skills install/uninstall doesn't touch the real user
# config. The path must contain ".claude/galaxy" for
# SkillsManager.galaxy_symlink? to recognize our symlinks
# as Galaxy-managed (GALAXY_MARKER = ".claude/galaxy").
SPEC_CLAUDE_CONFIG_DIR = Path.new(Dir.tempdir) /
                         "galaxy-diff-test-#{Random.rand(100000)}" /
                         ".claude"
SPEC_GALAXY_DIR = SPEC_CLAUDE_CONFIG_DIR / "galaxy"

# Set env vars BEFORE requiring the module so the
# module-level constants resolve to the test paths.
ENV["GALAXY_CLAUDE_CONFIG_DIR"] = SPEC_CLAUDE_CONFIG_DIR.to_s
ENV["GALAXY_DIR"] = SPEC_GALAXY_DIR.to_s

Dir.mkdir_p(SPEC_CLAUDE_CONFIG_DIR)
Dir.mkdir_p(SPEC_GALAXY_DIR)

# Skip CLI auto-run when loading module for specs.
ENV["GALAXY_DIFF_SKIP_CLI"] = "1"

require "../src/galaxy_diff"

# Helper for running the built binary in integration specs.
# __DIR__ is the spec/ directory, so we go up one level to
# find build/.
BINARY_PATH = Path[__DIR__].parent / "build" / "galaxy-diff"

def run_binary(
  args : Array(String) = [] of String,
  chdir : String? = nil,
  extra_env : Hash(String, String) = {} of String => String,
) : NamedTuple(output: String, error: String, status: Int32)
  unless File.exists?(BINARY_PATH)
    raise "Binary not found at #{BINARY_PATH}. Run 'make dev' first."
  end

  # Unset skip cli if it was set.
  ENV.delete("GALAXY_DIFF_SKIP_CLI")

  base_env = {
    "GALAXY_CLAUDE_CONFIG_DIR" => SPEC_CLAUDE_CONFIG_DIR.to_s,
    "GALAXY_DIR"               => SPEC_GALAXY_DIR.to_s,
    "HOME"                     => ENV["HOME"],
    "PATH"                     => ENV["PATH"],
  }
  merged_env = base_env.merge(extra_env)

  process = Process.new(
    BINARY_PATH.to_s,
    args: args,
    chdir: chdir,
    input: Process::Redirect::Close,
    output: Process::Redirect::Pipe,
    error: Process::Redirect::Pipe,
    env: merged_env,
  )

  output_content = process.output.gets_to_end
  error_content = process.error.gets_to_end
  status = process.wait

  {
    output: output_content,
    error:  error_content,
    status: status.exit_code,
  }
end

# Create a temp git repo for capture specs. Yields the repo
# path; cleans up afterwards. The repo has `user.email` and
# `user.name` set so `git commit` works without global
# config, and starts on the `main` branch for predictable
# metadata.
def with_temp_repo(&)
  dir = (Path.new(Dir.tempdir) /
         "galaxy-diff-repo-#{Random::Secure.hex(6)}").to_s
  Dir.mkdir_p(dir)
  begin
    Process.run("git", ["init", "-q", "-b", "main"], chdir: dir)
    Process.run("git", ["config", "user.email", "t@t.com"], chdir: dir)
    Process.run("git", ["config", "user.name", "t"], chdir: dir)
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

# Write a file shaped like a real binary: NUL bytes early,
# plus high bytes.
#
# The NULs are load-bearing for what this fixture tests. Git
# calls a file binary when it finds a NUL in the first 8000
# bytes, so without them git reports TEXT and only the
# encoding guard in `DiffCapture` ever fires — meaning the
# parser's own binary detection would go untested end to end
# while the specs still passed. A PNG or a Mach-O has NULs;
# so does this.
def write_binary_fixture(path : String, size : Int32 = 256)
  File.open(path, "wb") do |f|
    size.times do |i|
      f.write_byte(i % 4 == 0 ? 0x00_u8 : (0x80 + (i % 0x40)).to_u8)
    end
  end
end

# High bytes with NO NUL, so git reports TEXT. Only the
# encoding guard catches this one — the complement to
# `write_binary_fixture`.
def write_invalid_utf8_fixture(path : String, size : Int32 = 256)
  File.open(path, "wb") do |f|
    size.times { |i| f.write_byte((0x80 + (i % 0x40)).to_u8) }
  end
end

# Write a file git will call TEXT that still cannot be
# embedded: mostly ASCII, with one NUL past git's 8000-byte
# sniff window. `valid_encoding?` accepts NUL, so only the
# explicit NUL check catches this one.
def write_late_nul_fixture(path : String)
  File.open(path, "wb") do |f|
    f.print("A" * 9000)
    f.write_byte(0x00_u8)
    f.print("tail\n")
  end
end

# Helper: commit a file's current state in a repo.
def git_commit(repo : String, message : String)
  Process.run("git", ["add", "-A"], chdir: repo)
  Process.run(
    "git", ["commit", "-q", "-m", message], chdir: repo)
end

# Clean up the test directory after all specs run.
Spec.after_suite do
  FileUtils.rm_rf(SPEC_CLAUDE_CONFIG_DIR.to_s) if Dir.exists?(SPEC_CLAUDE_CONFIG_DIR)
end
