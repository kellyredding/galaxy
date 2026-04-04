ENV["GALAXY_SKIP_CLI"] = "1"

# Set up test fixtures directory via environment variable
# This must be set BEFORE requiring galaxy so CLAUDE_PERSONA_DIR picks it up
SPEC_FIXTURES = Path[__DIR__] / "fixtures"
ENV["CLAUDE_PERSONA_DIR"] = SPEC_FIXTURES.to_s

# Use a temporary directory for Galaxy config during tests.
# This prevents specs from reading or writing the real
# ~/.claude/galaxy/config.json.
SPEC_GALAXY_DIR = Path.new(Dir.tempdir) /
                  "galaxy-test-#{Random.rand(100000)}"
ENV["GALAXY_DIR"] = SPEC_GALAXY_DIR.to_s

Dir.mkdir_p(SPEC_GALAXY_DIR)

require "spec"
require "file_utils"
require "../src/galaxy"

# Clean up entire test directory after all specs
Spec.after_suite do
  if Dir.exists?(SPEC_GALAXY_DIR)
    FileUtils.rm_rf(SPEC_GALAXY_DIR.to_s)
  end
end
