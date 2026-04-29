module GalaxyLedger
  module ArtifactClassifier
    extend self

    # Maps file extension to {artifact_type, mime_type, confidence}
    # Confidence: :high = always an artifact, :medium = needs heuristics
    record ExtInfo,
      artifact_type : String,
      mime_type : String,
      confidence : Symbol

    EXTENSION_MAP = {
      # High confidence — always artifacts
      ".pdf"     => ExtInfo.new("pdf", "application/pdf", :high),
      ".csv"     => ExtInfo.new("csv", "text/csv", :high),
      ".tsv"     => ExtInfo.new("csv", "text/tab-separated-values", :high),
      ".svg"     => ExtInfo.new("image", "image/svg+xml", :high),
      ".mmd"     => ExtInfo.new("mermaid", "text/x-mermaid", :high),
      ".mermaid" => ExtInfo.new("mermaid", "text/x-mermaid", :high),
      ".png"     => ExtInfo.new("image", "image/png", :high),
      ".jpg"     => ExtInfo.new("image", "image/jpeg", :high),
      ".jpeg"    => ExtInfo.new("image", "image/jpeg", :high),
      ".gif"     => ExtInfo.new("image", "image/gif", :high),
      ".webp"    => ExtInfo.new("image", "image/webp", :high),
      ".html"    => ExtInfo.new("html", "text/html", :high),
      ".htm"     => ExtInfo.new("html", "text/html", :high),
      ".xlsx"    => ExtInfo.new("spreadsheet", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", :high),
      ".xls"     => ExtInfo.new("spreadsheet", "application/vnd.ms-excel", :high),
      # Medium confidence — need path/content heuristics
      ".md"       => ExtInfo.new("markdown", "text/markdown", :medium),
      ".markdown" => ExtInfo.new("markdown", "text/markdown", :medium),
      ".json"     => ExtInfo.new("data", "application/json", :medium),
      ".yaml"     => ExtInfo.new("data", "text/yaml", :medium),
      ".yml"      => ExtInfo.new("data", "text/yaml", :medium),
      ".xml"      => ExtInfo.new("data", "application/xml", :medium),
      ".txt"      => ExtInfo.new("text", "text/plain", :medium),
      ".log"      => ExtInfo.new("text", "text/plain", :medium),
    }

    # Source code extensions — never artifacts
    SOURCE_CODE_EXTENSIONS = Set{
      ".rb", ".cr", ".py", ".js", ".ts", ".tsx", ".jsx",
      ".swift", ".go", ".rs", ".java", ".kt", ".c", ".cpp",
      ".h", ".hpp", ".cs", ".sh", ".bash", ".zsh", ".fish",
      ".sql", ".erb", ".haml", ".slim", ".sass", ".scss",
      ".less", ".css", ".toml", ".lock", ".gemspec",
    }

    # Path patterns that indicate an artifact (for medium-confidence)
    ARTIFACT_PATH_PATTERNS = [
      %r{/tmp/}i,
      %r{/Desktop/}i,
      %r{/Documents/}i,
      %r{/Downloads/}i,
      %r{/output/}i,
      %r{/reports?/}i,
      %r{/exports?/}i,
      %r{/generated/}i,
      %r{/artifacts?/}i,
      %r{/data/}i,
      %r{/results?/}i,
    ]

    # Path patterns that indicate NOT an artifact (source code dirs)
    SOURCE_PATH_PATTERNS = [
      %r{/src/},
      %r{/lib/},
      %r{/app/},
      %r{/spec/},
      %r{/test/},
      %r{/config/},
      %r{/db/},
      %r{/vendor/},
      %r{/node_modules/},
      %r{/.git/},
      %r{/agent-guidelines/},
      %r{/implementation-plans/},
    ]

    # Filenames that are never artifacts (even with medium-confidence extensions)
    NON_ARTIFACT_FILENAMES = Set{
      "readme.md", "changelog.md", "license.md", "contributing.md",
      "claude.md", "gemfile", "makefile", "rakefile",
      "package.json", "tsconfig.json", "composer.json",
      ".eslintrc.json", ".prettierrc.json",
      "config.json", "settings.json",
      ".env", ".gitignore", ".dockerignore",
    }

    # Filename patterns that suggest an artifact
    ARTIFACT_FILENAME_PATTERNS = [
      /report/i,
      /analysis/i,
      /summary/i,
      /export/i,
      /diagram/i,
      /chart/i,
      /findings/i,
      /overview/i,
      /metrics/i,
      /dashboard/i,
    ]

    struct Classification
      getter artifact_type : String
      getter mime_type : String

      def initialize(@artifact_type, @mime_type)
      end
    end

    # Classify a file path. Returns nil if the file is NOT an artifact.
    def classify(file_path : String) : Classification?
      ext = File.extname(file_path).downcase
      basename = File.basename(file_path).downcase

      # Never classify source code
      return nil if SOURCE_CODE_EXTENSIONS.includes?(ext)

      # Never classify known non-artifact filenames
      return nil if NON_ARTIFACT_FILENAMES.includes?(basename)

      # Look up extension
      ext_info = EXTENSION_MAP[ext]?
      return nil unless ext_info

      # High confidence — always an artifact
      if ext_info.confidence == :high
        return Classification.new(ext_info.artifact_type, ext_info.mime_type)
      end

      # Medium confidence — apply heuristics
      return nil if source_code_path?(file_path)
      if artifact_path?(file_path) || artifact_filename?(basename)
        return Classification.new(ext_info.artifact_type, ext_info.mime_type)
      end

      nil
    end

    private def source_code_path?(path : String) : Bool
      SOURCE_PATH_PATTERNS.any? { |pattern| pattern.matches?(path) }
    end

    private def artifact_path?(path : String) : Bool
      ARTIFACT_PATH_PATTERNS.any? { |pattern| pattern.matches?(path) }
    end

    private def artifact_filename?(basename : String) : Bool
      name_without_ext = File.basename(basename, File.extname(basename))
      ARTIFACT_FILENAME_PATTERNS.any? { |pattern| pattern.matches?(name_without_ext) }
    end
  end
end
