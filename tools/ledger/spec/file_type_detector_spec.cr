require "./spec_helper"
require "file_utils"

describe GalaxyLedger::FileTypeDetector do
  describe ".detect" do
    # Priority 1: Guidelines
    it "detects guideline files" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/agent-guidelines/ruby.md"
      ).should eq("guideline")
    end

    # Priority 1: Implementation plans
    it "detects implementation plan files" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/implementation-plans/2026-03-14_01_feature.md"
      ).should eq("implementation_plan")
    end

    # Priority 2: Tests
    it "detects spec files" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/spec/models/user_spec.cr"
      ).should eq("test")
    end

    it "detects test files" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/test/models/user_test.go"
      ).should eq("test")
    end

    it "detects __tests__ files" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/src/components/__tests__/Button.test.tsx"
      ).should eq("test")
    end

    it "detects fixtures" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/spec/fixtures/users.yml"
      ).should eq("test")
    end

    it "detects features (Cucumber)" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/features/login.feature"
      ).should eq("test")
    end

    # Priority 3: Scripts
    it "detects bin files" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/bin/setup"
      ).should eq("script")
    end

    it "detects scripts directory" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/scripts/deploy.sh"
      ).should eq("script")
    end

    it "detects script directory (Rails convention)" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/script/server"
      ).should eq("script")
    end

    # Priority 4: Docs
    it "detects docs directory" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/docs/architecture.md"
      ).should eq("doc")
    end

    it "detects doc directory" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/doc/api.md"
      ).should eq("doc")
    end

    it "detects markdown files anywhere as doc" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/README.md"
      ).should eq("doc")
    end

    # .md in agent-guidelines is guideline, not doc (priority 1 beats priority 4)
    it "prioritizes guideline over doc for .md" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/agent-guidelines/ruby.md"
      ).should eq("guideline")
    end

    # .md in implementation-plans is implementation_plan, not doc
    it "prioritizes implementation_plan over doc for .md" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/implementation-plans/feature.md"
      ).should eq("implementation_plan")
    end

    # Priority 5a: Known config filenames
    it "detects known config filenames" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/Gemfile"
      ).should eq("config")
    end

    it "detects shard.yml as config" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/shard.yml"
      ).should eq("config")
    end

    it "detects package.json as config" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/package.json"
      ).should eq("config")
    end

    it "detects dotfiles as config" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/.gitignore"
      ).should eq("config")
    end

    # Priority 5b: Config directories
    it "detects config directory" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/config/database.yml"
      ).should eq("config")
    end

    it "detects .github directory" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/.github/workflows/ci.yml"
      ).should eq("config")
    end

    it "detects .circleci directory" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/.circleci/config.yml"
      ).should eq("config")
    end

    # Priority 6: Source
    it "detects src directory" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/src/main.cr"
      ).should eq("source")
    end

    it "detects app directory" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/app/models/user.rb"
      ).should eq("source")
    end

    it "detects lib directory" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/lib/utils.py"
      ).should eq("source")
    end

    it "detects Go pkg directory" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/pkg/server/handler.go"
      ).should eq("source")
    end

    it "detects controllers directory" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/controllers/users_controller.rb"
      ).should eq("source")
    end

    # Priority ordering: test beats source
    it "prioritizes test over source for spec in app" do
      GalaxyLedger::FileTypeDetector.detect(
        "/home/user/projects/myapp/spec/models/user_spec.rb"
      ).should eq("test")
    end

    # Priority 5c: Root-level files detected as config
    describe "root-level file detection" do
      it "detects files at project root as config" do
        tmp_dir = File.tempname("galaxy-test", "")
        Dir.mkdir_p(tmp_dir)
        git_dir = File.join(tmp_dir, ".git")
        Dir.mkdir_p(git_dir)

        begin
          # A file directly in the root should be config
          GalaxyLedger::FileTypeDetector.detect(
            File.join(tmp_dir, ".custom-linter")
          ).should eq("config")

          # A file in a subdirectory should NOT be config
          # (falls through to other since subdir isn't a known path)
          sub_dir = File.join(tmp_dir, "misc")
          Dir.mkdir_p(sub_dir)
          GalaxyLedger::FileTypeDetector.detect(
            File.join(sub_dir, "notes.txt")
          ).should eq("other")
        ensure
          FileUtils.rm_rf(tmp_dir)
        end
      end

      it "detects root via Makefile marker (no .git)" do
        tmp_dir = File.tempname("galaxy-test", "")
        Dir.mkdir_p(tmp_dir)
        File.write(File.join(tmp_dir, "Makefile"), "")

        begin
          GalaxyLedger::FileTypeDetector.detect(
            File.join(tmp_dir, ".tool-config")
          ).should eq("config")
        ensure
          FileUtils.rm_rf(tmp_dir)
        end
      end

      it "does not detect root when no markers exist" do
        tmp_dir = File.tempname("galaxy-test", "")
        Dir.mkdir_p(tmp_dir)

        begin
          GalaxyLedger::FileTypeDetector.detect(
            File.join(tmp_dir, "mystery-file")
          ).should eq("other")
        ensure
          FileUtils.rm_rf(tmp_dir)
        end
      end
    end

    # Default
    it "returns other for unrecognized paths" do
      GalaxyLedger::FileTypeDetector.detect(
        "/tmp/random/file.dat"
      ).should eq("other")
    end

    it "returns other for empty path" do
      GalaxyLedger::FileTypeDetector.detect("").should eq("other")
    end
  end

  describe "FILE_TYPES" do
    it "lists all valid file types" do
      GalaxyLedger::FileTypeDetector::FILE_TYPES.should eq([
        "guideline",
        "implementation_plan",
        "test",
        "script",
        "doc",
        "config",
        "source",
        "other",
      ])
    end
  end
end
