require "file_utils"

ENV["GALAXY_SKIP_CLI"] = "1"

# Use a temporary directory for Galaxy config during tests.
# This prevents specs from reading or writing the real
# ~/.claude/galaxy/config.json.
SPEC_GALAXY_DIR = Path.new(Dir.tempdir) /
                  "galaxy-test-#{Random.rand(100000)}"
ENV["GALAXY_DIR"] = SPEC_GALAXY_DIR.to_s

Dir.mkdir_p(SPEC_GALAXY_DIR)

# Fixtures are copied into the temp directory and used from there. The
# delegation specs run the real claude-persona, which migrates any persona
# whose version is older than its own and so rewrote the committed fixture.
# Set before requiring galaxy so CLAUDE_PERSONA_DIR picks it up.
SPEC_FIXTURES = SPEC_GALAXY_DIR / "fixtures"
FileUtils.cp_r((Path[__DIR__] / "fixtures").to_s, SPEC_FIXTURES.to_s)
ENV["CLAUDE_PERSONA_DIR"] = SPEC_FIXTURES.to_s

require "spec"
require "../src/galaxy"

# Clean up entire test directory after all specs
Spec.after_suite do
  if Dir.exists?(SPEC_GALAXY_DIR)
    FileUtils.rm_rf(SPEC_GALAXY_DIR.to_s)
  end
end
