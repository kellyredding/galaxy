ENV["GALAXY_SKIP_CLI"] = "1"

# Set up test fixtures directory via environment variable
# This must be set BEFORE requiring galaxy so CLAUDE_PERSONA_DIR picks it up
SPEC_FIXTURES = Path[__DIR__] / "fixtures"
ENV["CLAUDE_PERSONA_DIR"] = SPEC_FIXTURES.to_s

require "spec"
require "../src/galaxy"
