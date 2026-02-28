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

# Helper to create a session with a registered PID for CLI tests.
# Returns the ledger_session_id (Int64).
def create_session_with_pid(pid : Int64) : Int64
  session_id = "snap-cli-#{Random.rand(100000)}"
  GalaxyLedger::Database.create_session(session_id, claude_pid: pid)
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

  describe "list-entries subcommand" do
    before_each do
      # Clean database for isolation
      db_path = GalaxyLedger::Database.database_path
      File.delete(db_path) if File.exists?(db_path)
    end

    it "lists recent entries" do
      run_binary(["add", "--type", "learning", "--content", "First learning"])
      run_binary(["add", "--type", "decision", "--content", "First decision"])

      result = run_binary(["list-entries"])
      result[:status].should eq(0)
      result[:output].should contain("Recent ledger entries")
      result[:output].should contain("learning")
      result[:output].should contain("decision")
    end

    it "shows empty message when no entries" do
      result = run_binary(["list-entries"])
      result[:status].should eq(0)
      result[:output].should contain("No entries in ledger")
    end

    it "respects --limit flag" do
      5.times do |i|
        run_binary(["add", "--type", "learning", "--content", "Learning number #{i + 1}"])
      end

      result = run_binary(["list-entries", "--limit", "2"])
      result[:status].should eq(0)
      result[:output].should contain("showing 2 of 5")
    end

    it "respects positional limit argument for backwards compatibility" do
      5.times do |i|
        run_binary(["add", "--type", "learning", "--content", "Learning number #{i + 1}"])
      end

      result = run_binary(["list-entries", "2"])
      result[:status].should eq(0)
      result[:output].should contain("showing 2 of 5")
    end

    it "shows help with --help flag" do
      result = run_binary(["list-entries", "--help"])
      result[:status].should eq(0)
      result[:output].should contain("USAGE")
      result[:output].should contain("--limit N")
      result[:output].should contain("--type TYPE")
    end

    it "shows help with -h flag" do
      result = run_binary(["list-entries", "-h"])
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
      dedup_session = "dedup-test-#{Random.rand(10000)}"
      run_binary(["add", "--type", "learning", "--content", "Duplicate test content", "--session", dedup_session])
      result = run_binary(["add", "--type", "learning", "--content", "Duplicate test content", "--session", dedup_session])
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

  describe "list-entries with filters" do
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
      result = run_binary(["list-entries", "--type", "learning"])
      result[:status].should eq(0)
      result[:output].should contain("Filters: type=learning")
      result[:output].should contain("Learning 1")
      result[:output].should contain("Learning 2")
      result[:output].should_not contain("Decision 1")
    end

    it "filters by --importance" do
      result = run_binary(["list-entries", "--importance", "high"])
      result[:status].should eq(0)
      result[:output].should contain("Filters: importance=high")
      result[:output].should contain("Learning 1")
      result[:output].should contain("Decision 1")
      result[:output].should_not contain("Learning 2")
    end

    it "combines limit with filters" do
      result = run_binary(["list-entries", "--limit", "1", "--type", "learning"])
      result[:status].should eq(0)
      result[:output].should contain("showing 1)")
    end

    it "shows --help" do
      result = run_binary(["list-entries", "--help"])
      result[:status].should eq(0)
      result[:output].should contain("--type TYPE")
      result[:output].should contain("--importance LEVEL")
    end

    it "shows error for invalid type filter" do
      result = run_binary(["list-entries", "--type", "invalid"])
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

    it "requires --session, --pid, or --ledger-session-id flag" do
      result = run_binary(["list-files"])
      result[:error].should contain("--session, --pid, or --ledger-session-id is required")
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
      result[:output].should contain("list-entries")
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

  describe "extract-assistant" do
    it "captures last exchange from transcript via --transcript-path" do
      session_id = "extract-transcript-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      # Create a JSONL transcript with a complete exchange
      transcript_file = File.tempfile("transcript", ".jsonl")
      transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Help me add dark mode"}}\n|)
      transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "I added a dark mode toggle to the settings page."}}\n|)
      transcript_file.close

      result = run_binary([
        "extract-assistant",
        "--session", session_id,
        "--transcript-path", transcript_file.path,
      ])
      result[:status].should eq(0)

      # Verify last_interaction was captured with non-empty content
      session = GalaxyLedger::Database.get_session(session_id)
      session.should_not be_nil
      if s = session
        s.last_interaction.should_not be_nil, "Expected last_interaction to be set"
        li = JSON.parse(s.last_interaction.not_nil!)
        li.as_a.should_not be_empty, "Expected last_interaction to be a non-empty array"
        exchange = li.as_a.last
        exchange["user_message"].as_s.should eq("Help me add dark mode")
        exchange["full_content"].as_s.should_not be_empty, "Expected full_content to be non-empty"
      end

      File.delete(transcript_file.path) if File.exists?(transcript_file.path)
    end

    it "requires --input-file or --transcript-path" do
      session_id = "extract-no-input-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(session_id)

      result = run_binary([
        "extract-assistant",
        "--session", session_id,
      ])
      result[:status].should eq(1)
      result[:error].should contain("--input-file or --transcript-path is required")
    end

    # CLI eval tests (extract-assistant --input-file and --transcript-path)
    # have been moved to spec/extraction/extraction_eval_spec.cr where they
    # run concurrently with the other 4 extraction evals using fibers.
  end

  describe "snapshot subcommand" do
    describe "snapshot --help" do
      it "shows help text with all subcommands" do
        result = run_binary(["snapshot", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("snapshot")
        result[:output].should contain("create")
        result[:output].should contain("list")
        result[:output].should contain("view")
        result[:output].should contain("open")
        result[:output].should contain("delete")
      end
    end

    describe "snapshot create" do
      it "creates snapshot with valid PID, title, and stdin content" do
        pid = Random.rand(10000).to_i64 + 90000
        ledger_session_id = create_session_with_pid(pid)

        result = run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "Test snapshot"],
          stdin: "## Exchange 1\n\n### User\nHello\n\n### Assistant\nHi there!",
        )
        result[:status].should eq(0)
        result[:output].should contain("Snapshot #1 saved")
        result[:output].should contain("Test snapshot")
      end

      it "returns number 2 for second create to same session" do
        pid = Random.rand(10000).to_i64 + 90000
        ledger_session_id = create_session_with_pid(pid)

        result1 = run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "First"],
          stdin: "content 1",
        )
        result1[:status].should eq(0)
        result1[:output].should contain("Snapshot #1")

        result2 = run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "Second"],
          stdin: "content 2",
        )
        result2[:status].should eq(0)
        result2[:output].should contain("Snapshot #2")
      end

      it "returns number 1 for create to different session" do
        pid_a = Random.rand(10000).to_i64 + 90000
        pid_b = pid_a + 1
        create_session_with_pid(pid_a)
        create_session_with_pid(pid_b)

        run_binary(
          ["snapshot", "create", "--pid", pid_a.to_s, "--title", "A snap"],
          stdin: "content a",
        )

        result = run_binary(
          ["snapshot", "create", "--pid", pid_b.to_s, "--title", "B snap"],
          stdin: "content b",
        )
        result[:status].should eq(0)
        result[:output].should contain("Snapshot #1")
      end

      it "errors without --pid" do
        result = run_binary(
          ["snapshot", "create", "--title", "No PID"],
          stdin: "content",
        )
        result[:status].should_not eq(0)
        result[:error].should contain("--pid is required")
      end

      it "errors without --title" do
        pid = Random.rand(10000).to_i64 + 90000
        create_session_with_pid(pid)

        result = run_binary(
          ["snapshot", "create", "--pid", pid.to_s],
          stdin: "content",
        )
        result[:status].should_not eq(0)
        result[:error].should contain("--title is required")
      end

      it "errors with invalid PID" do
        result = run_binary(
          ["snapshot", "create", "--pid", "99999999", "--title", "Bad PID"],
          stdin: "content",
        )
        result[:status].should_not eq(0)
        result[:error].should contain("no session found")
      end

      it "shows help with --help" do
        result = run_binary(["snapshot", "create", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("snapshot create")
        result[:output].should contain("--pid")
        result[:output].should contain("--title")
      end
    end

    describe "snapshot list" do
      it "lists snapshots with formatted output" do
        pid = Random.rand(10000).to_i64 + 90000
        ledger_session_id = create_session_with_pid(pid)

        run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "First snap"],
          stdin: "content one",
        )
        run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "Second snap", "--exchanges", "2"],
          stdin: "content two is longer",
        )

        result = run_binary(["snapshot", "list", "--pid", pid.to_s])
        result[:status].should eq(0)
        result[:output].should contain("2 total")
        result[:output].should contain("#1")
        result[:output].should contain("First snap")
        result[:output].should contain("#2")
        result[:output].should contain("Second snap")
        result[:output].should contain("2 exchanges")
      end

      it "shows empty message when no snapshots" do
        pid = Random.rand(10000).to_i64 + 90000
        create_session_with_pid(pid)

        result = run_binary(["snapshot", "list", "--pid", pid.to_s])
        result[:status].should eq(0)
        result[:output].should contain("No snapshots")
      end

      it "outputs JSON with --json flag" do
        pid = Random.rand(10000).to_i64 + 90000
        ledger_session_id = create_session_with_pid(pid)

        run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "JSON test"],
          stdin: "content for json",
        )
        run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "Second JSON", "--exchanges", "3"],
          stdin: "more content here",
        )

        result = run_binary(["snapshot", "list", "--pid", pid.to_s, "--json"])
        result[:status].should eq(0)

        parsed = JSON.parse(result[:output])
        snapshots = parsed["snapshots"].as_a
        snapshots.size.should eq(2)

        first = snapshots[0]
        first["number"].as_i.should eq(1)
        first["title"].as_s.should eq("JSON test")
        first["exchange_count"].as_i.should eq(1)
        first["char_count"].as_i.should eq(16)
        first["id"].as_i64.should be > 0
        first["created_at"].as_s.should_not be_empty

        second = snapshots[1]
        second["number"].as_i.should eq(2)
        second["title"].as_s.should eq("Second JSON")
        second["exchange_count"].as_i.should eq(3)
      end

      it "outputs JSON with empty array when no snapshots" do
        pid = Random.rand(10000).to_i64 + 90000
        create_session_with_pid(pid)

        result = run_binary(["snapshot", "list", "--pid", pid.to_s, "--json"])
        result[:status].should eq(0)

        parsed = JSON.parse(result[:output])
        parsed["snapshots"].as_a.size.should eq(0)
      end

      it "does not include content field in JSON output" do
        pid = Random.rand(10000).to_i64 + 90000
        create_session_with_pid(pid)

        run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "No content test"],
          stdin: "this should not appear in list JSON",
        )

        result = run_binary(["snapshot", "list", "--pid", pid.to_s, "--json"])
        result[:status].should eq(0)

        parsed = JSON.parse(result[:output])
        first = parsed["snapshots"].as_a[0]
        first["title"].as_s.should eq("No content test")
        first.as_h.has_key?("content").should be_false
      end

      it "resolves session via --ledger-session-id" do
        pid = Random.rand(10000).to_i64 + 90000
        ledger_session_id = create_session_with_pid(pid)

        run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "LSID test"],
          stdin: "content",
        )

        result = run_binary(["snapshot", "list", "--ledger-session-id", ledger_session_id.to_s])
        result[:status].should eq(0)
        result[:output].should contain("LSID test")
      end

      it "outputs JSON via --ledger-session-id" do
        pid = Random.rand(10000).to_i64 + 90000
        ledger_session_id = create_session_with_pid(pid)

        run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "LSID JSON"],
          stdin: "content",
        )

        result = run_binary([
          "snapshot", "list",
          "--ledger-session-id", ledger_session_id.to_s,
          "--json",
        ])
        result[:status].should eq(0)

        parsed = JSON.parse(result[:output])
        parsed["snapshots"].as_a[0]["title"].as_s.should eq("LSID JSON")
      end

      it "shows help with --help" do
        result = run_binary(["snapshot", "list", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("snapshot list")
        result[:output].should contain("--ledger-session-id")
        result[:output].should contain("--json")
      end
    end

    describe "snapshot view" do
      it "outputs full snapshot content" do
        pid = Random.rand(10000).to_i64 + 90000
        create_session_with_pid(pid)

        content = "## Exchange 1\n\n### User\nHello world\n\n### Assistant\nHi!"
        run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "View test"],
          stdin: content,
        )

        result = run_binary(["snapshot", "view", "--pid", pid.to_s, "1"])
        result[:status].should eq(0)
        result[:output].should contain("## Exchange 1")
        result[:output].should contain("Hello world")
      end

      it "outputs JSON with --json flag including content" do
        pid = Random.rand(10000).to_i64 + 90000
        create_session_with_pid(pid)

        content = "## Exchange 1\n\n### User\nHello JSON\n\n### Assistant\nHi!"
        run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "View JSON test"],
          stdin: content,
        )

        result = run_binary(["snapshot", "view", "--pid", pid.to_s, "--json", "1"])
        result[:status].should eq(0)

        parsed = JSON.parse(result[:output])
        snapshot = parsed["snapshot"]
        snapshot["number"].as_i.should eq(1)
        snapshot["title"].as_s.should eq("View JSON test")
        snapshot["content"].as_s.should contain("Hello JSON")
        snapshot["exchange_count"].as_i.should eq(1)
        snapshot["char_count"].as_i.should be > 0
        snapshot["created_at"].as_s.should_not be_empty
        snapshot["updated_at"].as_s.should_not be_empty
      end

      it "resolves session via --ledger-session-id" do
        pid = Random.rand(10000).to_i64 + 90000
        ledger_session_id = create_session_with_pid(pid)

        run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "LSID view"],
          stdin: "content for lsid view",
        )

        result = run_binary([
          "snapshot", "view",
          "--ledger-session-id", ledger_session_id.to_s,
          "1",
        ])
        result[:status].should eq(0)
        result[:output].should contain("content for lsid view")
      end

      it "outputs JSON via --ledger-session-id" do
        pid = Random.rand(10000).to_i64 + 90000
        ledger_session_id = create_session_with_pid(pid)

        run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "LSID view JSON"],
          stdin: "lsid json content",
        )

        result = run_binary([
          "snapshot", "view",
          "--ledger-session-id", ledger_session_id.to_s,
          "--json", "1",
        ])
        result[:status].should eq(0)

        parsed = JSON.parse(result[:output])
        parsed["snapshot"]["title"].as_s.should eq("LSID view JSON")
        parsed["snapshot"]["content"].as_s.should contain("lsid json content")
      end

      it "errors with invalid number" do
        pid = Random.rand(10000).to_i64 + 90000
        create_session_with_pid(pid)

        result = run_binary(["snapshot", "view", "--pid", pid.to_s, "99"])
        result[:status].should_not eq(0)
        result[:error].should contain("not found")
      end

      it "shows help with --help" do
        result = run_binary(["snapshot", "view", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("snapshot view")
        result[:output].should contain("--ledger-session-id")
        result[:output].should contain("--json")
      end
    end

    describe "snapshot delete" do
      it "deletes snapshot and confirms" do
        pid = Random.rand(10000).to_i64 + 90000
        create_session_with_pid(pid)

        run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "To delete"],
          stdin: "content",
        )

        result = run_binary(["snapshot", "delete", "--pid", pid.to_s, "1"])
        result[:status].should eq(0)
        result[:output].should contain("Snapshot #1 deleted")

        # Verify it's gone
        view_result = run_binary(["snapshot", "view", "--pid", pid.to_s, "1"])
        view_result[:status].should_not eq(0)
      end

      it "deletes snapshot via --ledger-session-id" do
        pid = Random.rand(10000).to_i64 + 90000
        ledger_session_id = create_session_with_pid(pid)

        run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "LSID delete"],
          stdin: "content",
        )

        result = run_binary([
          "snapshot", "delete",
          "--ledger-session-id", ledger_session_id.to_s,
          "1",
        ])
        result[:status].should eq(0)
        result[:output].should contain("Snapshot #1 deleted")
      end

      it "errors when snapshot not found" do
        pid = Random.rand(10000).to_i64 + 90000
        create_session_with_pid(pid)

        result = run_binary(["snapshot", "delete", "--pid", pid.to_s, "99"])
        result[:status].should_not eq(0)
        result[:error].should contain("not found")
      end

      it "shows help with --help" do
        result = run_binary(["snapshot", "delete", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("snapshot delete")
        result[:output].should contain("--ledger-session-id")
      end
    end

    describe "snapshot open" do
      it "writes temp file and opens with configured editor" do
        pid = Random.rand(10000).to_i64 + 90000
        ledger_session_id = create_session_with_pid(pid)

        content = "## Exchange 1\n\n### User\nHello\n\n### Assistant\nHi!"
        run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "Open test"],
          stdin: content,
        )

        # Use 'true' as the editor so it exits immediately without opening anything
        result = run_binary(
          ["snapshot", "open", "--pid", pid.to_s, "1"],
          extra_env: {"EDITOR" => "true"},
        )
        result[:status].should eq(0)
        result[:output].should contain("Opened snapshot #1")
        result[:output].should contain("Open test")

        # Verify the temp file was written with correct content
        temp_path = GalaxyLedger::CLI.snapshot_temp_path(ledger_session_id, 1)
        File.exists?(temp_path).should be_true
        File.read(temp_path).should eq(content)
      end

      it "produces a stable temp file path (same path on re-open)" do
        pid = Random.rand(10000).to_i64 + 90000
        ledger_session_id = create_session_with_pid(pid)

        run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "Stability test"],
          stdin: "content",
        )

        # Open twice — should produce the same temp file path
        result1 = run_binary(
          ["snapshot", "open", "--pid", pid.to_s, "1"],
          extra_env: {"EDITOR" => "true"},
        )
        result2 = run_binary(
          ["snapshot", "open", "--pid", pid.to_s, "1"],
          extra_env: {"EDITOR" => "true"},
        )

        # Both should reference the same temp file in output
        temp_path = GalaxyLedger::CLI.snapshot_temp_path(ledger_session_id, 1)
        result1[:output].should contain(temp_path)
        result2[:output].should contain(temp_path)
      end

      it "opens snapshot via --ledger-session-id" do
        pid = Random.rand(10000).to_i64 + 90000
        ledger_session_id = create_session_with_pid(pid)

        run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "LSID open"],
          stdin: "lsid open content",
        )

        result = run_binary(
          ["snapshot", "open", "--ledger-session-id", ledger_session_id.to_s, "1"],
          extra_env: {"EDITOR" => "true"},
        )
        result[:status].should eq(0)
        result[:output].should contain("Opened snapshot #1")
        result[:output].should contain("LSID open")
      end

      it "errors when snapshot not found" do
        pid = Random.rand(10000).to_i64 + 90000
        create_session_with_pid(pid)

        result = run_binary(
          ["snapshot", "open", "--pid", pid.to_s, "99"],
          extra_env: {"EDITOR" => "true"},
        )
        result[:status].should_not eq(0)
        result[:error].should contain("not found")
      end

      it "errors without --pid or --ledger-session-id" do
        result = run_binary(
          ["snapshot", "open", "1"],
          extra_env: {"EDITOR" => "true"},
        )
        result[:status].should_not eq(0)
        result[:error].should contain("is required")
      end

      it "errors without snapshot number" do
        pid = Random.rand(10000).to_i64 + 90000
        create_session_with_pid(pid)

        result = run_binary(
          ["snapshot", "open", "--pid", pid.to_s],
          extra_env: {"EDITOR" => "true"},
        )
        result[:status].should_not eq(0)
        result[:error].should contain("snapshot number is required")
      end

      it "errors with invalid editor command" do
        pid = Random.rand(10000).to_i64 + 90000
        create_session_with_pid(pid)

        run_binary(
          ["snapshot", "create", "--pid", pid.to_s, "--title", "Bad editor"],
          stdin: "content",
        )

        result = run_binary(
          ["snapshot", "open", "--pid", pid.to_s, "1"],
          extra_env: {"EDITOR" => "nonexistent-editor-command-xyz"},
        )
        result[:status].should_not eq(0)
        result[:error].should contain("failed to open")
      end

      it "shows help with --help" do
        result = run_binary(["snapshot", "open", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("snapshot open")
        result[:output].should contain("--pid")
        result[:output].should contain("--ledger-session-id")
        result[:output].should contain("EDITOR RESOLUTION")
      end
    end
  end

  describe "backup subcommand" do
    # Use the test data dir for backup isolation
    backup_dir = SPEC_DATA_DIR / "backups"

    before_each do
      FileUtils.rm_rf(backup_dir) if Dir.exists?(backup_dir)
      # Ensure backups config points to the test backup dir
      Dir.mkdir_p(SPEC_CONFIG_DIR)
      config_data = {
        "extraction" => {
          "on_stop"           => false,
          "on_guideline_read" => false,
        },
        "backups" => {
          "enabled"        => true,
          "retention_days" => 3,
          "path"           => backup_dir.to_s,
        },
      }
      File.write(SPEC_CONFIG_DIR / "config.json", config_data.to_json)
    end

    it "shows help with --help" do
      result = run_binary(["backup", "--help"])
      result[:status].should eq(0)
      result[:output].should contain("galaxy-ledger backup")
      result[:output].should contain("--list")
      result[:output].should contain("--prune-only")
      result[:output].should contain("--session-id")
    end

    it "creates a backup file" do
      result = run_binary(["backup"])
      result[:status].should eq(0)
      result[:output].should contain("Backup created")

      # Verify backup file exists in today's directory
      today = Time.local.to_s("%Y-%m-%d")
      today_dir = backup_dir / today
      Dir.exists?(today_dir).should be_true

      # Should have at least one .db file
      db_files = Dir.children(today_dir).select(&.ends_with?(".db"))
      db_files.size.should be >= 1
    end

    it "uses provided session ID in filename" do
      result = run_binary(["backup", "--session-id", "42"])
      result[:status].should eq(0)

      today = Time.local.to_s("%Y-%m-%d")
      File.exists?(backup_dir / today / "ledger_42.db").should be_true
    end

    it "lists backups" do
      # Create a backup first
      run_binary(["backup", "--session-id", "99"])

      result = run_binary(["backup", "--list"])
      result[:status].should eq(0)
      result[:output].should contain("Backups in")
      result[:output].should contain("ledger_99.db")
      result[:output].should contain("Total:")
    end

    it "shows empty state when no backups exist" do
      result = run_binary(["backup", "--list"])
      result[:status].should eq(0)
      result[:output].should contain("No backups found")
    end

    it "prunes without creating a backup" do
      result = run_binary(["backup", "--prune-only"])
      result[:status].should eq(0)
      result[:output].should contain("No backups to prune")
    end

    it "reports disabled state" do
      Dir.mkdir_p(SPEC_CONFIG_DIR)
      config_data = {
        "_schema_version" => GalaxyLedger::VERSION,
        "version"         => GalaxyLedger::VERSION,
        "thresholds"      => {"warning" => 70, "critical" => 85},
        "warnings"        => {"at_warning_threshold" => true, "at_critical_threshold" => true},
        "extraction"      => {"on_stop" => false, "on_guideline_read" => false},
        "storage"         => {
          "postgres_enabled"       => false,
          "postgres_host_port"     => 5433,
          "embeddings_enabled"     => false,
          "openai_api_key_env_var" => "GALAXY_OPENAI_API_KEY",
        },
        "restoration" => {
          "max_essential_tokens" => 2000,
          "tier1_limits"         => {"high_importance_decisions" => 10},
          "tier2_limits"         => {"learnings" => 5, "medium_importance_decisions" => 5},
        },
        "snapshots" => {
          "inline_char_cap" => 15000,
          "max_per_session" => 10,
          "editor"          => "",
        },
        "backups" => {
          "enabled"        => false,
          "retention_days" => 3,
          "path"           => backup_dir.to_s,
        },
      }
      File.write(SPEC_CONFIG_DIR / "config.json", config_data.to_json)

      result = run_binary(["backup"])
      result[:status].should eq(0)
      result[:output].should contain("disabled")
    end
  end

  describe "list-entries --json" do
    it "outputs valid JSON with entries array" do
      session_id = "json-entries-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "JWT tokens expire after 15 minutes",
        importance: "high",
        source: "assistant",
        category: "auth",
        keywords: ["jwt", "auth"],
        source_file: "/home/user/notes.md",
      )
      GalaxyLedger::Database.insert(ledger_session_id, entry)

      result = run_binary(["list-entries", "--json", "--session", session_id])
      result[:status].should eq(0)

      parsed = JSON.parse(result[:output])
      entries = parsed["entries"].as_a
      entries.size.should eq(1)

      e = entries[0]
      e["id"].as_i64.should be > 0
      e["entry_type"].as_s.should eq("learning")
      e["source"].as_s.should eq("assistant")
      e["content"].as_s.should eq("JWT tokens expire after 15 minutes")
      e["importance"].as_s.should eq("high")
      e["category"].as_s.should eq("auth")
      e["keywords"].as_s.should contain("jwt")
      e["source_file"].as_s.should eq("/home/user/notes.md")
      e["ledger_session_id"].as_i64.should eq(ledger_session_id)
      e["created_at"].as_s.should_not be_empty
    end

    it "outputs empty entries array when no data" do
      session_id = "json-entries-empty-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(session_id)

      result = run_binary(["list-entries", "--json", "--session", session_id])
      result[:status].should eq(0)

      parsed = JSON.parse(result[:output])
      parsed["entries"].as_a.size.should eq(0)
    end

    it "handles null fields in JSON output" do
      session_id = "json-entries-null-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      entry = GalaxyLedger::Entry.new(
        entry_type: "decision",
        content: "Use SQLite for storage",
        importance: "medium",
      )
      GalaxyLedger::Database.insert(ledger_session_id, entry)

      result = run_binary(["list-entries", "--json", "--session", session_id])
      result[:status].should eq(0)

      e = JSON.parse(result[:output])["entries"].as_a[0]
      e["source"].as_s?.should be_nil
      e["category"].as_s?.should be_nil
      e["keywords"].as_s?.should be_nil
      e["source_file"].as_s?.should be_nil
    end
  end

  describe "list-entries --ledger-session-id" do
    it "resolves session by internal DB ID" do
      session_id = "lsid-entries-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Direct ID resolution works",
        importance: "medium",
      )
      GalaxyLedger::Database.insert(ledger_session_id, entry)

      result = run_binary(["list-entries", "--json", "--ledger-session-id", ledger_session_id.to_s])
      result[:status].should eq(0)

      entries = JSON.parse(result[:output])["entries"].as_a
      entries.size.should eq(1)
      entries[0]["content"].as_s.should eq("Direct ID resolution works")
    end
  end

  describe "list-files --json" do
    it "outputs valid JSON with files array" do
      session_id = "json-files-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/home/user/src/app.cr", :edit)
      GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/home/user/src/app.cr", :read)
      GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/home/user/README.md", :read)

      result = run_binary(["list-files", "--json", "--session", session_id])
      result[:status].should eq(0)

      parsed = JSON.parse(result[:output])
      files = parsed["files"].as_a
      files.size.should eq(2)

      app_file = files.find { |f| f["file_path"].as_s.includes?("app.cr") }
      app_file.should_not be_nil
      if af = app_file
        af["id"].as_i64.should be > 0
        af["file_path"].as_s.should eq("/home/user/src/app.cr")
        af["is_read"].as_bool.should be_true
        af["is_edited"].as_bool.should be_true
        af["is_written"].as_bool.should be_false
        af["is_searched"].as_bool.should be_false
        af["access_count"].as_i64.should be >= 2
      end
    end

    it "outputs empty files array when no data" do
      session_id = "json-files-empty-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(session_id)

      result = run_binary(["list-files", "--json", "--session", session_id])
      result[:status].should eq(0)

      parsed = JSON.parse(result[:output])
      parsed["files"].as_a.size.should eq(0)
    end

    it "fetches all files without limit when --json is used" do
      session_id = "json-files-nolimit-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      60.times do |i|
        GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/home/user/file#{i}.rb", :read)
      end

      result = run_binary(["list-files", "--json", "--session", session_id])
      result[:status].should eq(0)

      files = JSON.parse(result[:output])["files"].as_a
      files.size.should eq(60)
    end

    it "includes search_pattern for searched files" do
      session_id = "json-files-search-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      GalaxyLedger::Database.upsert_session_file(
        ledger_session_id, "/home/user/src/", :search,
        search_pattern: "extraction_marker"
      )

      result = run_binary(["list-files", "--json", "--session", session_id])
      result[:status].should eq(0)

      f = JSON.parse(result[:output])["files"].as_a[0]
      f["is_searched"].as_bool.should be_true
      f["search_pattern"].as_s.should eq("extraction_marker")
    end
  end

  describe "list-files --ledger-session-id" do
    it "resolves session by internal DB ID" do
      session_id = "lsid-files-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/home/user/test.rb", :read)

      result = run_binary(["list-files", "--json", "--ledger-session-id", ledger_session_id.to_s])
      result[:status].should eq(0)

      files = JSON.parse(result[:output])["files"].as_a
      files.size.should eq(1)
      files[0]["file_path"].as_s.should eq("/home/user/test.rb")
    end
  end

  describe "search --json" do
    it "outputs valid JSON with entries array" do
      session_id = "json-search-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "JWT tokens expire after 15 minutes",
        importance: "high",
        source: "assistant",
      )
      GalaxyLedger::Database.insert(ledger_session_id, entry)

      result = run_binary(["search", "--json", "--query", "JWT"])
      result[:status].should eq(0)

      parsed = JSON.parse(result[:output])
      entries = parsed["entries"].as_a
      entries.size.should eq(1)
      entries[0]["content"].as_s.should contain("JWT")
      entries[0]["entry_type"].as_s.should eq("learning")
    end

    it "outputs empty entries array when no matches" do
      result = run_binary(["search", "--json", "--query", "nonexistent-query-xyz"])
      result[:status].should eq(0)

      parsed = JSON.parse(result[:output])
      parsed["entries"].as_a.size.should eq(0)
    end
  end

  describe "search --ledger-session-id" do
    it "scopes search by internal DB ID" do
      session_id = "lsid-search-#{Random.rand(100000)}"
      ledger_session_id = GalaxyLedger::Database.create_session(session_id)

      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Scoped search via ledger session ID",
        importance: "medium",
      )
      GalaxyLedger::Database.insert(ledger_session_id, entry)

      # Also add entry to a different session
      other_session_id = "lsid-search-other-#{Random.rand(100000)}"
      other_lsid = GalaxyLedger::Database.create_session(other_session_id)
      other_entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Different scoped search entry",
        importance: "medium",
      )
      GalaxyLedger::Database.insert(other_lsid, other_entry)

      result = run_binary(["search", "--json", "--query", "scoped", "--ledger-session-id", ledger_session_id.to_s])
      result[:status].should eq(0)

      entries = JSON.parse(result[:output])["entries"].as_a
      entries.size.should eq(1)
      entries[0]["content"].as_s.should contain("Scoped search via ledger session ID")
    end
  end
end
