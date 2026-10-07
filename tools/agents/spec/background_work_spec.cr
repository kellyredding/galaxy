require "./spec_helper"

private SESSION     = "11111111-2222-3333-4444-555555555555"
private PROJECT_DIR = SPEC_CLAUDE_CONFIG_DIR / "projects" / "-Users-someone-projects"

private def agent_path(agent_id : String) : String
  (PROJECT_DIR / SESSION / "subagents" / "agent-#{agent_id}.jsonl").to_s
end

private def task_stop_record(id : String) : String
  {
    "type"    => "assistant",
    "message" => {
      "content" => [
        {"type" => "tool_use", "name" => "TaskStop", "input" => {"task_id" => id}},
      ],
    },
  }.to_json
end

private def with_identifiers(ledger_session_id : Int64, ids : Array(String), &)
  path = SPEC_LEDGER_DATABASE_PATH.to_s
  File.delete(path) if File.exists?(path)
  DB.open("sqlite3://#{path}") do |db|
    db.exec("CREATE TABLE ledger_session_identifiers " \
            "(ledger_session_id INTEGER, session_identifier TEXT)")
    ids.each do |id|
      db.exec("INSERT INTO ledger_session_identifiers VALUES (?, ?)",
        ledger_session_id, id)
    end
  end
  begin
    yield
  ensure
    File.delete(path) if File.exists?(path)
  end
end

describe GalaxyAgents::BackgroundWork do
  before_each do
    FileUtils.rm_rf(PROJECT_DIR.to_s)
  end

  describe ".launched" do
    it "reads every launch marker" do
      write_transcript("bw1", [
        launch_record("b-bash"),
        launch_record("a-agent", :agent),
        launch_record("t-task", :task),
        %|{"type":"user","toolUseResult":{"agentId":"a-sync","isAsync":false}}|,
      ])
      GalaxyAgents::BackgroundWork.launched(agent_path("bw1"))
        .should eq(Set{"b-bash", "a-agent", "t-task"})
    end

    it "is empty for a missing transcript" do
      GalaxyAgents::BackgroundWork.launched("/nonexistent.jsonl")
        .should be_empty
    end
  end

  describe ".closed" do
    it "reads notifications of every status and explicit stops" do
      write_transcript("bw2", [
        notification_record("one"),
        notification_record("two", "killed"),
        task_stop_record("three"),
      ])
      GalaxyAgents::BackgroundWork.closed(agent_path("bw2"))
        .should eq(Set{"one", "two", "three"})
    end
  end

  describe ".outstanding" do
    it "is the launch that nothing has closed" do
      write_transcript("bw3", [launch_record("ci"), launch_record("done")])
      File.write(agent_path("bw3"), notification_record("done") + "\n", mode: "a")

      GalaxyAgents::BackgroundWork.outstanding(agent_path("bw3"), [] of String)
        .should eq(Set{"ci"})
    end

    it "is cleared by a notification delivered to the parent" do
      write_transcript("bw4", [launch_record("ci")])
      write_parent_transcript([notification_record("ci")])

      paths = GalaxyAgents::BackgroundWork.session_transcripts(agent_path("bw4"), 1_i64)
      GalaxyAgents::BackgroundWork.outstanding(agent_path("bw4"), paths)
        .should be_empty
    end

    it "is cleared by a notification in a later transcript of the session" do
      write_transcript("bw5", [launch_record("ci")])
      write_parent_transcript([%|{"type":"assistant"}|])
      after_clear = "99999999-0000-0000-0000-000000000000"
      File.write(PROJECT_DIR / "#{after_clear}.jsonl", notification_record("ci") + "\n")

      with_identifiers(7_i64, [SESSION, after_clear]) do
        paths = GalaxyAgents::BackgroundWork.session_transcripts(agent_path("bw5"), 7_i64)
        paths.should contain((PROJECT_DIR / "#{after_clear}.jsonl").to_s)
        GalaxyAgents::BackgroundWork.outstanding(agent_path("bw5"), paths)
          .should be_empty
      end
    end
  end

  describe ".quiet?" do
    it "tells a transcript just written from one left alone" do
      write_transcript("bw6", [%|{"type":"assistant"}|])
      GalaxyAgents::BackgroundWork.quiet?(agent_path("bw6"), 30.seconds).should be_false
      File.touch(agent_path("bw6"), Time.utc - 1.minute)
      GalaxyAgents::BackgroundWork.quiet?(agent_path("bw6"), 30.seconds).should be_true
    end
  end
end
