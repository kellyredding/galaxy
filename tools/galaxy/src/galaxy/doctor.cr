require "json"

module Galaxy
  # `galaxy doctor`: what is installed, whether it all came from one build,
  # and whether macOS will route galaxy:// to the installed app.
  module Doctor
    extend self

    LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Versions/" \
                 "Current/Frameworks/LaunchServices.framework/Versions/Current/" \
                 "Support/lsregister"

    record Finding, ok : Bool, text : String

    def run : Int32
      findings = [] of Finding
      manifest = read_manifest

      puts "Galaxy install"
      if manifest
        dirty = manifest["dirty"]?.try(&.as_bool?) ? ", uncommitted changes" : ""
        puts "  Suite:    #{manifest["version"]?} (#{manifest["commit"]?}#{dirty})"
        puts "  Built:    #{manifest["built_at"]?}, signing: #{manifest["signing"]?}"
      else
        findings << Finding.new(false, "No install record at #{INSTALLED_MANIFEST}: this install predates install.sh. Run `galaxy update`.")
      end

      expected = manifest ? tool_versions(manifest) : {} of String => String
      installed = installed_tool_versions(expected.keys)
      findings.concat(compare_tools(expected, installed))

      findings.concat(app_findings(manifest))
      findings.concat(registration_findings(registered_apps))

      puts ""
      findings.each { |f| puts "  #{f.ok ? "✓" : "✗"} #{f.text}" }
      problems = findings.count { |f| !f.ok }
      puts ""
      puts problems.zero? ? "All good." : "#{problems} problem#{problems == 1 ? "" : "s"}. `galaxy update` fixes most of them."
      problems.zero? ? 0 : 1
    end

    def read_manifest(path : Path = INSTALLED_MANIFEST) : JSON::Any?
      return nil unless File.exists?(path)
      JSON.parse(File.read(path))
    rescue JSON::ParseException
      nil
    end

    def tool_versions(manifest : JSON::Any) : Hash(String, String)
      result = {} of String => String
      manifest["tools"]?.try(&.as_h?).try &.each do |name, version|
        result[name] = version.as_s
      end
      result
    end

    # Each tool prints either "name X.Y.Z" or just "X.Y.Z"; the version is
    # the last word either way.
    def installed_tool_versions(names : Array(String), bin_dir : Path = BIN_DIR) : Hash(String, String?)
      result = {} of String => String?
      names.each do |name|
        bin = bin_dir / name
        result[name] = if File.exists?(bin) && File.info(bin).permissions.owner_execute?
                         output = IO::Memory.new
                         Process.run(bin.to_s, ["--version"], output: output, error: Process::Redirect::Close)
                         output.to_s.split.last?
                       end
      end
      result
    end

    def compare_tools(expected : Hash(String, String), installed : Hash(String, String?)) : Array(Finding)
      expected.map do |name, want|
        have = installed[name]?
        if have.nil?
          Finding.new(false, "#{name}: missing from #{BIN_DIR}")
        elsif have == want
          Finding.new(true, "#{name} #{have}")
        else
          Finding.new(false, "#{name}: #{have} installed, #{want} expected")
        end
      end
    end

    def app_findings(manifest : JSON::Any?, app : Path = INSTALLED_APP) : Array(Finding)
      if File.symlink?(app)
        return [Finding.new(false, "#{app} is a link into a build folder (#{File.realpath(app) rescue "missing"}); `galaxy update` installs a real copy.")]
      end
      return [Finding.new(false, "#{app} is not installed")] unless Dir.exists?(app)

      findings = [] of Finding
      commit = plist_value(app, "GalaxyBuildCommit")
      want = manifest.try(&.["commit"]?.try(&.as_s?))
      if commit.nil?
        findings << Finding.new(false, "Galaxy.app carries no build stamp; it was not installed by install.sh")
      elsif want && commit != want
        findings << Finding.new(false, "Galaxy.app is from #{commit}, the tools from #{want}")
      else
        findings << Finding.new(true, "Galaxy.app #{plist_value(app, "CFBundleShortVersionString")} (#{commit})")
      end

      signer = signing_authority(app)
      findings << if signer
        Finding.new(true, "Galaxy.app signed by #{signer}")
      else
        Finding.new(false, "Galaxy.app is ad-hoc signed, so macOS asks for its permissions again after every update")
      end
      findings
    end

    def registration_findings(paths : Array(String), app : Path = INSTALLED_APP) : Array(Finding)
      others = paths.reject { |p| p == app.to_s }
      findings = [] of Finding
      findings << if paths.includes?(app.to_s)
        Finding.new(true, "Launch Services knows #{app}")
      else
        Finding.new(false, "Launch Services does not know #{app}; galaxy:// may not open it")
      end
      others.each do |path|
        findings << Finding.new(false, "Another Galaxy.app is registered and may receive galaxy:// links: #{path}")
      end
      findings
    end

    def registered_apps : Array(String)
      output = IO::Memory.new
      Process.run(LSREGISTER, ["-dump"], output: output, error: Process::Redirect::Close)
      output.to_s.lines.compact_map do |line|
        line.match(/^path:\s+(.*\/Galaxy\.app) \(0x[0-9a-f]+\)$/).try(&.[1])
      end.uniq
    rescue File::NotFoundError
      [] of String
    end

    private def plist_value(app : Path, key : String) : String?
      output = IO::Memory.new
      status = Process.run(
        "/usr/libexec/PlistBuddy", ["-c", "Print :#{key}", (app / "Contents" / "Info.plist").to_s],
        output: output, error: Process::Redirect::Close,
      )
      status.success? ? output.to_s.strip : nil
    end

    private def signing_authority(app : Path) : String?
      output = IO::Memory.new
      Process.run("codesign", ["-dv", "--verbose=2", app.to_s], output: output, error: output)
      output.to_s.each_line.find(&.starts_with?("Authority=")).try(&.lchop("Authority="))
    end
  end
end
