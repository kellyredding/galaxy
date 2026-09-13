require "./spec_helper"

# The command's own share of the contract: which session is asking, the envelope
# it sends, the paths it makes absolute, and printing a read's JSON untouched
# and a change's message. The rules and the sentences belong to the app.
describe "galaxy-files" do
  it "sends the asking session's ledger identity with every request" do
    with_reply_server(%({"ok":true,"sets":[]})) do |sock, channel|
      result = run_binary(["list", "--pid", SPEC_PID], env: {"GALAXY_SOCKET_PATH" => sock})
      result[:status].should eq(0)

      envelope = JSON.parse(channel.receive)
      envelope["v"].as_i.should eq(1)
      envelope["event"].as_s.should eq("file_set.list")
      envelope["ledger_session_id"].as_i64.should eq(SPEC_LEDGER_SESSION_ID)
      envelope["session_identifiers"].as_a.map(&.as_s).should eq(["claude-one", "claude-two"])
    end
  end

  it "needs --pid before asking anything" do
    result = run_binary(["list"])
    result[:status].should eq(1)
    result[:error].should contain("--pid is required")
  end

  it "relays the ledger's refusal of a pid it does not know" do
    result = run_binary(["list", "--pid", "999"])
    result[:status].should eq(1)
    result[:error].should contain("no ledger session for PID 999")
  end

  it "says so when the app does not answer" do
    result = run_binary(["list", "--pid", SPEC_PID])
    result[:status].should eq(1)
    result[:error].should contain("no reply from Galaxy (is the app running?)")
  end

  it "relays the app's refusal and exits non-zero" do
    reply = {ok: false, error: "There is no set named “nope”."}.to_json
    with_reply_server(reply) do |sock, _|
      result = run_binary(["show", "--pid", SPEC_PID, "nope"], env: {"GALAXY_SOCKET_PATH" => sock})
      result[:status].should eq(1)
      result[:error].should contain("Error: There is no set named “nope”.")
    end
  end

  describe "list" do
    it "prints the reply untouched" do
      reply = %({"ok":true,"sets":[{"default":true,"files":2,"name":"Default","notes":0,"origin":"user","selected":true}]})
      with_reply_server(reply) do |sock, _|
        result = run_binary(["list", "--pid", SPEC_PID], env: {"GALAXY_SOCKET_PATH" => sock})
        result[:output].should eq("#{reply}\n")
      end
    end

    it "takes no arguments" do
      result = run_binary(["list", "--pid", SPEC_PID, "extra"])
      result[:status].should eq(1)
      result[:error].should contain("list takes no arguments")
    end
  end

  describe "view" do
    it "sends the set name and prints the reply untouched" do
      reply = %({"files":[],"ok":true,"root":"/tmp","set":{"name":"auth flow"}})
      with_reply_server(reply) do |sock, channel|
        result = run_binary(["view", "--pid", SPEC_PID, "auth flow"], env: {"GALAXY_SOCKET_PATH" => sock})
        result[:output].should eq("#{reply}\n")

        envelope = JSON.parse(channel.receive)
        envelope["event"].as_s.should eq("file_set.view")
        envelope["detail_data"]["name"].as_s.should eq("auth flow")
      end
    end

    it "needs exactly one name" do
      result = run_binary(["view", "--pid", SPEC_PID])
      result[:status].should eq(1)
      result[:error].should contain("view takes one set name")
    end
  end

  describe "open" do
    it "sends absolute paths as given and prints the app's message" do
      message = "Made “auth” and opened 2 files in it. It is on screen."
      with_reply_server({ok: true, message: message}.to_json) do |sock, channel|
        result = run_binary(
          ["open", "--pid", SPEC_PID, "auth", "/tmp/a.rb", "/tmp/b.rb"],
          env: {"GALAXY_SOCKET_PATH" => sock},
        )
        result[:status].should eq(0)
        result[:output].should eq("#{message}\n")

        envelope = JSON.parse(channel.receive)
        envelope["event"].as_s.should eq("file_set.open")
        envelope["detail_data"]["name"].as_s.should eq("auth")
        envelope["detail_data"]["paths"].as_a.map(&.as_s).should eq(["/tmp/a.rb", "/tmp/b.rb"])
      end
    end

    it "makes a relative path absolute against the working directory" do
      dir = File.join(Dir.tempdir, "gf-cwd-#{Random.rand(1_000_000)}")
      Dir.mkdir_p(dir)
      begin
        with_reply_server(%({"message":"Opened.","ok":true})) do |sock, channel|
          run_binary(
            ["open", "--pid", SPEC_PID, "auth", "src/a.rb", "./b.rb", "src/../c.rb"],
            env: {"GALAXY_SOCKET_PATH" => sock},
            chdir: dir,
          )
          real = File.realpath(dir)
          JSON.parse(channel.receive)["detail_data"]["paths"].as_a.map(&.as_s).should eq([
            File.join(real, "src/a.rb"),
            File.join(real, "b.rb"),
            File.join(real, "c.rb"),
          ])
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "keeps the shell's spelling of a symlinked working directory" do
      real = File.join(Dir.tempdir, "gf-real-#{Random.rand(1_000_000)}")
      link = File.join(Dir.tempdir, "gf-link-#{Random.rand(1_000_000)}")
      Dir.mkdir_p(real)
      File.symlink(real, link)
      begin
        with_reply_server(%({"message":"Opened.","ok":true})) do |sock, channel|
          run_binary(
            ["open", "--pid", SPEC_PID, "auth", "a.rb"],
            env: {"GALAXY_SOCKET_PATH" => sock, "PWD" => link},
            chdir: link,
          )
          JSON.parse(channel.receive)["detail_data"]["paths"].as_a.map(&.as_s).should eq([
            File.join(link, "a.rb"),
          ])
        end
      ensure
        File.delete(link) if File.symlink?(link)
        FileUtils.rm_rf(real)
      end
    end

    it "expands ~ in a path the shell did not" do
      with_reply_server(%({"message":"Opened.","ok":true})) do |sock, channel|
        run_binary(
          ["open", "--pid", SPEC_PID, "auth", "~/notes.md"],
          env: {"GALAXY_SOCKET_PATH" => sock, "HOME" => "/tmp/gf-home"},
        )
        JSON.parse(channel.receive)["detail_data"]["paths"].as_a.map(&.as_s).should eq([
          "/tmp/gf-home/notes.md",
        ])
      end
    end

    it "takes a path that begins with a dash after --" do
      with_reply_server(%({"message":"Opened.","ok":true})) do |sock, channel|
        result = run_binary(
          ["open", "--pid", SPEC_PID, "auth", "--", "-odd.rb"],
          env: {"GALAXY_SOCKET_PATH" => sock},
        )
        result[:status].should eq(0)
        paths = JSON.parse(channel.receive)["detail_data"]["paths"].as_a.map(&.as_s)
        paths.size.should eq(1)
        paths[0].should end_with("/-odd.rb")
      end
    end

    it "needs a set name and at least one file, before any request" do
      result = run_binary(["open", "--pid", SPEC_PID])
      result[:status].should eq(1)
      result[:error].should contain("a set name is required")

      result = run_binary(["open", "--pid", SPEC_PID, "auth"])
      result[:status].should eq(1)
      result[:error].should contain("name at least one file to open")
    end

    it "refuses an unknown flag" do
      result = run_binary(["open", "--pid", SPEC_PID, "auth", "--force", "a.rb"])
      result[:status].should eq(1)
      result[:error].should contain("unknown flag '--force'")
    end
  end

  describe "show" do
    it "sends the set name and prints the app's message" do
      with_reply_server(%({"message":"“Default” is on screen.","ok":true})) do |sock, channel|
        result = run_binary(["show", "--pid", SPEC_PID, "Default"], env: {"GALAXY_SOCKET_PATH" => sock})
        result[:output].should eq("“Default” is on screen.\n")

        envelope = JSON.parse(channel.receive)
        envelope["event"].as_s.should eq("file_set.show")
        envelope["detail_data"]["name"].as_s.should eq("Default")
      end
    end
  end

  describe "rename" do
    it "sends the name and the new name" do
      with_reply_server(%({"message":"Renamed “auth” to “auth flow”.","ok":true})) do |sock, channel|
        result = run_binary(["rename", "--pid", SPEC_PID, "auth", "auth flow"], env: {"GALAXY_SOCKET_PATH" => sock})
        result[:output].should eq("Renamed “auth” to “auth flow”.\n")

        detail = JSON.parse(channel.receive)["detail_data"]
        detail["name"].as_s.should eq("auth")
        detail["new_name"].as_s.should eq("auth flow")
      end
    end

    it "needs both names" do
      result = run_binary(["rename", "--pid", SPEC_PID, "auth"])
      result[:status].should eq(1)
      result[:error].should contain("rename takes the set's name and its new name")
    end
  end

  describe "delete" do
    it "sends the remove request and prints the app's message" do
      with_reply_server(%({"message":"Removed “auth”; it had no files open.","ok":true})) do |sock, channel|
        result = run_binary(["delete", "--pid", SPEC_PID, "auth"], env: {"GALAXY_SOCKET_PATH" => sock})
        result[:output].should eq("Removed “auth”; it had no files open.\n")

        envelope = JSON.parse(channel.receive)
        envelope["event"].as_s.should eq("file_set.remove")
        envelope["detail_data"]["name"].as_s.should eq("auth")
      end
    end

    it "answers to remove as well" do
      with_reply_server(%({"message":"Removed.","ok":true})) do |sock, channel|
        result = run_binary(["remove", "--pid", SPEC_PID, "auth"], env: {"GALAXY_SOCKET_PATH" => sock})
        result[:status].should eq(0)
        JSON.parse(channel.receive)["event"].as_s.should eq("file_set.remove")
      end
    end
  end

  it "prints help for itself and each command without a pid" do
    run_binary([] of String)[:output].should contain("COMMANDS:")
    %w(list view open show rename delete).each do |command|
      result = run_binary([command, "--help"])
      result[:status].should eq(0)
      result[:output].should contain("galaxy-files #{command}")
    end
  end

  it "rejects an unknown command" do
    result = run_binary(["close", "--pid", SPEC_PID, "auth"])
    result[:status].should eq(1)
    result[:error].should contain("Unknown command 'close'")
  end
end
