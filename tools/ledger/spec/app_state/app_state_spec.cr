require "../spec_helper"

private def app_session(
  block_reason : String?,
  lost_ready_recoverable : Bool = false,
  inbox_depth : Int32 = 1,
) : GalaxyLedger::AppState::Session
  GalaxyLedger::AppState::Session.new(
    ledger_session_id: 7_i64,
    session_ref: "weak-comet-glares",
    claude_session_id: "abc",
    inbox_depth: inbox_depth,
    block_reason: block_reason,
    lost_ready_recoverable: lost_ready_recoverable,
  )
end

describe GalaxyLedger::AppState do
  describe "Session#recoverable?" do
    it "is true for a session that never reported ready" do
      app_session("never-reported-ready").recoverable?.should be_true
    end

    it "is true for a reset the app says may have lost its readiness" do
      session = app_session("awaiting-reset", lost_ready_recoverable: true)

      session.recoverable?.should be_true
      session.awaiting_lost_ready?.should be_true
    end

    it "is false for a reset the app has not marked recoverable" do
      session = app_session("awaiting-reset")

      session.recoverable?.should be_false
      session.awaiting_lost_ready?.should be_false
    end

    it "is false for a session mid-turn, whatever the flag says" do
      app_session("in-turn", lost_ready_recoverable: true)
        .recoverable?.should be_false
    end
  end

  describe ".read" do
    it "reads the recoverable flag, defaulting it when the app omits it" do
      path = "/tmp/galaxy-test-sessions-#{Random.rand(100000)}.json"
      File.write(path, {
        "sidebarItems" => [
          {"session" => {
            "ledgerSessionId"      => 1,
            "sessionRef"           => "stuck",
            "inboxDepth"           => 1,
            "submitBlockReason"    => "awaiting-reset",
            "lostReadyRecoverable" => true,
          }},
          {"session" => {
            "ledgerSessionId"   => 2,
            "sessionRef"        => "older-app",
            "inboxDepth"        => 1,
            "submitBlockReason" => "awaiting-reset",
          }},
        ],
      }.to_json)

      begin
        reading = GalaxyLedger::AppState.read(path).not_nil!
        stuck, older = reading.sessions

        stuck.awaiting_lost_ready?.should be_true
        older.lost_ready_recoverable.should be_false
        older.recoverable?.should be_false
      ensure
        File.delete?(path)
      end
    end
  end
end
