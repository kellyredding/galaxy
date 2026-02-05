require "../spec_helper"

# Helper to create a test session with database entries
def create_test_session_with_entries(session_id : String, entry_count : Int32 = 3)
  session_dir = GalaxyLedger.session_dir(session_id)
  Dir.mkdir_p(session_dir)

  entry_count.times do |i|
    entry = GalaxyLedger::Entry.new(
      entry_type: "learning",
      content: "Test learning #{i + 1}",
      importance: "medium",
      created_at: "2026-02-01T10:0#{i}:00Z"
    )
    GalaxyLedger::Database.insert(session_id, entry)
  end
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
    it "outputs JSON with additionalContext" do
      result = run_binary(["on-startup"])
      result[:status].should eq(0)

      # Parse the output as JSON
      output = JSON.parse(result[:output])
      output["hookSpecificOutput"]["hookEventName"].should eq("SessionStart")
      output["hookSpecificOutput"]["additionalContext"].as_s.should contain("Galaxy Ledger Available")
    end

    it "includes ledger awareness information" do
      result = run_binary(["on-startup"])
      result[:status].should eq(0)

      output = JSON.parse(result[:output])
      context = output["hookSpecificOutput"]["additionalContext"].as_s
      context.should contain("persistent context ledger")
      context.should contain("galaxy-ledger search")
    end

    it "creates session folder when session_id provided" do
      session_id = "test-startup-session-#{Random.rand(100000)}"
      session_dir = GalaxyLedger.session_dir(session_id)

      # Clean up any existing session
      FileUtils.rm_rf(session_dir.to_s)

      # Run on-startup with session_id
      result = run_binary(["on-startup"], stdin: %({"session_id": "#{session_id}"}))
      result[:status].should eq(0)

      # Verify session folder was created
      Dir.exists?(session_dir).should eq(true)

      # Clean up
      FileUtils.rm_rf(session_dir.to_s)
    end
  end

  describe "session subcommand" do
    test_session_id = "test-cli-session-#{Random.rand(100000)}"

    describe "session (no args)" do
      it "shows help when no subcommand provided" do
        result = run_binary(["session"])
        result[:output].should contain("galaxy-ledger session")
        result[:output].should contain("USAGE")
        result[:status].should eq(0)
      end
    end

    describe "session list" do
      it "lists sessions" do
        result = run_binary(["session", "list"])
        result[:status].should eq(0)
        # Output should either show sessions or "No sessions found"
        output = result[:output]
        (output.includes?("Sessions") || output.includes?("No sessions")).should eq(true)
      end
    end

    describe "session show SESSION_ID" do
      it "shows session details for existing session" do
        # Create a test session
        session_dir = GalaxyLedger.session_dir(test_session_id)
        Dir.mkdir_p(session_dir)

        result = run_binary(["session", "show", test_session_id])
        result[:status].should eq(0)
        result[:output].should contain("Session: #{test_session_id}")
        result[:output].should contain("Path:")
        result[:output].should contain("Status:")

        # Clean up
        FileUtils.rm_rf(session_dir.to_s)
      end

      it "outputs error for non-existent session" do
        result = run_binary(["session", "show", "nonexistent-session-#{Random.rand(100000)}"])
        result[:error].should contain("Session not found")
        result[:status].should_not eq(0)
      end

      it "outputs error when session_id not provided" do
        result = run_binary(["session", "show"])
        result[:error].should contain("Usage")
        result[:status].should_not eq(0)
      end
    end

    describe "session remove SESSION_ID" do
      it "removes existing session" do
        # Create a test session
        session_dir = GalaxyLedger.session_dir(test_session_id)
        Dir.mkdir_p(session_dir)
        # Add a test file
        File.write(session_dir / "test.txt", "test content")

        # Verify it exists
        Dir.exists?(session_dir).should eq(true)

        result = run_binary(["session", "remove", test_session_id])
        result[:status].should eq(0)
        result[:output].should contain("Removed session")
        result[:output].should contain("Folder removed: yes")

        # Verify it's gone
        Dir.exists?(session_dir).should eq(false)
      end

      it "outputs error for non-existent session" do
        result = run_binary(["session", "remove", "nonexistent-session-#{Random.rand(100000)}"])
        result[:error].should contain("Session not found")
        result[:status].should_not eq(0)
      end

      it "outputs error when session_id not provided" do
        result = run_binary(["session", "remove"])
        result[:error].should contain("Usage")
        result[:status].should_not eq(0)
      end
    end

    describe "session help" do
      it "shows session help" do
        result = run_binary(["session", "help"])
        result[:output].should contain("galaxy-ledger session")
        result[:output].should contain("USAGE")
        result[:status].should eq(0)
      end
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

  describe "session remove purges from SQLite" do
    before_each do
      # Clean database for isolation
      db_path = GalaxyLedger::Database.database_path
      File.delete(db_path) if File.exists?(db_path)
    end

    it "purges entries from database when session removed" do
      session_id = "purge-test-#{Random.rand(100000)}"
      create_test_session_with_entries(session_id, 3)

      begin
        # Verify entries are in database
        GalaxyLedger::Database.count_by_session(session_id).should eq(3)

        # Remove session
        result = run_binary(["session", "remove", session_id])
        result[:status].should eq(0)
        result[:output].should contain("SQLite purged: yes")

        # Verify entries are gone
        GalaxyLedger::Database.count_by_session(session_id).should eq(0)
      ensure
        FileUtils.rm_rf(GalaxyLedger.session_dir(session_id).to_s)
      end
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

    describe "session --help" do
      it "shows help with --help flag" do
        result = run_binary(["session", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("USAGE")
        result[:output].should contain("session list")
        result[:output].should contain("session show")
        result[:output].should contain("session remove")
      end

      it "shows help with -h flag" do
        result = run_binary(["session", "-h"])
        result[:status].should eq(0)
        result[:output].should contain("USAGE")
      end

      it "shows subcommand help for session list --help" do
        result = run_binary(["session", "list", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("session list")
      end

      it "shows subcommand help for session show --help" do
        result = run_binary(["session", "show", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("session show")
        result[:output].should contain("SESSION_ID")
      end

      it "shows subcommand help for session remove --help" do
        result = run_binary(["session", "remove", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("session remove")
        result[:output].should contain("SESSION_ID")
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

      it "shows help for on-session-start --help" do
        result = run_binary(["on-session-start", "--help"])
        result[:status].should eq(0)
        result[:output].should contain("on-session-start")
        result[:output].should contain("clear|compact")
        result[:output].should contain("INPUT")
        result[:output].should contain("OUTPUT")
        result[:output].should contain("HOOK CONFIGURATION")
      end
    end
  end

  describe "top-level help banner" do
    it "lists all user-facing commands" do
      result = run_binary(["--help"])
      result[:status].should eq(0)
      result[:output].should contain("search")
      result[:output].should contain("list")
      result[:output].should contain("add")
      result[:output].should contain("config")
      result[:output].should contain("session")
    end

    it "lists hook commands in separate section" do
      result = run_binary(["--help"])
      result[:status].should eq(0)
      result[:output].should contain("Hook Commands")
      result[:output].should contain("on-startup")
      result[:output].should contain("on-stop")
      result[:output].should contain("on-session-start")
    end

    it "includes discoverability hint" do
      result = run_binary(["--help"])
      result[:status].should eq(0)
      result[:output].should contain("--help")
      result[:output].should contain("detailed command usage")
    end
  end
end
