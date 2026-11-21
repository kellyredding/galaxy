require "../spec_helper"
require "socket"

private BINARY = File.expand_path(File.join(__DIR__, "../../build/galaxy"))

# Stands in for galaxy.sock: answers each request envelope with `reply`
# (given the parsed envelope), and keeps every envelope it was sent.
private class FakeGalaxy
  getter path : String
  getter requests = [] of JSON::Any

  def initialize(&reply : JSON::Any -> String)
    @path = "/tmp/gxr-#{Random.rand(1_000_000)}.sock"
    @server = UNIXServer.new(@path)
    server = @server
    requests = @requests
    spawn do
      while client = server.accept?
        if raw = client.gets
          envelope = JSON.parse(raw)
          requests << envelope
          client.puts reply.call(envelope)
        end
        client.close rescue nil
      end
    end
  end

  def close
    @server.close rescue nil
  end
end

private def galaxy(args : Array(String), env = {} of String => String) : {Int32, String, String}
  out_io = IO::Memory.new
  err_io = IO::Memory.new
  base = {"HOME" => ENV["HOME"], "PATH" => ENV["PATH"], "GALAXY_DIR" => SPEC_GALAXY_DIR.to_s,
          "CLAUDE_PERSONA_DIR" => SPEC_FIXTURES.to_s}
  status = Process.run(BINARY, args: args, output: out_io, error: err_io, env: base.merge(env), clear_env: true)
  {status.exit_code, out_io.to_s, err_io.to_s}
end

private def detail_of(fake : FakeGalaxy, index = 0) : JSON::Any
  fake.requests[index]["detail_data"]
end

# Stands in for galaxy-watch.sock: accepts every subscription and sends
# `lines`, then holds the connection open.
private class FakeWatch
  getter path : String

  def initialize(lines : Array(String))
    @path = "/tmp/gxw-cli-#{Random.rand(1_000_000)}.sock"
    @server = UNIXServer.new(@path)
    server = @server
    spawn do
      while client = server.accept?
        c = client
        spawn do
          if raw = c.gets
            c.puts({"v" => 1, "subscribed" => JSON.parse(raw)["subscribe"]}.to_json)
            lines.each { |l| c.puts l }
            sleep 5.seconds
          end
          c.close rescue nil
        end
      end
    end
  end

  def close
    @server.close rescue nil
  end
end

private def fake_watch(lines : Array(String)) : FakeWatch
  FakeWatch.new(lines)
end

# A galaxy-timeline stand-in. `row` answers the newest-row lookup and every
# list; `after_20`, when given, answers lists that start at event 20 or later.
private def fake_timeline(row : String, after_20 : String? = nil) : String
  dir = "#{SPEC_GALAXY_DIR}/fake-timeline-#{Random.rand(1_000_000)}"
  Dir.mkdir_p(dir)
  script = "#{dir}/galaxy-timeline"
  later = after_20 || row
  File.write(script, <<-SH)
    #!/bin/sh
    after=0
    reverse=no
    while [ $# -gt 0 ]; do
      case "$1" in
        --after-id) after=$2; shift ;;
        --reverse) reverse=yes ;;
      esac
      shift
    done
    if [ "$reverse" = no ] && [ "$after" -ge 20 ]; then
      echo '{"events":[#{later}]}'
    else
      echo '{"events":[#{row}]}'
    fi
    SH
  File.chmod(script, 0o755)
  script
end

describe "galaxy session" do
  it "prints usage for help" do
    code, stdout, _ = galaxy(["session", "help"])
    code.should eq(0)
    stdout.should contain("galaxy session new --as OWNER")
    stdout.should contain("SEND FILE")
  end

  it "tells a driver to wait for session:exited, not session:ended, before dismissing" do
    _, stdout, _ = galaxy(["session", "help"])
    stdout.should contain("galaxy session wait <id> --events session:exited")
    stdout.should contain("not\n  session:ended")
  end

  describe "new" do
    it "sends session.create with the absolute directory and prints the reply" do
      fake = FakeGalaxy.new { |_e| %({"ok":true,"id":"abc","token":"t0k","name":"Worker","owner":"Atlas lead"}) }
      code, stdout, err = galaxy(
        ["session", "new", "--as", "Atlas lead", "--dir", "/tmp", "--name", "Worker", "--no-wait"],
        {"GALAXY_SOCKET_PATH" => fake.path})

      err.should eq("")
      code.should eq(0)
      JSON.parse(stdout).should eq(JSON.parse(%({"id":"abc","token":"t0k","name":"Worker","owner":"Atlas lead"})))
      envelope = fake.requests.first
      envelope["event"].as_s.should eq("session.create")
      envelope["ledger_session_id"].as_i64.should eq(0)
      envelope["v"].as_i.should eq(1)
      detail = envelope["detail_data"]
      detail["owner"].as_s.should eq("Atlas lead")
      detail["directory"].as_s.should eq("/tmp")
      detail["name"].as_s.should eq("Worker")
      detail["persona"]?.should be_nil
    ensure
      fake.try(&.close)
    end

    it "passes a persona that exists" do
      fake = FakeGalaxy.new { |_e| %({"ok":true,"id":"abc","token":"t"}) }
      code, _, _ = galaxy(["session", "new", "--as", "L", "--dir", "/tmp", "--persona", "test-basic", "--no-wait"],
        {"GALAXY_SOCKET_PATH" => fake.path})
      code.should eq(0)
      detail_of(fake)["persona"].as_s.should eq("test-basic")
    ensure
      fake.try(&.close)
    end

    it "reports Galaxy refusing a folder Claude Code has not trusted" do
      fake = FakeGalaxy.new do |_e|
        %({"ok":false,"error":"Claude Code has not trusted /tmp: trust it first (open claude there once and accept the dialog) or use a folder it already trusts"})
      end
      code, stdout, err = galaxy(["session", "new", "--as", "L", "--dir", "/tmp"], {"GALAXY_SOCKET_PATH" => fake.path})

      code.should eq(1)
      stdout.should eq("")
      err.should contain("Claude Code has not trusted /tmp")
    ensure
      fake.try(&.close)
    end

    it "refuses a missing owner, directory or persona before asking Galaxy" do
      galaxy(["session", "new", "--dir", "/tmp"])[2].should contain("--as OWNER is required")
      galaxy(["session", "new", "--as", "L", "--dir", "/nonexistent-#{Random.rand(1000)}"])[2].should contain("no such directory")
      galaxy(["session", "new", "--as", "L", "--dir", "/tmp", "--persona", "nope"])[2].should contain("no persona named 'nope'")
    end
  end

  describe "token commands" do
    it "sends the id and token, from the flag or the environment" do
      fake = FakeGalaxy.new { |e| %({"ok":true,"id":"abc","locked":#{e["event"].as_s == "session.lock"}}) }
      code, stdout, _ = galaxy(["session", "lock", "abc", "--token", "flag-token"], {"GALAXY_SOCKET_PATH" => fake.path})
      code.should eq(0)
      JSON.parse(stdout)["locked"].as_bool.should be_true

      galaxy(["session", "release", "abc"], {"GALAXY_SOCKET_PATH" => fake.path, "GALAXY_SESSION_TOKEN" => "env-token"})

      fake.requests.map(&.["event"].as_s).should eq(["session.lock", "session.release"])
      detail_of(fake, 0)["token"].as_s.should eq("flag-token")
      detail_of(fake, 1)["token"].as_s.should eq("env-token")
      detail_of(fake, 1)["id"].as_s.should eq("abc")
    ensure
      fake.try(&.close)
    end

    it "sends stop_holder for resume and prints the acceptance" do
      fake = FakeGalaxy.new { |_e| %({"ok":true,"id":"abc","accepted":true}) }
      code, stdout, _ = galaxy(["session", "resume", "abc", "--token", "t", "--stop-holder", "--no-wait"], {"GALAXY_SOCKET_PATH" => fake.path})
      galaxy(["session", "resume", "abc", "--token", "t", "--no-wait"], {"GALAXY_SOCKET_PATH" => fake.path})
      code.should eq(0)
      JSON.parse(stdout)["accepted"].as_bool.should be_true
      detail_of(fake, 0)["stop_holder"].as_bool.should be_true
      detail_of(fake, 1)["stop_holder"].as_bool.should be_false
    ensure
      fake.try(&.close)
    end

    it "needs a token" do
      code, _, err = galaxy(["session", "clear", "abc"])
      code.should eq(1)
      err.should contain("clear needs --token")
    end

    it "reports Galaxy's refusal on stderr with exit 1" do
      fake = FakeGalaxy.new { |_e| %({"ok":false,"error":"held by pid 4242 (interactive)","holder_pid":4242}) }
      code, stdout, err = galaxy(["session", "resume", "abc", "--token", "t"], {"GALAXY_SOCKET_PATH" => fake.path})
      code.should eq(1)
      stdout.should eq("")
      err.should eq("Error: held by pid 4242 (interactive)\n")
    ensure
      fake.try(&.close)
    end

    it "says so when Galaxy is not running" do
      code, _, err = galaxy(["session", "stop", "abc", "--token", "t"],
        {"GALAXY_SOCKET_PATH" => "/tmp/gxr-missing-#{Random.rand(1_000_000)}.sock"})
      code.should eq(1)
      err.should contain("Galaxy isn't running")
    end
  end

  describe "send" do
    it "validates the file and sends the parsed input with its id" do
      fake = FakeGalaxy.new { |_e| %({"ok":true,"id":"abc","input_id":"lead-7","duplicate":false}) }
      file = File.tempfile("input", ".json") do |f|
        f.print %({"id":"lead-7","summary":"Two","notes":[{"quote":"a line","note":"a reply"}]})
      end
      code, stdout, err = galaxy(["session", "send", "abc", "--token", "t", file.path], {"GALAXY_SOCKET_PATH" => fake.path})

      err.should eq("")
      code.should eq(0)
      JSON.parse(stdout).should eq(JSON.parse(%({"id":"abc","input_id":"lead-7","duplicate":false})))
      input = detail_of(fake)["input"]
      input["id"].as_s.should eq("lead-7")
      input["summary"].as_s.should eq("Two")
      input["notes"][0]["quote"].as_s.should eq("a line")
    ensure
      fake.try(&.close)
      file.try(&.delete)
    end

    it "treats a resend Galaxy already accepted as success" do
      fake = FakeGalaxy.new { |_e| %({"ok":true,"id":"abc","input_id":"lead-7","duplicate":true}) }
      file = File.tempfile("input", ".json") { |f| f.print %({"id":"lead-7","message":"again"}) }
      code, stdout, _ = galaxy(["session", "send", "abc", "--token", "t", file.path], {"GALAXY_SOCKET_PATH" => fake.path})

      code.should eq(0)
      JSON.parse(stdout)["duplicate"].as_bool.should be_true
    ensure
      fake.try(&.close)
      file.try(&.delete)
    end

    it "fails when the id was already used for different content" do
      fake = FakeGalaxy.new { |_e| %({"ok":false,"error":"input id lead-7 was already used for different content"}) }
      file = File.tempfile("input", ".json") { |f| f.print %({"id":"lead-7","message":"changed"}) }
      code, stdout, err = galaxy(["session", "send", "abc", "--token", "t", file.path], {"GALAXY_SOCKET_PATH" => fake.path})

      code.should eq(1)
      stdout.should eq("")
      err.should eq("Error: input id lead-7 was already used for different content\n")
    ensure
      fake.try(&.close)
      file.try(&.delete)
    end

    it "lists every problem in an invalid file without contacting Galaxy" do
      fake = FakeGalaxy.new { |_e| %({"ok":true}) }
      file = File.tempfile("input", ".json") { |f| f.print %({"mesage":"typo","notes":[{"note":"x"}]}) }
      code, _, err = galaxy(["session", "send", "abc", "--token", "t", file.path], {"GALAXY_SOCKET_PATH" => fake.path})

      code.should eq(1)
      err.should contain("id: missing")
      err.should contain("mesage: unknown key")
      err.should contain("notes[0].quote: missing")
      err.should contain("Valid shapes:")
      fake.requests.should be_empty
    ensure
      fake.try(&.close)
      file.try(&.delete)
    end

    it "needs a file" do
      galaxy(["session", "send", "abc", "--token", "t"])[2].should contain("send needs a JSON file")
    end
  end

  describe "status and list" do
    it "prints the session object" do
      fake = FakeGalaxy.new { |_e| %({"ok":true,"session":{"id":"abc","owner":"L","locked":true,"ledger_session_id":830}}) }
      code, stdout, _ = galaxy(["session", "status", "abc"], {"GALAXY_SOCKET_PATH" => fake.path})
      code.should eq(0)
      JSON.parse(stdout)["ledger_session_id"].as_i64.should eq(830)
    ensure
      fake.try(&.close)
    end

    it "lists with the owner filter, dismissed sessions included on request" do
      fake = FakeGalaxy.new { |_e| %({"ok":true,"sessions":[{"id":"abc","dismissed":true}]}) }
      code, stdout, _ = galaxy(["session", "list", "--owner", "Atlas lead", "--include-dismissed"], {"GALAXY_SOCKET_PATH" => fake.path})
      galaxy(["session", "list"], {"GALAXY_SOCKET_PATH" => fake.path})
      code.should eq(0)
      JSON.parse(stdout)["sessions"][0]["dismissed"].as_bool.should be_true
      detail_of(fake)["owner"].as_s.should eq("Atlas lead")
      detail_of(fake)["include_dismissed"].as_bool.should be_true
      detail_of(fake, 1)["include_dismissed"].as_bool.should be_false
    ensure
      fake.try(&.close)
    end

    it "no longer accepts --include-closed" do
      code, _, err = galaxy(["session", "list", "--include-closed"])
      code.should eq(1)
      err.should contain("unknown flag '--include-closed'")
    end
  end

  describe "dismiss and restore" do
    it "sends the id and token and prints whether the session is dismissed" do
      fake = FakeGalaxy.new do |e|
        %({"ok":true,"id":"abc","dismissed":#{e["event"].as_s == "session.dismiss"}})
      end
      code, stdout, _ = galaxy(["session", "dismiss", "abc", "--token", "t"], {"GALAXY_SOCKET_PATH" => fake.path})
      code.should eq(0)
      JSON.parse(stdout).should eq(JSON.parse(%({"id":"abc","dismissed":true})))

      code, stdout, _ = galaxy(["session", "restore", "abc", "--token", "t"], {"GALAXY_SOCKET_PATH" => fake.path})
      code.should eq(0)
      JSON.parse(stdout).should eq(JSON.parse(%({"id":"abc","dismissed":false})))

      fake.requests.map(&.["event"].as_s).should eq(["session.dismiss", "session.restore"])
      detail_of(fake, 0)["token"].as_s.should eq("t")
      detail_of(fake, 1)["id"].as_s.should eq("abc")
    ensure
      fake.try(&.close)
    end

    it "reports a refusal to dismiss a running session" do
      fake = FakeGalaxy.new { |_e| %({"ok":false,"error":"session is running; stop it first"}) }
      code, _, err = galaxy(["session", "dismiss", "abc", "--token", "t"], {"GALAXY_SOCKET_PATH" => fake.path})
      code.should eq(1)
      err.should eq("Error: session is running; stop it first\n")
    ensure
      fake.try(&.close)
    end

    it "needs a token" do
      galaxy(["session", "restore", "abc"])[2].should contain("restore needs --token")
    end
  end

  describe "read" do
    it "reads the timeline after a cursor, details parsed" do
      dir = "#{SPEC_GALAXY_DIR}/fake-timeline-#{Random.rand(100000)}"
      Dir.mkdir_p(dir)
      args_log = "#{dir}/args"
      script = "#{dir}/galaxy-timeline"
      File.write(script, <<-SH)
        #!/bin/sh
        echo "$@" > #{args_log}
        echo '{"events":[{"id":12,"event_type":"turn:completed","occurred_at":"2026-11-20 19:39:20","source":"galaxy-ledger","detail_data":"{\\"assistant_response\\":\\"done\\"}"}]}'
        SH
      File.chmod(script, 0o755)

      code, stdout, err = galaxy(["session", "read", "abc", "--after", "11", "--ledger-session-id", "830"],
        {"GALAXY_TIMELINE_BIN" => script})

      err.should eq("")
      code.should eq(0)
      event = JSON.parse(stdout)["events"][0]
      event["id"].as_i64.should eq(12)
      event["type"].as_s.should eq("turn:completed")
      event["occurred_at"].as_s.should eq("2026-11-20T19:39:20Z")
      event["detail"]["assistant_response"].as_s.should eq("done")
      File.read(args_log).should contain("--ledger-session-id 830 --after-id 11")
    end

    it "refuses a limit that is not a positive number" do
      code, _, err = galaxy(["session", "read", "abc", "--limit", "0", "--ledger-session-id", "830"])
      code.should eq(1)
      err.should contain("--limit needs a positive number")
    end

    it "asks Galaxy for the ledger session, and prints nothing before there is one" do
      fake = FakeGalaxy.new { |_e| %({"ok":true,"session":{"id":"abc","ledger_session_id":null}}) }
      code, stdout, _ = galaxy(["session", "read", "abc"], {"GALAXY_SOCKET_PATH" => fake.path})
      code.should eq(0)
      JSON.parse(stdout)["events"].as_a.should be_empty
      fake.requests.first["event"].as_s.should eq("session.status")
    ensure
      fake.try(&.close)
    end
  end

  describe "waiting for input after new and resume" do
    it "new waits for session:input-ready and reports the opening turn" do
      fake = FakeGalaxy.new do |e|
        e["event"].as_s == "session.create" ? %({"ok":true,"id":"abc","token":"t0k"}) : %({"ok":true,"session":{"id":"abc","ledger_session_id":830}})
      end
      watch = fake_watch([%({"v":1,"event_id":20,"type":"session:input-ready","session_id":"abc","occurred_at":"x"})])
      timeline = fake_timeline(%({"id":20,"event_type":"session:input-ready","occurred_at":"2026-11-21 16:50:59","source":"galaxy-app/driven","detail_data":"{\\"opening_event_id\\":18}"}))

      code, stdout, err = galaxy(["session", "new", "--as", "L", "--dir", "/tmp", "--timeout", "5"],
        {"GALAXY_SOCKET_PATH" => fake.path, "GALAXY_WATCH_SOCKET_PATH" => watch.path, "GALAXY_TIMELINE_BIN" => timeline})

      err.should eq("")
      code.should eq(0)
      JSON.parse(stdout).should eq(JSON.parse(%({"id":"abc","token":"t0k","opening_event_id":18})))
    ensure
      fake.try(&.close)
      watch.try(&.close)
    end

    it "new reports a quiet start as a null opening" do
      fake = FakeGalaxy.new do |e|
        e["event"].as_s == "session.create" ? %({"ok":true,"id":"abc","token":"t0k"}) : %({"ok":true,"session":{"id":"abc","ledger_session_id":830}})
      end
      watch = fake_watch([%({"v":1,"event_id":20,"type":"session:input-ready","session_id":"abc","occurred_at":"x"})])
      timeline = fake_timeline(%({"id":20,"event_type":"session:input-ready","occurred_at":"2026-11-21 16:50:59","source":"galaxy-app/driven","detail_data":"{\\"opening_event_id\\":null}"}))

      code, stdout, _ = galaxy(["session", "new", "--as", "L", "--dir", "/tmp", "--timeout", "5"],
        {"GALAXY_SOCKET_PATH" => fake.path, "GALAXY_WATCH_SOCKET_PATH" => watch.path, "GALAXY_TIMELINE_BIN" => timeline})

      code.should eq(0)
      JSON.parse(stdout)["opening_event_id"].raw.should be_nil
    ensure
      fake.try(&.close)
      watch.try(&.close)
    end

    it "new fails with the exit details if the session exits first, still printing the token" do
      fake = FakeGalaxy.new do |e|
        e["event"].as_s == "session.create" ? %({"ok":true,"id":"abc","token":"t0k"}) : %({"ok":true,"session":{"id":"abc","ledger_session_id":830}})
      end
      watch = fake_watch([%({"v":1,"event_id":21,"type":"session:exited","session_id":"abc","occurred_at":"x"})])
      timeline = fake_timeline(%({"id":21,"event_type":"session:exited","occurred_at":"2026-11-21 16:50:59","source":"galaxy-app/driven","detail_data":"{\\"exit_code\\":1}"}))

      code, stdout, err = galaxy(["session", "new", "--as", "L", "--dir", "/tmp", "--timeout", "5"],
        {"GALAXY_SOCKET_PATH" => fake.path, "GALAXY_WATCH_SOCKET_PATH" => watch.path, "GALAXY_TIMELINE_BIN" => timeline})

      code.should eq(1)
      JSON.parse(stdout).should eq(JSON.parse(%({"id":"abc","token":"t0k","input_ready":false})))
      err.should contain("exited before it was ready for input (exit code 1)")
    ensure
      fake.try(&.close)
      watch.try(&.close)
    end

    it "new exits 2 when --timeout runs out, still printing the token" do
      fake = FakeGalaxy.new do |e|
        e["event"].as_s == "session.create" ? %({"ok":true,"id":"abc","token":"t0k"}) : %({"ok":true,"session":{"id":"abc","ledger_session_id":null}})
      end
      watch = fake_watch([] of String)

      code, stdout, _ = galaxy(["session", "new", "--as", "L", "--dir", "/tmp", "--timeout", "0.3"],
        {"GALAXY_SOCKET_PATH" => fake.path, "GALAXY_WATCH_SOCKET_PATH" => watch.path})

      code.should eq(2)
      JSON.parse(stdout)["token"].as_s.should eq("t0k")
    ensure
      fake.try(&.close)
      watch.try(&.close)
    end

    it "resume ignores input-ready rows from earlier launches" do
      fake = FakeGalaxy.new do |e|
        e["event"].as_s == "session.resume" ? %({"ok":true,"id":"abc","accepted":true}) : %({"ok":true,"session":{"id":"abc","ledger_session_id":830}})
      end
      watch = fake_watch([%({"v":1,"event_id":30,"type":"session:input-ready","session_id":"abc","occurred_at":"x"})])
      # The newest row before the resume is an earlier launch's input-ready
      # (20); rows after it are this launch's (30, after its /galaxy:resume).
      timeline = fake_timeline(
        %({"id":20,"event_type":"session:input-ready","occurred_at":"2026-11-21 16:00:00","source":"galaxy-app/driven","detail_data":"{\\"opening_event_id\\":12}"}),
        after_20: %({"id":30,"event_type":"session:input-ready","occurred_at":"2026-11-21 17:00:00","source":"galaxy-app/driven","detail_data":"{\\"opening_event_id\\":28}"}))

      code, stdout, err = galaxy(["session", "resume", "abc", "--token", "t", "--timeout", "5"],
        {"GALAXY_SOCKET_PATH" => fake.path, "GALAXY_WATCH_SOCKET_PATH" => watch.path, "GALAXY_TIMELINE_BIN" => timeline})

      err.should eq("")
      code.should eq(0)
      JSON.parse(stdout).should eq(JSON.parse(%({"id":"abc","accepted":true,"opening_event_id":28})))
    ensure
      fake.try(&.close)
      watch.try(&.close)
    end
  end

  describe "wait" do
    it "exits 2 on timeout" do
      watch = "/tmp/gxw-cli-#{Random.rand(1_000_000)}.sock"
      server = UNIXServer.new(watch)
      spawn do
        if client = server.accept?
          client.gets
          client.puts %({"v":1,"subscribed":"abc"})
          sleep 2.seconds
          client.close rescue nil
        end
      end

      code, _, _ = galaxy(["session", "wait", "abc", "--after", "0", "--timeout", "0.3"],
        {"GALAXY_WATCH_SOCKET_PATH" => watch, "GALAXY_SOCKET_PATH" => "/tmp/gxr-none-#{Random.rand(100000)}.sock"})
      code.should eq(2)
    ensure
      server.try(&.close)
    end

    it "exits 3 when the session is dismissed before its event" do
      watch = "/tmp/gxw-cli-#{Random.rand(1_000_000)}.sock"
      server = UNIXServer.new(watch)
      spawn do
        if client = server.accept?
          client.gets
          client.puts %({"v":1,"subscribed":"abc"})
          client.puts %({"v":1,"event_id":null,"type":"session:dismissed","session_id":"abc","occurred_at":"x","detail":{"initiated_by":"user"}})
          client.close rescue nil
        end
      end

      code, stdout, _ = galaxy(["session", "wait", "abc", "--after", "0", "--events", "turn:*", "--timeout", "3"],
        {"GALAXY_WATCH_SOCKET_PATH" => watch, "GALAXY_SOCKET_PATH" => "/tmp/gxr-none-#{Random.rand(100000)}.sock"})
      code.should eq(3)
      stdout.should eq("")
    ensure
      server.try(&.close)
    end

    it "exits 0 printing the first matching event" do
      watch = "/tmp/gxw-cli-#{Random.rand(1_000_000)}.sock"
      server = UNIXServer.new(watch)
      spawn do
        if client = server.accept?
          client.gets
          client.puts %({"v":1,"subscribed":"abc"})
          client.puts %({"v":1,"event_id":null,"type":"session.idle","session_id":"abc","occurred_at":"x"})
          client.puts %({"v":1,"event_id":5,"type":"turn:completed","session_id":"abc","occurred_at":"x"})
          sleep 2.seconds
          client.close rescue nil
        end
      end

      code, stdout, _ = galaxy(["session", "wait", "abc", "--after", "0", "--events", "turn:*", "--timeout", "3"],
        {"GALAXY_WATCH_SOCKET_PATH" => watch, "GALAXY_SOCKET_PATH" => "/tmp/gxr-none-#{Random.rand(100000)}.sock"})
      code.should eq(0)
      stdout.lines.size.should eq(1)
      JSON.parse(stdout)["event_id"].as_i64.should eq(5)
    ensure
      server.try(&.close)
    end
  end
end
