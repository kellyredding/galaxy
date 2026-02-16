require "../spec_helper"

# Helper to create a test session with database entries.
# Returns the ledger_session_id (Int64) for use in subsequent DB calls.
def create_test_session_with_entries(session_id : String, entry_count : Int32 = 3) : Int64
  # Create session record first to satisfy FK constraint on ledger_entries
  ledger_session_id = GalaxyLedger::Database.create_session(session_id)

  entry_count.times do |i|
    entry = GalaxyLedger::Entry.new(
      entry_type: "learning",
      content: "Test learning #{i + 1}",
      importance: "medium",
      created_at: "2026-02-01T10:0#{i}:00Z"
    )
    GalaxyLedger::Database.insert(ledger_session_id, entry)
  end

  ledger_session_id
end

describe "CLI Integration" do
  describe "version subcommand" do
    it "outputs version" do
      result = run_binary(["version"])
      result[:output].should contain(GalaxyLedger::VERSION)
      result[:status].should eq(0)
    end
  end

  describe "--version flag" do
    it "outputs version" do
      result = run_binary(["--version"])
      result[:output].should contain(GalaxyLedger::VERSION)
      result[:status].should eq(0)
    end
  end

  describe "help subcommand" do
    it "outputs usage information" do
      result = run_binary(["help"])
      result[:output].should contain("galaxy-ledger")
      result[:output].should contain("Commands:")
      result[:status].should eq(0)
    end
  end

  describe "--help flag" do
    it "outputs usage information" do
      result = run_binary(["--help"])
      result[:output].should contain("galaxy-ledger")
      result[:status].should eq(0)
    end
  end

  describe "no arguments" do
    it "shows help when no arguments provided" do
      result = run_binary([] of String)
      result[:output].should contain("galaxy-ledger")
      result[:output].should contain("Commands:")
      result[:status].should eq(0)
    end
  end

  describe "unknown command" do
    it "outputs error and exits non-zero" do
      result = run_binary(["unknown"])
      result[:error].should contain("Unknown command")
      result[:status].should_not eq(0)
    end
  end

  describe "config subcommand" do
    describe "config (no args)" do
      it "outputs current config as JSON" do
        result = run_binary(["config"])
        result[:output].should contain("version")
        result[:output].should contain("thresholds")
        result[:output].should contain("warnings")
        result[:status].should eq(0)
      end
    end

    describe "config path" do
      it "outputs config file path" do
        result = run_binary(["config", "path"])
        result[:output].should contain("config.json")
        result[:status].should eq(0)
      end
    end

    describe "config help" do
      it "outputs configuration documentation" do
        result = run_binary(["config", "help"])
        result[:output].should contain("AVAILABLE SETTINGS")
        result[:output].should contain("thresholds")
        result[:output].should contain("warnings")
        result[:status].should eq(0)
      end
    end

    describe "config set KEY VALUE" do
      it "updates config" do
        result = run_binary(["config", "set", "thresholds.warning", "75"])
        result[:output].should contain("Set thresholds.warning")
        result[:status].should eq(0)

        # Verify it was set
        result = run_binary(["config", "get", "thresholds.warning"])
        result[:output].strip.should eq("75")
      end

      it "handles nested keys" do
        result = run_binary(["config", "set", "storage.postgres_enabled", "true"])
        result[:status].should eq(0)

        result = run_binary(["config", "get", "storage.postgres_enabled"])
        result[:output].strip.should eq("true")
      end

      it "handles deeply nested keys" do
        result = run_binary(["config", "set", "restoration.tier2_limits.learnings", "8"])
        result[:status].should eq(0)

        result = run_binary(["config", "get", "restoration.tier2_limits.learnings"])
        result[:output].strip.should eq("8")
      end

      it "outputs error for invalid value" do
        result = run_binary(["config", "set", "thresholds.warning", "invalid"])
        result[:error].should contain("must be integer")
        result[:status].should_not eq(0)
      end
    end

    describe "config get KEY" do
      it "outputs value for valid key" do
        result = run_binary(["config", "get", "thresholds.warning"])
        result[:status].should eq(0)
        result[:output].should_not be_empty
      end

      it "outputs error for invalid key" do
        result = run_binary(["config", "get", "nonexistent"])
        result[:error].should contain("Unknown")
        result[:status].should_not eq(0)
      end
    end

    describe "config reset" do
      it "resets config to defaults" do
        # First change something
        run_binary(["config", "set", "thresholds.warning", "80"])

        # Reset
        result = run_binary(["config", "reset"])
        result[:output].should contain("reset to defaults")
        result[:status].should eq(0)

        # Verify it's back to default
        result = run_binary(["config", "get", "thresholds.warning"])
        result[:output].strip.should eq("70")
      end
    end
  end

  describe "on-startup subcommand" do
    it "outputs JSON with systemMessage and additionalContext" do
      hook_input = {"session_id" => "cli-startup-#{rand(100000)}"}.to_json
      result = run_binary(["on-startup"], stdin: hook_input)
      result[:status].should eq(0)

      # Parse the output as JSON
      output = JSON.parse(result[:output])
      output["systemMessage"].should be_a(JSON::Any)
      output["hookSpecificOutput"]["hookEventName"].should eq("SessionStart")
      output["hookSpecificOutput"]["additionalContext"].as_s.should contain("## Galaxy Ledger")
    end

    it "includes ledger awareness information" do
      hook_input = {"session_id" => "cli-startup-aware-#{rand(100000)}"}.to_json
      result = run_binary(["on-startup"], stdin: hook_input)
      result[:status].should eq(0)

      output = JSON.parse(result[:output])
      context = output["hookSpecificOutput"]["additionalContext"].as_s
      context.should contain("persistent context ledger")
      context.should contain("galaxy-ledger search")
    end
  end

  describe "search subcommand" do
    before_each do
      # Clean database for isolation
      db_path = GalaxyLedger::Database.database_path
      File.delete(db_path) if File.exists?(db_path)
    end

    it "searches for entries with --query flag" do
      # Add entries via add command
      run_binary(["add", "--type", "learning", "--content", "JWT tokens expire after 15 minutes"])
      run_binary(["add", "--type", "decision", "--content", "Using Redis for session caching"])

      result = run_binary(["search", "--query", "JWT"])
      result[:status].should eq(0)
      result[:output].should contain("Search results")
      result[:output].should contain("JWT tokens")
    end

    it "shows no results message when nothing matches" do
      run_binary(["add", "--type", "learning", "--content", "Something else entirely"])

      result = run_binary(["search", "--query", "nonexistent"])
      result[:status].should eq(0)
      result[:output].should contain("No results found")
    end

    it "shows help when no arguments provided" do
      result = run_binary(["search"])
      result[:status].should eq(0)
      result[:output].should contain("USAGE")
      result[:output].should contain("--query")
    end

    it "shows help with --help flag" do
      result = run_binary(["search", "--help"])
      result[:status].should eq(0)
      result[:output].should contain("USAGE")
      result[:output].should contain("--query QUERY")
      result[:output].should contain("EXAMPLES")
    end

    it "shows help with -h flag" do
      result = run_binary(["search", "-h"])
      result[:status].should eq(0)
      result[:output].should contain("USAGE")
    end

    it "shows error when --query is missing" do
      result = run_binary(["search", "--type", "learning"])
      result[:error].should contain("--query is required")
      result[:status].should_not eq(0)
    end

    it "can search for literal --help with --query flag (does not show help)" do
      # The key test here is that --query "--help" performs a search,
      # not that it shows help documentation
      result = run_binary(["search", "--query", "--help"])
      result[:status].should eq(0)
      # Should attempt search, not show help text
      # Output will be "No results found" or "Search results" - either is fine
      # It should NOT contain "USAGE:" which indicates help was shown
      result[:output].should_not contain("USAGE:")
      result[:output].should_not contain("REQUIRED:")
    end

    it "shows error for unknown option" do
      result = run_binary(["search", "--unknown", "value"])
      result[:error].should contain("Unknown option")
      result[:status].should_not eq(0)
    end
  end

  describe "list subcommand" do
    before_each do
      # Clean database for isolation
      db_path = GalaxyLedger::Database.database_path
      File.delete(db_path) if File.exists?(db_path)
    end

    it "lists recent entries" do
      run_binary(["add", "--type", "learning", "--content", "First learning"])
      run_binary(["add", "--type", "decision", "--content", "First decision"])

      result = run_binary(["list"])
      result[:status].should eq(0)
      result[:output].should contain("Recent ledger entries")
      result[:output].should contain("learning")
      result[:output].should contain("decision")
    end

    it "shows empty message when no entries" do
      result = run_binary(["list"])
      result[:status].should eq(0)
      result[:output].should contain("No entries in ledger")
    end

    it "respects --limit flag" do
      5.times do |i|
        run_binary(["add", "--type", "learning", "--content", "Learning number #{i + 1}"])
      end

      result = run_binary(["list", "--limit", "2"])
      result[:status].should eq(0)
      result[:output].should contain("showing 2 of 5")
    end

    it "respects positional limit argument for backwards compatibility" do
      5.times do |i|
        run_binary(["add", "--type", "learning", "--content", "Learning number #{i + 1}"])
      end

      result = run_binary(["list", "2"])
      result[:status].should eq(0)
      result[:output].should contain("showing 2 of 5")
    end

    it "shows help with --help flag" do
      result = run_binary(["list", "--help"])
      result[:status].should eq(0)
      result[:output].should contain("USAGE")
      result[:output].should contain("--limit N")
      result[:output].should contain("--type TYPE")
    end

    it "shows help with -h flag" do
      result = run_binary(["list", "-h"])
      result[:status].should eq(0)
      result[:output].should contain("USAGE")
    end
  end

  describe "add subcommand" do
    before_each do
      # Clean database for isolation
      db_path = GalaxyLedger::Database.database_path
      File.delete(db_path) if File.exists?(db_path)
    end

    it "adds a learning entry with --type and --content flags" do
      result = run_binary(["add", "--type", "learning", "--content", "Test learning content"])
      result[:status].should eq(0)
      result[:output].should contain("Added learning to ledger")
      result[:output].should contain("Test learning content")
    end

    it "adds a decision entry" do
      result = run_binary(["add", "--type", "decision", "--content", "We decided to use SQLite"])
      result[:status].should eq(0)
      result[:output].should contain("Added decision to ledger")
    end

    it "adds a direction entry" do
      result = run_binary(["add", "--type", "direction", "--content", "Always use trailing commas"])
      result[:status].should eq(0)
      result[:output].should contain("Added direction to ledger")
    end

    it "supports --importance flag" do
      result = run_binary(["add", "--type", "learning", "--content", "Important learning", "--importance", "high"])
      result[:status].should eq(0)
      result[:output].should contain("Importance: high")
    end

    it "supports --session flag" do
      result = run_binary(["add", "--type", "learning", "--content", "Session specific", "--session", "custom-session-123"])
      result[:status].should eq(0)
      result[:output].should contain("Session: custom-session-123")
    end

    it "detects duplicate content" do
      run_binary(["add", "--type", "learning", "--content", "Duplicate test content"])
      result = run_binary(["add", "--type", "learning", "--content", "Duplicate test content"])
      result[:status].should eq(0)
      result[:output].should contain("already exists")
    end

    it "shows help when no arguments provided" do
      result = run_binary(["add"])
      result[:status].should eq(0)
      result[:output].should contain("USAGE")
      result[:output].should contain("--type TYPE")
      result[:output].should contain("--content CONTENT")
    end

    it "shows help with --help flag" do
      result = run_binary(["add", "--help"])
      result[:status].should eq(0)
      result[:output].should contain("USAGE")
      result[:output].should contain("ENTRY TYPES")
      result[:output].should contain("EXAMPLES")
    end

    it "shows help with -h flag" do
      result = run_binary(["add", "-h"])
      result[:status].should eq(0)
      result[:output].should contain("USAGE")
    end

    it "shows error when --type is missing" do
      result = run_binary(["add", "--content", "Some content"])
      result[:error].should contain("--type is required")
      result[:status].should_not eq(0)
    end

    it "shows error when --content is missing" do
      result = run_binary(["add", "--type", "learning"])
      result[:error].should contain("--content is required")
      result[:status].should_not eq(0)
    end

    it "shows error for invalid type" do
      result = run_binary(["add", "--type", "invalid_type", "--content", "Some content"])
      result[:error].should contain("Invalid type")
      result[:status].should_not eq(0)
    end

    it "shows error for invalid importance" do
      result = run_binary(["add", "--type", "learning", "--content", "Test", "--importance", "invalid"])
      result[:error].should contain("Invalid importance")
      result[:status].should_not eq(0)
    end

    it "shows error for unknown option" do
      result = run_binary(["add", "--unknown", "value"])
      result[:error].should contain("Unknown option")
      result[:status].should_not eq(0)
    end
  end

  describe "search with prefix matching" do
    before_each do
      db_path = GalaxyLedger::Database.database_path
      File.delete(db_path) if File.exists?(db_path)
    end

    it "finds entries with prefix matching (default)" do
      run_binary(["add", "--type", "guideline", "--content", "Use trailing commas on multiline structures"])

      result = run_binary(["search", "--query", "trail"])
      result[:status].should eq(0)
      result[:output].should contain("trailing")
    end

    it "supports --exact flag for exact matching" do
      run_binary(["add", "--type", "guideline", "--content", "Use trailing commas on multiline structures"])

      result = run_binary(["search", "--query", "trail", "--exact"])
      result[:status].should eq(0)
      result[:output].should contain("No results found")
    end
  end

  describe "search with filters" do
    before_each do
      db_path = GalaxyLedger::Database.database_path
      File.delete(db_path) if File.exists?(db_path)

      # Add test data
      run_binary(["add", "--type", "learning", "--content", "JWT tokens expire", "--importance", "high"])
      run_binary(["add", "--type", "decision", "--content", "JWT storage in Redis", "--importance", "medium"])
      run_binary(["add", "--type", "guideline", "--content", "JWT best practices", "--importance", "high"])
    end

    it "filters by --type" do
      result = run_binary(["search", "--query", "JWT", "--type", "learning"])
      result[:status].should eq(0)
      result[:output].should contain("Found: 1 entries")
      result[:output].should contain("type=learning")
    end

    it "filters by --importance" do
      result = run_binary(["search", "--query", "JWT", "--importance", "high"])
      result[:status].should eq(0)
      result[:output].should contain("Found: 2 entries")
      result[:output].should contain("importance=high")
    end

    it "combines --type and --importance filters" do
      result = run_binary(["search", "--query", "JWT", "--type", "guideline", "--importance", "high"])
      result[:status].should eq(0)
      result[:output].should contain("Found: 1 entries")
      result[:output].should contain("type=guideline")
      result[:output].should contain("importance=high")
    end

    it "shows error for invalid type filter" do
      result = run_binary(["search", "--query", "JWT", "--type", "invalid"])
      result[:error].should contain("Invalid type")
      result[:status].should_not eq(0)
    end

    it "shows error for invalid importance filter" do
      result = run_binary(["search", "--query", "JWT", "--importance", "invalid"])
      result[:error].should contain("Invalid importance")
      result[:status].should_not eq(0)
    end
  end

  describe "list with filters" do
    before_each do
      db_path = GalaxyLedger::Database.database_path
      File.delete(db_path) if File.exists?(db_path)

      # Add test data
      run_binary(["add", "--type", "learning", "--content", "Learning 1", "--importance", "high"])
      run_binary(["add", "--type", "learning", "--content", "Learning 2", "--importance", "medium"])
      run_binary(["add", "--type", "decision", "--content", "Decision 1", "--importance", "high"])
      run_binary(["add", "--type", "guideline", "--content", "Guideline 1", "--importance", "medium"])
    end

    it "filters by --type" do
      result = run_binary(["list", "--type", "learning"])
      result[:status].should eq(0)
      result[:output].should contain("Filters: type=learning")
      result[:output].should contain("Learning 1")
      result[:output].should contain("Learning 2")
      result[:output].should_not contain("Decision 1")
    end

    it "filters by --importance" do
      result = run_binary(["list", "--importance", "high"])
      result[:status].should eq(0)
      result[:output].should contain("Filters: importance=high")
      result[:output].should contain("Learning 1")
      result[:output].should contain("Decision 1")
      result[:output].should_not contain("Learning 2")
    end

    it "combines limit with filters" do
      result = run_binary(["list", "--limit", "1", "--type", "learning"])
      result[:status].should eq(0)
      result[:output].should contain("showing 1)")
    end

    it "shows --help" do
      result = run_binary(["list", "--help"])
      result[:status].should eq(0)
      result[:output].should contain("--type TYPE")
      result[:output].should contain("--importance LEVEL")
    end

    it "shows error for invalid type filter" do
      result = run_binary(["list", "--type", "invalid"])
      result[:error].should contain("Invalid type")
      result[:status].should_not eq(0)
    end
  end

  describe "help flag coverage for all commands" do
    describe "config --help" do
      it "shows help with --help flag" do
        result = run_binary(["config", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("USAGE")
        result[:output].should contain("AVAILABLE SETTINGS")
      end

      it "shows help with -h flag" do
        result = run_binary(["config", "-h"])
        result[:status].should eq(0)
        result[:output].should contain("USAGE")
      end

      it "shows subcommand help for config set --help" do
        result = run_binary(["config", "set", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("config set")
        result[:output].should contain("KEY")
        result[:output].should contain("VALUE")
      end

      it "shows subcommand help for config get --help" do
        result = run_binary(["config", "get", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("config get")
        result[:output].should contain("KEY")
      end

      it "shows subcommand help for config reset --help" do
        result = run_binary(["config", "reset", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("config reset")
      end

      it "shows subcommand help for config path --help" do
        result = run_binary(["config", "path", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("config path")
      end
    end

    describe "hook commands --help" do
      it "shows help for on-startup --help" do
        result = run_binary(["on-startup", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("on-startup")
        result[:output].should contain("SessionStart")
        result[:output].should contain("INPUT")
        result[:output].should contain("OUTPUT")
        result[:output].should contain("HOOK CONFIGURATION")
      end

      it "shows help for on-stop --help" do
        result = run_binary(["on-stop", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("on-stop")
        result[:output].should contain("Stop hook")
        result[:output].should contain("INPUT")
        result[:output].should contain("OUTPUT")
        result[:output].should contain("HOOK CONFIGURATION")
      end

      it "shows help for on-clear --help" do
        result = run_binary(["on-clear", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("on-clear")
        result[:output].should contain("SessionStart")
        result[:output].should contain("INPUT")
        result[:output].should contain("OUTPUT")
        result[:output].should contain("HOOK CONFIGURATION")
      end

      it "shows help for on-compact --help" do
        result = run_binary(["on-compact", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("on-compact")
        result[:output].should contain("SessionStart")
        result[:output].should contain("INPUT")
        result[:output].should contain("OUTPUT")
        result[:output].should contain("HOOK CONFIGURATION")
      end

      it "shows help for on-resume --help" do
        result = run_binary(["on-resume", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("on-resume")
        result[:output].should contain("SessionStart")
        result[:output].should contain("INPUT")
        result[:output].should contain("OUTPUT")
        result[:output].should contain("HOOK CONFIGURATION")
      end
    end
  end

  describe "stale extraction end-to-end flow" do
    # Tests the full cycle: read → extract marker → edit → mark stale → verify
    # We can't test the async re-extraction subprocess, but we verify the
    # database state at each step of the pipeline.

    it "full cycle: read guideline, edit it, verify stale, prune, verify clean" do
      session_id = "e2e-stale-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      begin
        # Step 1: Read a guideline file → creates extraction_marker entry
        read_input = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/agent-guidelines/ruby-style.md"},
          "tool_response"   => "# Ruby Style\n- Use double quotes\n- Trailing commas",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: read_input)
        result[:status].should eq(0)

        # Verify: extraction_marker entry exists, not stale
        GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md").should be_true
        GalaxyLedger::Database.stale_entries(ledger_session_id).should be_empty

        # Step 2: Edit the same guideline file → marks entries stale
        edit_input = {
          "session_id" => session_id,
          "tool_name"  => "Edit",
          "tool_input" => {
            "file_path"  => "/home/user/agent-guidelines/ruby-style.md",
            "old_string" => "Use double quotes",
            "new_string" => "Use single quotes",
          },
          "tool_response"   => "success",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: edit_input)
        result[:status].should eq(0)

        # Verify: marker is now stale
        stale = GalaxyLedger::Database.stale_entries(ledger_session_id)
        stale.size.should eq(1)
        stale[0][:source_file].should eq("/home/user/agent-guidelines/ruby-style.md")
        stale[0][:full_path].should eq("/home/user/agent-guidelines/ruby-style.md")
        stale[0][:entry_type].should eq("guideline")

        # Step 3: Simulate what on-stop does — prune stale entries
        GalaxyLedger::Database.delete_entries_by_source_file(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md")

        # Verify: entries are pruned, ready for re-extraction
        GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md").should be_false
        GalaxyLedger::Database.stale_entries(ledger_session_id).should be_empty
      ensure
        GalaxyLedger::Database.delete_session(session_id)
      end
    end

    it "handles multiple stale files in same session" do
      session_id = "e2e-multi-stale-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      begin
        # Read two guideline files
        ["ruby-style.md", "rspec-style.md"].each do |filename|
          read_input = {
            "session_id"      => session_id,
            "tool_name"       => "Read",
            "tool_input"      => {"file_path" => "/home/user/agent-guidelines/#{filename}"},
            "tool_response"   => "contents of #{filename}",
            "hook_event_name" => "PostToolUse",
          }.to_json
          run_binary(["on-post-tool-use"], stdin: read_input)
        end

        # Edit only one of them
        edit_input = {
          "session_id" => session_id,
          "tool_name"  => "Edit",
          "tool_input" => {
            "file_path"  => "/home/user/agent-guidelines/ruby-style.md",
            "old_string" => "old",
            "new_string" => "new",
          },
          "tool_response"   => "success",
          "hook_event_name" => "PostToolUse",
        }.to_json
        run_binary(["on-post-tool-use"], stdin: edit_input)

        # Only ruby-style should be stale
        stale = GalaxyLedger::Database.stale_entries(ledger_session_id)
        stale.size.should eq(1)
        stale[0][:source_file].should eq("/home/user/agent-guidelines/ruby-style.md")

        # rspec-style should be untouched
        GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/home/user/agent-guidelines/rspec-style.md").should be_true

        # Prune only the stale one
        GalaxyLedger::Database.delete_entries_by_source_file(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md")

        # rspec-style still present, ruby-style gone
        GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/home/user/agent-guidelines/rspec-style.md").should be_true
        GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md").should be_false
      ensure
        GalaxyLedger::Database.delete_session(session_id)
      end
    end

    it "mixed types: guideline and implementation_plan stale independently" do
      session_id = "e2e-mixed-stale-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      begin
        # Read a guideline
        read_gl = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/agent-guidelines/ruby-style.md"},
          "tool_response"   => "guideline content",
          "hook_event_name" => "PostToolUse",
        }.to_json
        run_binary(["on-post-tool-use"], stdin: read_gl)

        # Read an implementation plan
        read_ip = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/implementation-plans/feature.md"},
          "tool_response"   => "plan content",
          "hook_event_name" => "PostToolUse",
        }.to_json
        run_binary(["on-post-tool-use"], stdin: read_ip)

        # Edit only the implementation plan
        write_ip = {
          "session_id" => session_id,
          "tool_name"  => "Write",
          "tool_input" => {
            "file_path" => "/home/user/implementation-plans/feature.md",
            "content"   => "updated plan",
          },
          "tool_response"   => "success",
          "hook_event_name" => "PostToolUse",
        }.to_json
        run_binary(["on-post-tool-use"], stdin: write_ip)

        # Only the plan should be stale
        stale = GalaxyLedger::Database.stale_entries(ledger_session_id)
        stale.size.should eq(1)
        stale[0][:source_file].should eq("/home/user/implementation-plans/feature.md")
        stale[0][:entry_type].should eq("implementation_plan")

        # Guideline should be fresh
        GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md").should be_true
      ensure
        GalaxyLedger::Database.delete_session(session_id)
      end
    end
  end

  describe "list-files subcommand" do
    before_each do
      db_path = GalaxyLedger::Database.database_path
      File.delete(db_path) if File.exists?(db_path)
    end

    it "lists session files with operation flags" do
      session_id = "list-files-test-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/home/user/src/app.cr", :edit)
      GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/home/user/src/app.cr", :read)
      GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/home/user/README.md", :read)

      result = run_binary(["list-files", "--session", session_id])
      result[:status].should eq(0)
      result[:output].should contain("Session files for session ##{ledger_session_id}")
      result[:output].should contain("edited")
      result[:output].should contain("read")
      result[:output].should contain("app.cr")
      result[:output].should contain("README.md")

      GalaxyLedger::Database.delete_session(session_id)
    end

    it "shows search patterns for searched files" do
      session_id = "list-files-search-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      GalaxyLedger::Database.upsert_session_file(
        ledger_session_id, "/home/user/src/", :search,
        search_pattern: "extraction_marker"
      )

      result = run_binary(["list-files", "--session", session_id])
      result[:status].should eq(0)
      result[:output].should contain("searched")
      result[:output].should contain("extraction_marker")

      GalaxyLedger::Database.delete_session(session_id)
    end

    it "shows empty message when no files found" do
      session_id = "list-files-empty-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      result = run_binary(["list-files", "--session", session_id])
      result[:status].should eq(0)
      result[:output].should contain("No session files found")

      GalaxyLedger::Database.delete_session(session_id)
    end

    it "requires --session or --pid flag" do
      result = run_binary(["list-files"])
      result[:error].should contain("--session or --pid is required")
      result[:status].should_not eq(0)
    end

    it "respects --limit flag" do
      session_id = "list-files-limit-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      5.times do |i|
        GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/home/user/file#{i}.rb", :read)
      end

      result = run_binary(["list-files", "--session", session_id, "--limit", "2"])
      result[:status].should eq(0)
      result[:output].should contain("showing 2 of 5")

      GalaxyLedger::Database.delete_session(session_id)
    end

    it "shows help with --help flag" do
      result = run_binary(["list-files", "--help"])
      result[:status].should eq(0)
      result[:output].should contain("USAGE")
      result[:output].should contain("--session SESSION_ID")
    end

    it "shows help with -h flag" do
      result = run_binary(["list-files", "-h"])
      result[:status].should eq(0)
      result[:output].should contain("USAGE")
    end
  end

  describe "top-level help banner" do
    it "lists all user-facing commands" do
      result = run_binary(["--help"])
      result[:status].should eq(0)
      result[:output].should contain("search")
      result[:output].should contain("list")
      result[:output].should contain("list-files")
      result[:output].should contain("add")
      result[:output].should contain("config")
    end

    it "lists hook commands in separate section" do
      result = run_binary(["--help"])
      result[:status].should eq(0)
      result[:output].should contain("Hook Commands")
      result[:output].should contain("on-startup")
      result[:output].should contain("on-resume")
      result[:output].should contain("on-clear")
      result[:output].should contain("on-compact")
      result[:output].should contain("on-stop")
    end

    it "includes discoverability hint" do
      result = run_binary(["--help"])
      result[:status].should eq(0)
      result[:output].should contain("--help")
      result[:output].should contain("detailed command usage")
    end
  end

  describe "update-session-metrics subcommand" do
    before_each do
      db_path = GalaxyLedger::Database.database_path
      File.delete(db_path) if File.exists?(db_path)
    end

    it "updates session metrics from stdin JSON" do
      session_id = "metrics-test-#{Random.rand(100000)}"

      # Create the session record first
      GalaxyLedger::Database.create_session(session_id)

      metrics_json = {
        "session_id" => session_id,
        "timestamp"  => 1234567890,
        "context"    => {
          "percentage"  => 45.2,
          "tokens_used" => 50000,
          "tokens_max"  => 200000,
        },
        "cost" => {
          "usd" => 0.15,
        },
        "model" => {
          "id"           => "claude-opus-4-6",
          "display_name" => "Claude Opus 4.6",
        },
      }.to_json

      result = run_binary(
        ["update-session-metrics", "--session", session_id],
        stdin: metrics_json,
      )
      result[:status].should eq(0)

      # Verify metrics were persisted
      session = GalaxyLedger::Database.get_session(session_id)
      session.should_not be_nil
      if s = session
        s.context_percentage.should eq(45.2)
        s.tokens_used.should eq(50000)
        s.tokens_max.should eq(200000)
        s.cost_usd.should eq(0.15)
        s.model_id.should eq("claude-opus-4-6")
        s.model_display_name.should eq("Claude Opus 4.6")
      end
    end

    it "updates cwd, project_dir, and git_branch from stdin JSON" do
      session_id = "metrics-branch-#{Random.rand(100000)}"

      # Create the session record first
      GalaxyLedger::Database.create_session(session_id)

      metrics_json = {
        "session_id" => session_id,
        "cwd"        => "/home/user/project/subdir",
        "git_branch" => "kr/feature-01",
        "workspace"  => {
          "project_dir" => "/home/user/project",
        },
        "context" => {
          "percentage" => 30.0,
        },
      }.to_json

      result = run_binary(
        ["update-session-metrics", "--session", session_id],
        stdin: metrics_json,
      )
      result[:status].should eq(0)

      # Verify cwd, project_dir, and git_branch were persisted
      session = GalaxyLedger::Database.get_session(session_id)
      session.should_not be_nil
      if s = session
        s.cwd.should eq("/home/user/project/subdir")
        s.project_dir.should eq("/home/user/project")
        s.git_branch.should eq("kr/feature-01")
        s.context_percentage.should eq(30.0)
      end
    end

    it "exits non-zero when --session or --pid is missing" do
      metrics_json = {"context" => {"percentage" => 10.0}}.to_json
      result = run_binary(["update-session-metrics"], stdin: metrics_json)
      result[:status].should_not eq(0)
      result[:error].should contain("--session or --pid is required")
    end

    it "exits non-zero when no JSON provided on stdin" do
      session_id = "metrics-empty-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(session_id)

      result = run_binary(["update-session-metrics", "--session", session_id])
      result[:status].should_not eq(0)
      result[:error].should contain("no JSON provided")
    end

    it "shows help with --help flag" do
      result = run_binary(["update-session-metrics", "--help"])
      result[:status].should eq(0)
      result[:output].should contain("update-session-metrics")
      result[:output].should contain("--session SESSION_ID")
      result[:output].should contain("ContextStatus")
    end

    it "shows help with -h flag" do
      result = run_binary(["update-session-metrics", "-h"])
      result[:status].should eq(0)
      result[:output].should contain("update-session-metrics")
    end
  end
end
