module GalaxyLedger
  module FileTypeDetector
    extend self

    # Valid file types, ordered by detection priority.
    FILE_TYPES = [
      "guideline",
      "implementation_plan",
      "test",
      "script",
      "doc",
      "config",
      "source",
      "other",
    ]

    # --- Priority 1: Special ledger file types ---

    GUIDELINE_PATHS = [
      "/agent-guidelines/",
    ]

    IMPLEMENTATION_PLAN_PATHS = [
      "/implementation-plans/",
    ]

    # --- Priority 2: Test directories ---
    # Covers: RSpec, minitest, Crystal spec, Go, pytest, Jest,
    # Cucumber, PHPUnit, JUnit, fixtures

    TEST_PATHS = [
      "/spec/",
      "/test/",
      "/tests/",
      "/__tests__/",
      "/features/",
      "/fixtures/",
    ]

    # --- Priority 3: Script directories ---

    SCRIPT_PATHS = [
      "/bin/",
      "/scripts/",
      "/script/",
    ]

    # --- Priority 4: Documentation ---
    # Path-based detection plus *.md anywhere

    DOC_PATHS = [
      "/docs/",
      "/doc/",
      "/documentation/",
    ]

    # --- Priority 5: Config ---
    # Known root-level filenames (matched by basename) plus
    # config directories.

    CONFIG_FILENAMES = Set{
      "Makefile",
      "Rakefile",
      "Gemfile",
      "Gemfile.lock",
      "Guardfile",
      "Procfile",
      "Dockerfile",
      "Vagrantfile",
      "Brewfile",
      "Podfile",
      "Fastfile",
      "Dangerfile",
      "Thorfile",
      "Berksfile",
      "Capfile",
      "Justfile",
      "Taskfile.yml",
      "shard.yml",
      "shard.lock",
      "package.json",
      "package-lock.json",
      "yarn.lock",
      "pnpm-lock.yaml",
      "tsconfig.json",
      "pyproject.toml",
      "setup.py",
      "setup.cfg",
      "Pipfile",
      "Pipfile.lock",
      "requirements.txt",
      "Cargo.toml",
      "Cargo.lock",
      "go.mod",
      "go.sum",
      "build.gradle",
      "build.gradle.kts",
      "pom.xml",
      "docker-compose.yml",
      "docker-compose.yaml",
      "compose.yml",
      "compose.yaml",
      ".rubocop.yml",
      ".eslintrc.json",
      ".eslintrc.yml",
      ".eslintrc.js",
      ".prettierrc",
      ".prettierrc.json",
      ".prettierrc.yml",
      ".gitignore",
      ".gitattributes",
      ".dockerignore",
      ".editorconfig",
      ".tool-versions",
      ".mise.toml",
      ".env",
      ".env.example",
      ".env.local",
      ".env.development",
      ".env.test",
      ".env.production",
      "babel.config.js",
      "webpack.config.js",
      "rollup.config.js",
      "vite.config.ts",
      "vite.config.js",
      "jest.config.js",
      "jest.config.ts",
      ".babelrc",
      "tox.ini",
      ".flake8",
      ".pylintrc",
      "mypy.ini",
      ".rspec",
      "codecov.yml",
      "renovate.json",
      ".nvmrc",
      ".ruby-version",
      ".python-version",
      ".node-version",
      ".crystal-version",
      "Earthfile",
    }

    CONFIG_PATHS = [
      "/config/",
      "/.github/",
      "/.circleci/",
      "/.gitlab/",
    ]

    # --- Priority 6: Source code directories ---
    # General conventions plus framework-specific paths

    SOURCE_PATHS = [
      "/src/",
      "/lib/",
      "/app/",
      "/pkg/",
      "/internal/",
      "/cmd/",
      "/components/",
      "/services/",
      "/models/",
      "/controllers/",
      "/views/",
      "/helpers/",
      "/concerns/",
      "/jobs/",
      "/mailers/",
      "/channels/",
      "/serializers/",
      "/presenters/",
      "/decorators/",
      "/middleware/",
      "/handlers/",
      "/routes/",
      "/api/",
      "/engines/",
      "/plugins/",
      "/extensions/",
    ]

    # Root marker files for project root detection.
    # Intentionally small — only files that almost never appear in
    # subdirectories. Do NOT use the full CONFIG_FILENAMES set here;
    # files like package.json, yarn.lock, and .eslintrc.json commonly
    # exist in monorepo subdirectories and would cause false positives.
    ROOT_MARKERS = Set{
      ".git",
      "Makefile",
      "Rakefile",
      "Gemfile",
      "shard.yml",
      "Cargo.toml",
      "go.mod",
      "pyproject.toml",
      "setup.py",
      "pom.xml",
      "build.gradle",
      "build.gradle.kts",
      "Dockerfile",
      "Vagrantfile",
      "Earthfile",
    }

    # Detect file type from an absolute file path.
    # Returns one of FILE_TYPES.
    def detect(file_path : String) : String
      return "other" if file_path.empty?

      # Priority 1: Guideline files
      GUIDELINE_PATHS.each do |pattern|
        return "guideline" if file_path.includes?(pattern)
      end

      # Priority 1: Implementation plan files
      IMPLEMENTATION_PLAN_PATHS.each do |pattern|
        return "implementation_plan" if file_path.includes?(pattern)
      end

      # Priority 2: Test files (by directory convention)
      TEST_PATHS.each do |pattern|
        return "test" if file_path.includes?(pattern)
      end

      # Priority 3: Script files (by directory convention)
      SCRIPT_PATHS.each do |pattern|
        return "script" if file_path.includes?(pattern)
      end

      # Priority 4: Documentation
      DOC_PATHS.each do |pattern|
        return "doc" if file_path.includes?(pattern)
      end
      return "doc" if file_path.ends_with?(".md")

      # Priority 5a: Known config filenames (anywhere)
      basename = File.basename(file_path)
      return "config" if CONFIG_FILENAMES.includes?(basename)

      # Priority 5b: Config directories
      CONFIG_PATHS.each do |pattern|
        return "config" if file_path.includes?(pattern)
      end

      # Priority 5c: Root-level files are config
      if root_level_file?(file_path)
        return "config"
      end

      # Priority 6: Source code directories
      SOURCE_PATHS.each do |pattern|
        return "source" if file_path.includes?(pattern)
      end

      # Default
      "other"
    end

    # Check if a file sits directly in a project root directory.
    # Walks up from the file's parent looking for root markers
    # (.git, Makefile, Gemfile, shard.yml, etc.).
    private def root_level_file?(file_path : String) : Bool
      file_dir = File.dirname(file_path)
      return false if file_dir.empty?

      project_root = find_project_root(file_dir)
      return false unless project_root

      file_dir == project_root
    end

    # Walk up from a directory looking for project root markers.
    # Returns the first directory containing a marker, or nil.
    private def find_project_root(start_dir : String) : String?
      dir = start_dir

      loop do
        # Check for any root marker in this directory
        ROOT_MARKERS.each do |marker|
          marker_path = File.join(dir, marker)
          if File.exists?(marker_path) || Dir.exists?(marker_path)
            return dir
          end
        end

        # Move up one level
        parent = File.dirname(dir)

        # Stop at filesystem root
        break if parent == dir

        dir = parent
      end

      nil
    end
  end
end
