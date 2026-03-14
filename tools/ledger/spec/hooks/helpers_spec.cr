require "../spec_helper"

describe GalaxyLedger::Hooks::Helpers do
  describe ".shorten_home_path" do
    it "replaces home directory prefix with ~" do
      home = Path.home.to_s
      path = "#{home}/projects/myapp/src/file.cr"
      GalaxyLedger::Hooks::Helpers.shorten_home_path(path).should eq("~/projects/myapp/src/file.cr")
    end

    it "returns path unchanged when not under home" do
      path = "/tmp/other/file.cr"
      GalaxyLedger::Hooks::Helpers.shorten_home_path(path).should eq("/tmp/other/file.cr")
    end

    it "handles home directory exactly" do
      home = Path.home.to_s
      GalaxyLedger::Hooks::Helpers.shorten_home_path(home).should eq("~")
    end
  end

  describe ".truncate" do
    it "returns text unchanged when within limit" do
      GalaxyLedger::Hooks::Helpers.truncate("hello", 10).should eq("hello")
    end

    it "truncates text exceeding limit" do
      result = GalaxyLedger::Hooks::Helpers.truncate("hello world", 8)
      result.should eq("hello...")
      result.size.should eq(8)
    end

    it "uses custom suffix" do
      result = GalaxyLedger::Hooks::Helpers.truncate("hello world", 9, suffix: "..")
      result.should eq("hello w..")
    end

    it "handles text exactly at limit" do
      GalaxyLedger::Hooks::Helpers.truncate("hello", 5).should eq("hello")
    end

    it "handles very short limit" do
      result = GalaxyLedger::Hooks::Helpers.truncate("hello world", 3)
      result.should eq("...")
    end
  end

  describe ".build_system_message" do
    it "returns empty state with prefix when no data" do
      msg = GalaxyLedger::Hooks::Helpers.build_system_message(
        prefix: "Handoff",
        empty_message: "No previous context to hand off."
      )
      msg.should eq("Handoff │ No previous context to hand off.")
    end

    it "returns empty state for startup" do
      msg = GalaxyLedger::Hooks::Helpers.build_system_message(
        prefix: "Ledger active",
        empty_message: "New session"
      )
      msg.should eq("Ledger active │ New session")
    end

    it "counts guidelines and plans from files, not restoration" do
      tier1 = GalaxyLedger::Database::Tier1Result.new(
        high_importance_decisions: [make_stored_entry("decision")] * 2
      )
      tier2 = GalaxyLedger::Database::Tier2Result.new(
        learnings: [] of GalaxyLedger::Database::StoredEntry,
        medium_decisions: [] of GalaxyLedger::Database::StoredEntry
      )
      restoration = GalaxyLedger::Database::RestorationResult.new(tier1, tier2)

      files = [
        make_session_file("/path/agent-guidelines/ruby.md", file_type: "guideline"),
        make_session_file("/path/agent-guidelines/rspec.md", file_type: "guideline"),
        make_session_file("/path/agent-guidelines/git.md", file_type: "guideline"),
        make_session_file("/path/implementation-plans/feature.md", file_type: "implementation_plan"),
        make_session_file("/path/src/app.cr", file_type: "source"),
      ]

      msg = GalaxyLedger::Hooks::Helpers.build_system_message(
        prefix: "Handoff",
        empty_message: "No previous context to hand off.",
        restoration: restoration,
        files: files
      )
      msg.should contain("3 guidelines")
      msg.should contain("1 plan")
      msg.should contain("2 decisions")
      msg.should contain("5 session files")
    end

    it "includes file count" do
      files = [make_session_file("/path/a.rb"), make_session_file("/path/b.rb")]

      msg = GalaxyLedger::Hooks::Helpers.build_system_message(
        prefix: "Handoff",
        empty_message: "No data.",
        files: files
      )
      msg.should contain("2 session files")
    end

    it "uses singular forms correctly" do
      tier1 = GalaxyLedger::Database::Tier1Result.new(
        high_importance_decisions: [] of GalaxyLedger::Database::StoredEntry
      )
      tier2 = GalaxyLedger::Database::Tier2Result.new(
        learnings: [make_stored_entry("learning")],
        medium_decisions: [] of GalaxyLedger::Database::StoredEntry
      )
      restoration = GalaxyLedger::Database::RestorationResult.new(tier1, tier2)
      files = [
        make_session_file("/path/agent-guidelines/ruby.md", file_type: "guideline"),
      ]

      msg = GalaxyLedger::Hooks::Helpers.build_system_message(
        prefix: "Handoff",
        empty_message: "No data.",
        restoration: restoration,
        files: files
      )
      msg.should contain("1 guideline")
      msg.should_not contain("1 guidelines")
      msg.should contain("1 learning")
      msg.should_not contain("1 learnings")
      msg.should contain("1 session file")
      msg.should_not contain("1 session files")
    end

    it "merges high and medium decisions in count" do
      tier1 = GalaxyLedger::Database::Tier1Result.new(
        high_importance_decisions: [make_stored_entry("decision")] * 2
      )
      tier2 = GalaxyLedger::Database::Tier2Result.new(
        learnings: [] of GalaxyLedger::Database::StoredEntry,
        medium_decisions: [make_stored_entry("decision")] * 3
      )
      restoration = GalaxyLedger::Database::RestorationResult.new(tier1, tier2)

      msg = GalaxyLedger::Hooks::Helpers.build_system_message(
        prefix: "Handoff",
        empty_message: "No data.",
        restoration: restoration
      )
      msg.should contain("5 decisions")
    end

    it "shows zero guidelines when no guideline files exist" do
      tier1 = GalaxyLedger::Database::Tier1Result.new(
        high_importance_decisions: [make_stored_entry("decision")]
      )
      tier2 = GalaxyLedger::Database::Tier2Result.new(
        learnings: [] of GalaxyLedger::Database::StoredEntry,
        medium_decisions: [] of GalaxyLedger::Database::StoredEntry
      )
      restoration = GalaxyLedger::Database::RestorationResult.new(tier1, tier2)
      files = [make_session_file("/path/src/app.cr", file_type: "source")]

      msg = GalaxyLedger::Hooks::Helpers.build_system_message(
        prefix: "Handoff",
        empty_message: "No data.",
        restoration: restoration,
        files: files
      )
      msg.should_not contain("guideline")
      msg.should_not contain("plan")
      msg.should contain("1 decision")
    end
  end

  describe ".output_json" do
    it "produces valid JSON with expected structure" do
      json_str = GalaxyLedger::Hooks::Helpers.output_json("status line", "context here")
      parsed = JSON.parse(json_str)
      parsed["systemMessage"].as_s.should eq("status line")
      parsed["hookSpecificOutput"]["hookEventName"].as_s.should eq("SessionStart")
      parsed["hookSpecificOutput"]["additionalContext"].as_s.should eq("context here")
    end
  end
end

# Helper to create a StoredEntry for testing
def make_stored_entry(entry_type : String, content : String = "test content") : GalaxyLedger::Database::StoredEntry
  GalaxyLedger::Database::StoredEntry.new(
    id: Random.rand(10000).to_i64,
    created_at: "2026-01-01T00:00:00Z",
    ledger_session_id: 1_i64,
    entry_type: entry_type,
    source: nil,
    content: content,
    content_hash: "hash-#{Random.rand(10000)}",
    metadata: nil,
    importance: "medium"
  )
end

# Helper to create a SessionFile for testing
def make_session_file(
  path : String,
  file_type : String = "other",
) : GalaxyLedger::Database::SessionFile
  GalaxyLedger::Database::SessionFile.new(
    id: Random.rand(10000).to_i64,
    ledger_session_id: 1_i64,
    file_path: path,
    search_pattern: "",
    is_read: true,
    is_edited: false,
    is_written: false,
    is_searched: false,
    first_seen_at: "2026-01-01T00:00:00Z",
    last_seen_at: "2026-01-01T00:00:00Z",
    access_count: 1_i64,
    metadata: nil,
    file_type: file_type,
  )
end
