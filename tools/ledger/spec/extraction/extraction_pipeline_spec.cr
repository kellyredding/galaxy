require "../spec_helper"

# Fast specs for the extraction pipeline.
# These stub ClaudeCLI.run to test parse_extraction_result and the public
# Extraction API without making live Claude CLI calls.

describe "Extraction Pipeline" do
  after_each do
    GalaxyLedger::Extraction::ClaudeCLI.test_response = nil
    GalaxyLedger::Extraction::ClaudeCLI.test_run_result = nil
  end

  # ---------------------------------------------------------------------------
  # User Prompt Extraction
  # ---------------------------------------------------------------------------
  describe ".extract_user_directions" do
    it "returns empty result for empty prompt" do
      result = GalaxyLedger::Extraction.extract_user_directions("")
      result.empty?.should be_true
    end

    it "returns empty result when ClaudeCLI returns nil" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = nil
      # prompt is non-empty but test_response is nil, so run() goes to real
      # call path which would fail — but we can test the empty content guard:
      result = GalaxyLedger::Extraction.extract_user_directions("  ")
      result.empty?.should be_true
    end

    it "parses zero extractions for acknowledgments" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [] of String,
      }.to_json

      result = GalaxyLedger::Extraction.extract_user_directions("yes, that looks good")
      result.extractions.size.should eq(0)
    end

    it "parses direction extractions" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [
          {
            "type"       => "direction",
            "content"    => "Always use trailing commas in multiline arrays",
            "importance" => "medium",
          },
          {
            "type"       => "direction",
            "content"    => "Never use single quotes for strings",
            "importance" => "medium",
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_user_directions("Always use trailing commas")
      result.extractions.size.should eq(2)
      result.extractions.all? { |e| e.entry_type == "direction" }.should be_true
      result.extractions[0].content.should eq("Always use trailing commas in multiline arrays")
      result.extractions[1].importance.should eq("medium")
    end

    it "parses constraint extractions" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [
          {
            "type"       => "constraint",
            "content"    => "Do not modify the legacy API endpoints",
            "importance" => "high",
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_user_directions("Don't modify the legacy API")
      result.extractions.size.should eq(1)
      result.extractions[0].entry_type.should eq("constraint")
      result.extractions[0].importance.should eq("high")
    end

    it "parses preference extractions" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [
          {
            "type"       => "preference",
            "content"    => "Prefer RSpec let! over instance variables",
            "importance" => "medium",
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_user_directions("I prefer let! over instance variables")
      result.extractions.size.should eq(1)
      result.extractions[0].entry_type.should eq("preference")
    end

    it "ignores unrelated JSON fields (session_title etc.)" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "session_title" => "Should Be Ignored",
        "extractions"   => [
          {
            "type"       => "direction",
            "content"    => "Always use trailing commas",
            "importance" => "medium",
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_user_directions("Use trailing commas")
      result.extractions.size.should eq(1)
    end

    it "parses mixed direction and preference extractions" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [
          {
            "type"       => "direction",
            "content"    => "Always run specs before committing",
            "importance" => "high",
          },
          {
            "type"       => "preference",
            "content"    => "Use double quotes for Ruby strings",
            "importance" => "low",
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_user_directions("mixed message")
      result.extractions.size.should eq(2)
      types = result.extractions.map(&.entry_type)
      types.should contain("direction")
      types.should contain("preference")
    end
  end

  # ---------------------------------------------------------------------------
  # Assistant Response Extraction
  # ---------------------------------------------------------------------------
  describe ".extract_assistant_learnings" do
    it "returns empty result for empty content" do
      result = GalaxyLedger::Extraction.extract_assistant_learnings("question", "")
      result.empty?.should be_true
    end

    it "parses learning extractions with summary" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "summary" => {
          "user_request"       => "How does authentication work?",
          "assistant_response" => "Explained the JWT-based auth flow",
          "files_modified"     => [] of String,
          "key_actions"        => ["Analyzed auth middleware", "Traced token flow"],
        },
        "extractions" => [
          {
            "type"       => "learning",
            "content"    => "Auth uses JWT tokens stored in HTTP-only cookies",
            "importance" => "high",
          },
          {
            "type"       => "learning",
            "content"    => "Token refresh happens via a dedicated /refresh endpoint",
            "importance" => "medium",
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_assistant_learnings(
        "How does auth work?",
        "Here's how the auth system works..."
      )
      result.extractions.size.should eq(2)
      result.extractions.all? { |e| e.entry_type == "learning" }.should be_true

      summary = result.summary
      summary.should_not be_nil
      summary.not_nil!.user_request.should eq("How does authentication work?")
      summary.not_nil!.key_actions.size.should eq(2)
    end

    it "parses decision extractions" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "summary" => {
          "user_request"       => "Should we use Redis or Memcached?",
          "assistant_response" => "Chose Redis for its data structure support",
          "files_modified"     => ["config/cache.yml"],
          "key_actions"        => ["Evaluated both options", "Configured Redis"],
        },
        "extractions" => [
          {
            "type"       => "decision",
            "content"    => "Use Redis over Memcached for caching due to data structure support",
            "importance" => "high",
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_assistant_learnings(
        "Should we use Redis or Memcached?",
        "After evaluating both..."
      )
      result.extractions.size.should eq(1)
      result.extractions[0].entry_type.should eq("decision")
      result.extractions[0].importance.should eq("high")
      result.summary.not_nil!.files_modified.should eq(["config/cache.yml"])
    end

    it "parses discovery extractions" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "summary" => {
          "user_request"       => "Why is the build failing?",
          "assistant_response" => "Found deprecated API usage causing build failure",
          "files_modified"     => [] of String,
          "key_actions"        => ["Investigated build logs"],
        },
        "extractions" => [
          {
            "type"       => "discovery",
            "content"    => "The process.wait API was deprecated in Crystal 1.9",
            "importance" => "medium",
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_assistant_learnings(
        "Why is the build failing?",
        "I found the issue..."
      )
      result.extractions.size.should eq(1)
      result.extractions[0].entry_type.should eq("discovery")
    end

    it "handles response with no extractions but valid summary" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "summary" => {
          "user_request"       => "What is 2+2?",
          "assistant_response" => "Answered that 2+2 is 4",
          "files_modified"     => [] of String,
          "key_actions"        => [] of String,
        },
        "extractions" => [] of String,
      }.to_json

      result = GalaxyLedger::Extraction.extract_assistant_learnings("What is 2+2?", "4")
      result.extractions.size.should eq(0)
      result.summary.should_not be_nil
    end

    it "handles response with missing summary" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [
          {
            "type"       => "learning",
            "content"    => "Something learned",
            "importance" => "medium",
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_assistant_learnings("question", "answer")
      result.extractions.size.should eq(1)
      result.summary.should be_nil
    end

    it "ignores session_title in JSON (no longer parsed)" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "session_title" => "Galaxy Ledger Session Title",
        "summary"       => {
          "user_request"       => "Add session titles",
          "assistant_response" => "Added session title extraction",
          "files_modified"     => ["extraction.cr"],
          "key_actions"        => ["Updated prompt"],
        },
        "extractions" => [] of String,
      }.to_json

      result = GalaxyLedger::Extraction.extract_assistant_learnings("Add session titles", "Done")
      result.summary.should_not be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Guideline Extraction
  # ---------------------------------------------------------------------------
  describe ".extract_guidelines" do
    it "returns empty result for empty content" do
      result = GalaxyLedger::Extraction.extract_guidelines("/path/to/file.md", "")
      result.empty?.should be_true
    end

    it "parses guideline extractions with enhanced fields" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [
          {
            "type"         => "guideline",
            "content"      => "Use double quotes for all Ruby strings",
            "importance"   => "medium",
            "category"     => "ruby-style",
            "keywords"     => ["ruby", "strings", "quotes"],
            "applies_when" => "Writing Ruby code",
          },
          {
            "type"         => "guideline",
            "content"      => "Prefer trailing commas in multiline collections",
            "importance"   => "medium",
            "category"     => "ruby-style",
            "keywords"     => ["ruby", "formatting", "collections"],
            "applies_when" => "Writing Ruby code",
          },
          {
            "type"         => "guideline",
            "content"      => "Use frozen string literal magic comment",
            "importance"   => "high",
            "category"     => "ruby-style",
            "keywords"     => ["ruby", "performance", "frozen"],
            "applies_when" => "Writing Ruby code",
          },
          {
            "type"         => "guideline",
            "content"      => "Limit line length to 120 characters",
            "importance"   => "low",
            "category"     => "ruby-style",
            "keywords"     => ["ruby", "formatting", "line-length"],
            "applies_when" => "Writing Ruby code",
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_guidelines(
        "/path/to/ruby-style.md",
        "# Ruby Style Guide\n..."
      )
      result.extractions.size.should eq(4)
      result.extractions.all? { |e| e.entry_type == "guideline" }.should be_true

      # Enhanced fields populated
      first = result.extractions[0]
      first.category.should eq("ruby-style")
      first.applies_when.should eq("Writing Ruby code")
      first.keywords.should_not be_nil
      first.keywords.not_nil!.should contain("ruby")
    end

    it "auto-adds source file stem to keywords" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [
          {
            "type"       => "guideline",
            "content"    => "Use let! for database records",
            "importance" => "medium",
            "keywords"   => ["rspec", "testing", "let"],
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_guidelines(
        "/path/to/rspec-style.md",
        "# RSpec Style\n..."
      )
      # source_file should be the full path
      result.extractions[0].source_file.should eq("/path/to/rspec-style.md")
      # file stem "rspec-style" should be auto-added to keywords
      result.extractions[0].keywords.not_nil!.should contain("rspec-style")
    end

    it "does not duplicate file stem in keywords if already present" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [
          {
            "type"       => "guideline",
            "content"    => "Some rule",
            "importance" => "medium",
            "keywords"   => ["ruby-style", "ruby", "formatting"],
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_guidelines(
        "/path/to/ruby-style.md",
        "content"
      )
      keywords = result.extractions[0].keywords.not_nil!
      keywords.count("ruby-style").should eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  # Implementation Plan Extraction
  # ---------------------------------------------------------------------------
  describe ".extract_implementation_plan" do
    it "returns empty result for empty content" do
      result = GalaxyLedger::Extraction.extract_implementation_plan("/path/to/plan.md", "")
      result.empty?.should be_true
    end

    it "parses implementation_plan extractions with enhanced fields" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [
          {
            "type"         => "implementation_plan",
            "content"      => "Phase 1-3 complete, currently working on Phase 4 (extraction)",
            "importance"   => "high",
            "category"     => "galaxy-ledger",
            "keywords"     => ["galaxy-ledger", "phase-4", "extraction", "progress"],
            "applies_when" => "Working on Galaxy Ledger",
          },
          {
            "type"         => "implementation_plan",
            "content"      => "SQLite chosen over flat files for storage due to FTS5 support",
            "importance"   => "medium",
            "category"     => "galaxy-ledger",
            "keywords"     => ["galaxy-ledger", "sqlite", "storage", "decision"],
            "applies_when" => "Working on Galaxy Ledger",
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_implementation_plan(
        "/path/to/galaxy-ledger-plan.md",
        "# Implementation Plan\n..."
      )
      result.extractions.size.should eq(2)
      result.extractions.all? { |e| e.entry_type == "implementation_plan" }.should be_true

      first = result.extractions[0]
      first.importance.should eq("high")
      first.category.should eq("galaxy-ledger")
      first.applies_when.should eq("Working on Galaxy Ledger")
    end

    it "auto-adds source file stem to keywords" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [
          {
            "type"       => "implementation_plan",
            "content"    => "Some plan context",
            "importance" => "medium",
            "keywords"   => ["planning", "context"],
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_implementation_plan(
        "/plans/2026-01-15_feature.md",
        "plan content"
      )
      result.extractions[0].source_file.should eq("/plans/2026-01-15_feature.md")
      result.extractions[0].keywords.not_nil!.should contain("2026-01-15_feature")
    end
  end

  # ---------------------------------------------------------------------------
  # Edge Cases (parse_extraction_result via public API)
  # ---------------------------------------------------------------------------
  describe "parsing edge cases" do
    it "handles malformed JSON gracefully" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = "not valid json {"

      result = GalaxyLedger::Extraction.extract_user_directions("some input")
      result.empty?.should be_true
    end

    it "handles JSON with missing extractions key" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {"other_key" => "value"}.to_json

      result = GalaxyLedger::Extraction.extract_user_directions("some input")
      result.extractions.size.should eq(0)
    end

    it "handles extractions with missing type (defaults to learning)" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [
          {
            "content"    => "Something without a type",
            "importance" => "medium",
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_assistant_learnings("q", "a")
      result.extractions.size.should eq(1)
      result.extractions[0].entry_type.should eq("learning")
    end

    it "handles extractions with missing importance (defaults to medium)" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [
          {
            "type"    => "direction",
            "content" => "Always use X",
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_user_directions("Always use X")
      result.extractions.size.should eq(1)
      result.extractions[0].importance.should eq("medium")
    end

    it "filters out extractions with invalid entry types" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [
          {
            "type"       => "direction",
            "content"    => "Valid entry",
            "importance" => "medium",
          },
          {
            "type"       => "made_up_type",
            "content"    => "Invalid entry type",
            "importance" => "medium",
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_user_directions("input")
      result.extractions.size.should eq(1)
      result.extractions[0].content.should eq("Valid entry")
    end

    it "filters out extractions with invalid importance levels" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [
          {
            "type"       => "learning",
            "content"    => "Valid importance",
            "importance" => "medium",
          },
          {
            "type"       => "learning",
            "content"    => "Invalid importance",
            "importance" => "critical",
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_assistant_learnings("q", "a")
      result.extractions.size.should eq(1)
      result.extractions[0].content.should eq("Valid importance")
    end

    it "filters out extractions with empty content" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [
          {
            "type"       => "direction",
            "content"    => "Has content",
            "importance" => "medium",
          },
          {
            "type"       => "direction",
            "content"    => "",
            "importance" => "medium",
          },
          {
            "type"       => "direction",
            "content"    => "   ",
            "importance" => "medium",
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_user_directions("input")
      result.extractions.size.should eq(1)
    end

    it "handles nil keywords gracefully" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [
          {
            "type"       => "guideline",
            "content"    => "A guideline without keywords",
            "importance" => "medium",
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_guidelines("/path/to/file.md", "content")
      entry = result.extractions[0]
      # keywords should have the auto-added file stem even when Claude omits keywords
      entry.keywords.not_nil!.should contain("file")
    end

    it "handles summary with empty user_request and assistant_response" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "summary" => {
          "user_request"       => "",
          "assistant_response" => "",
          "files_modified"     => [] of String,
          "key_actions"        => [] of String,
        },
        "extractions" => [] of String,
      }.to_json

      result = GalaxyLedger::Extraction.extract_assistant_learnings("q", "a")
      # Empty summary strings → summary should be nil
      result.summary.should be_nil
    end

    it "parses summary files_modified and key_actions arrays" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "summary" => {
          "user_request"       => "Fix the bug",
          "assistant_response" => "Fixed the null pointer in auth.rb",
          "files_modified"     => ["app/models/user.rb", "spec/models/user_spec.rb"],
          "key_actions"        => ["Added nil guard", "Updated spec"],
        },
        "extractions" => [] of String,
      }.to_json

      result = GalaxyLedger::Extraction.extract_assistant_learnings("Fix the bug", "Fixed it")
      summary = result.summary.not_nil!
      summary.files_modified.size.should eq(2)
      summary.files_modified.should contain("app/models/user.rb")
      summary.key_actions.size.should eq(2)
    end
  end

  # ---------------------------------------------------------------------------
  # ClaudeCLI.run Return Type Behavior
  # ---------------------------------------------------------------------------
  describe "ClaudeCLI.run return type" do
    it "test_response wraps in zero-usage RunResult" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [] of String,
      }.to_json

      run_result = GalaxyLedger::Extraction::ClaudeCLI.run(
        content: "test content",
        prompt: "test prompt",
      )
      run_result[:result].should_not be_nil
      run_result[:cost_usd].should eq(0.0)
      run_result[:input_tokens].should eq(0_i64)
      run_result[:output_tokens].should eq(0_i64)
      run_result[:cache_creation_tokens].should eq(0_i64)
      run_result[:cache_read_tokens].should eq(0_i64)
    end

    it "test_run_result returns full tuple" do
      full_result = GalaxyLedger::Extraction::ClaudeCLI::RunResult.new(
        result: %({"extractions":[]}),
        cost_usd: 0.15,
        input_tokens: 5000_i64,
        output_tokens: 200_i64,
        cache_creation_tokens: 3000_i64,
        cache_read_tokens: 1000_i64,
      )
      GalaxyLedger::Extraction::ClaudeCLI.test_run_result = full_result

      run_result = GalaxyLedger::Extraction::ClaudeCLI.run(
        content: "test content",
        prompt: "test prompt",
      )
      run_result[:result].should eq(%({"extractions":[]}))
      run_result[:cost_usd].should eq(0.15)
      run_result[:input_tokens].should eq(5000_i64)
      run_result[:output_tokens].should eq(200_i64)
      run_result[:cache_creation_tokens].should eq(3000_i64)
      run_result[:cache_read_tokens].should eq(1000_i64)
    end

    it "test_run_result takes precedence over test_response" do
      GalaxyLedger::Extraction::ClaudeCLI.test_response = "should be ignored"
      GalaxyLedger::Extraction::ClaudeCLI.test_run_result = GalaxyLedger::Extraction::ClaudeCLI::RunResult.new(
        result: "from_run_result",
        cost_usd: 0.50,
        input_tokens: 100_i64,
        output_tokens: 50_i64,
        cache_creation_tokens: 0_i64,
        cache_read_tokens: 0_i64,
      )

      run_result = GalaxyLedger::Extraction::ClaudeCLI.run(
        content: "test content",
        prompt: "test prompt",
      )
      run_result[:result].should eq("from_run_result")
      run_result[:cost_usd].should eq(0.50)
    end

    it "returns zero-usage RunResult for empty content" do
      run_result = GalaxyLedger::Extraction::ClaudeCLI.run(
        content: "  ",
        prompt: "test prompt",
      )
      run_result[:result].should be_nil
      run_result[:cost_usd].should eq(0.0)
    end

    it "returns zero-usage RunResult for empty prompt" do
      run_result = GalaxyLedger::Extraction::ClaudeCLI.run(
        content: "test content",
        prompt: "  ",
      )
      run_result[:result].should be_nil
      run_result[:cost_usd].should eq(0.0)
    end
  end

  # ---------------------------------------------------------------------------
  # Usage Data Flow Through Extraction Pipeline
  # ---------------------------------------------------------------------------
  describe "usage data propagation" do
    it "propagates usage to Result via extract_user_directions" do
      GalaxyLedger::Extraction::ClaudeCLI.test_run_result = GalaxyLedger::Extraction::ClaudeCLI::RunResult.new(
        result: {
          "extractions" => [
            {
              "type"       => "direction",
              "content"    => "Always use trailing commas",
              "importance" => "medium",
            },
          ],
        }.to_json,
        cost_usd: 0.15,
        input_tokens: 5000_i64,
        output_tokens: 200_i64,
        cache_creation_tokens: 3000_i64,
        cache_read_tokens: 1000_i64,
      )

      result = GalaxyLedger::Extraction.extract_user_directions("some input")
      result.cost_usd.should eq(0.15)
      result.total_tokens.should eq(9200_i64) # 5000+200+3000+1000
      result.extractions.size.should eq(1)
    end

    it "propagates usage to Result via extract_assistant_learnings" do
      GalaxyLedger::Extraction::ClaudeCLI.test_run_result = GalaxyLedger::Extraction::ClaudeCLI::RunResult.new(
        result: {
          "summary" => {
            "user_request"       => "Test",
            "assistant_response" => "Done",
            "files_modified"     => [] of String,
            "key_actions"        => [] of String,
          },
          "extractions" => [] of String,
        }.to_json,
        cost_usd: 0.25,
        input_tokens: 10000_i64,
        output_tokens: 500_i64,
        cache_creation_tokens: 0_i64,
        cache_read_tokens: 5000_i64,
      )

      result = GalaxyLedger::Extraction.extract_assistant_learnings("q", "a")
      result.cost_usd.should eq(0.25)
      result.total_tokens.should eq(15500_i64)
    end

    it "propagates usage to Result via extract_guidelines" do
      GalaxyLedger::Extraction::ClaudeCLI.test_run_result = GalaxyLedger::Extraction::ClaudeCLI::RunResult.new(
        result: {
          "extractions" => [
            {
              "type"       => "guideline",
              "content"    => "Use double quotes",
              "importance" => "medium",
            },
          ],
        }.to_json,
        cost_usd: 0.10,
        input_tokens: 2000_i64,
        output_tokens: 100_i64,
        cache_creation_tokens: 1000_i64,
        cache_read_tokens: 500_i64,
      )

      result = GalaxyLedger::Extraction.extract_guidelines("/path/to/file.md", "content")
      result.cost_usd.should eq(0.10)
      result.total_tokens.should eq(3600_i64)
    end

    it "propagates usage to Result via extract_implementation_plan" do
      GalaxyLedger::Extraction::ClaudeCLI.test_run_result = GalaxyLedger::Extraction::ClaudeCLI::RunResult.new(
        result: {
          "extractions" => [
            {
              "type"       => "implementation_plan",
              "content"    => "Phase 1 complete",
              "importance" => "high",
            },
          ],
        }.to_json,
        cost_usd: 0.20,
        input_tokens: 8000_i64,
        output_tokens: 400_i64,
        cache_creation_tokens: 2000_i64,
        cache_read_tokens: 3000_i64,
      )

      result = GalaxyLedger::Extraction.extract_implementation_plan("/path/to/plan.md", "content")
      result.cost_usd.should eq(0.20)
      result.total_tokens.should eq(13400_i64)
    end

    it "returns zero usage on nil result" do
      GalaxyLedger::Extraction::ClaudeCLI.test_run_result = GalaxyLedger::Extraction::ClaudeCLI::RunResult.new(
        result: nil,
        cost_usd: 0.05,
        input_tokens: 100_i64,
        output_tokens: 0_i64,
        cache_creation_tokens: 0_i64,
        cache_read_tokens: 0_i64,
      )

      result = GalaxyLedger::Extraction.extract_user_directions("some input")
      result.empty?.should be_true
      # When result is nil, we get a fresh Result.new — zero usage
      result.cost_usd.should eq(0.0)
      result.total_tokens.should eq(0_i64)
    end

    it "zero-usage test_response backward compat preserves existing pipeline tests" do
      # This validates that all existing pipeline tests using test_response
      # still work — the extraction result has zero usage data
      GalaxyLedger::Extraction::ClaudeCLI.test_response = {
        "extractions" => [
          {
            "type"       => "direction",
            "content"    => "Always use trailing commas",
            "importance" => "medium",
          },
        ],
      }.to_json

      result = GalaxyLedger::Extraction.extract_user_directions("some input")
      result.extractions.size.should eq(1)
      result.cost_usd.should eq(0.0)
      result.total_tokens.should eq(0_i64)
    end
  end
end
