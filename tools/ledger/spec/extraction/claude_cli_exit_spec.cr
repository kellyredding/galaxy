require "../spec_helper"

describe GalaxyLedger::Extraction::ClaudeCLI do
  describe ".describe_exit" do
    it "names the exit code of a child that exited" do
      status = Process.run("sh", args: ["-c", "exit 3"])
      GalaxyLedger::Extraction::ClaudeCLI.describe_exit(status).should eq("exit 3")
    end

    it "names the signal that killed a child" do
      status = Process.run("sh", args: ["-c", "kill -TERM $$"])
      GalaxyLedger::Extraction::ClaudeCLI.describe_exit(status).should eq("signal TERM")
    end
  end
end
