require "../spec_helper"

private def decision_of(output : String) : JSON::Any
  JSON.parse(output)["hookSpecificOutput"]
end

describe GalaxyLedger::Hooks::AllowPermission do
  describe ".decision" do
    it "allows and echoes the tool input back as updatedInput" do
      stdin = {
        "session_id" => "s1",
        "tool_name"  => "Bash",
        "tool_input" => {"command" => "npm run lint"},
      }.to_json

      out = decision_of(GalaxyLedger::Hooks::AllowPermission.decision(stdin))
      out["hookEventName"].as_s.should eq("PermissionRequest")
      out["decision"]["behavior"].as_s.should eq("allow")
      out["decision"]["updatedInput"]["command"].as_s.should eq("npm run lint")
    end

    it "allows without updatedInput when stdin has no tool input" do
      out = decision_of(GalaxyLedger::Hooks::AllowPermission.decision(%({"session_id":"s1"})))
      out["decision"].as_h.keys.should eq(["behavior"])
    end

    it "allows on empty or malformed stdin" do
      ["", "not json {{{", %({"tool_input":"a string"})].each do |stdin|
        out = decision_of(GalaxyLedger::Hooks::AllowPermission.decision(stdin))
        out["decision"]["behavior"].as_s.should eq("allow")
        out["decision"]["updatedInput"]?.should be_nil
      end
    end
  end
end

describe "allow-permission command" do
  it "prints the allow decision on stdout" do
    result = run_binary(
      ["allow-permission"],
      stdin: {"tool_input" => {"file_path" => "/tmp/x"}}.to_json,
    )
    result[:status].should eq(0)
    out = decision_of(result[:output])
    out["decision"]["behavior"].as_s.should eq("allow")
    out["decision"]["updatedInput"]["file_path"].as_s.should eq("/tmp/x")
  end

  # Unlike the on-* hooks, this one is never skipped: a skipped decision
  # would leave a driven session stalled at the prompt.
  it "still decides when GALAXY_SKIP_HOOKS is set" do
    result = run_binary(
      ["allow-permission"],
      stdin: "",
      extra_env: {"GALAXY_SKIP_HOOKS" => "1"},
    )
    result[:status].should eq(0)
    decision_of(result[:output])["decision"]["behavior"].as_s.should eq("allow")
  end

  it "shows help" do
    result = run_binary(["allow-permission", "--help"])
    result[:status].should eq(0)
    result[:output].should contain("PermissionRequest")
  end
end
