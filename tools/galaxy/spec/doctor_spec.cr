require "./spec_helper"

describe Galaxy::Doctor do
  describe ".tool_versions" do
    it "reads the tools table from an install manifest" do
      manifest = JSON.parse(%({"version": "0.1.0", "tools": {"galaxy": "0.1.0", "galaxy-ledger": "0.7.1"}}))
      Galaxy::Doctor.tool_versions(manifest).should eq(
        {"galaxy" => "0.1.0", "galaxy-ledger" => "0.7.1"})
    end
  end

  describe ".installed_tool_versions" do
    it "takes the last word of --version, in either output style" do
      dir = Path.new(Dir.tempdir) / "galaxy-doctor-bin-#{Random.rand(100000)}"
      Dir.mkdir_p(dir)
      File.write(dir / "galaxy", "#!/bin/sh\necho 0.1.0\n")
      File.write(dir / "galaxy-ledger", "#!/bin/sh\necho galaxy-ledger 0.7.1\n")
      File.chmod(dir / "galaxy", 0o755)
      File.chmod(dir / "galaxy-ledger", 0o755)
      begin
        Galaxy::Doctor.installed_tool_versions(%w[galaxy galaxy-ledger galaxy-diff], dir).should eq(
          {"galaxy" => "0.1.0", "galaxy-ledger" => "0.7.1", "galaxy-diff" => nil})
      ensure
        FileUtils.rm_rf(dir.to_s)
      end
    end
  end

  describe ".compare_tools" do
    it "passes a match and names a mismatch and a missing tool" do
      findings = Galaxy::Doctor.compare_tools(
        {"galaxy" => "0.1.0", "galaxy-ledger" => "0.7.1", "galaxy-diff" => "0.1.0"},
        {"galaxy" => "0.1.0", "galaxy-ledger" => "0.7.0", "galaxy-diff" => nil} of String => String?,
      )
      findings.map(&.ok).should eq([true, false, false])
      findings[1].text.should contain("0.7.0 installed, 0.7.1 expected")
      findings[2].text.should contain("missing")
    end
  end

  describe ".app_findings" do
    it "flags an app that is a link into a build folder" do
      dir = Path.new(Dir.tempdir) / "galaxy-doctor-app-#{Random.rand(100000)}"
      Dir.mkdir_p(dir)
      link = dir / "Galaxy.app"
      File.symlink("/nonexistent/Galaxy.app", link)
      begin
        findings = Galaxy::Doctor.app_findings(nil, link)
        findings.size.should eq(1)
        findings.first.ok.should be_false
        findings.first.text.should contain("link into a build folder")
      ensure
        FileUtils.rm_rf(dir.to_s)
      end
    end

    it "flags a missing app" do
      missing = Path.new(Dir.tempdir) / "galaxy-no-app-#{Random.rand(100000)}" / "Galaxy.app"
      Galaxy::Doctor.app_findings(nil, missing).first.text.should contain("not installed")
    end
  end

  describe ".registration_findings" do
    app = Path.new("/Users/x/Applications/Galaxy.app")

    it "passes when only the installed app is registered" do
      findings = Galaxy::Doctor.registration_findings([app.to_s], app)
      findings.all?(&.ok).should be_true
    end

    it "names every other registered copy" do
      build = "/src/galaxy/GalaxyApp/build/Build/Products/Debug/Galaxy.app"
      findings = Galaxy::Doctor.registration_findings([app.to_s, build], app)
      findings.count { |f| !f.ok }.should eq(1)
      findings.last.text.should contain(build)
    end

    it "fails when the installed app is not registered" do
      Galaxy::Doctor.registration_findings([] of String, app).first.ok.should be_false
    end
  end
end
