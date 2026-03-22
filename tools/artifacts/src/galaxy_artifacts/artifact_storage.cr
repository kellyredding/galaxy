require "digest/sha256"
require "file_utils"

module GalaxyArtifacts
  module ArtifactStorage
    extend self

    # Base directory for artifact storage
    ARTIFACTS_DIR = GalaxyArtifacts::DATA_DIR / "artifacts"

    # Default max file size (50 MB)
    DEFAULT_MAX_FILE_SIZE = 52_428_800_i64

    # Store an artifact file. Copies source to artifact storage directory.
    # Returns the stored path on success, nil on failure.
    def store(
      ledger_session_id : Int64,
      number : Int32,
      source_path : String,
      original_filename : String,
    ) : String?
      return nil unless File.exists?(source_path)

      session_dir = ARTIFACTS_DIR / ledger_session_id.to_s
      Dir.mkdir_p(session_dir) unless Dir.exists?(session_dir)

      # Build stored filename: 001_original-name.ext
      padded = number.to_s.rjust(3, '0')
      slug = slugify(original_filename)
      stored_filename = "#{padded}_#{slug}"
      stored_path = (session_dir / stored_filename).to_s

      FileUtils.cp(source_path, stored_path)
      stored_path
    rescue
      nil
    end

    # Store artifact content from a string (for text artifacts
    # captured via PostToolUse where we have the content in memory).
    # Returns the stored path on success, nil on failure.
    def store_content(
      ledger_session_id : Int64,
      number : Int32,
      content : String,
      original_filename : String,
    ) : String?
      session_dir = ARTIFACTS_DIR / ledger_session_id.to_s
      Dir.mkdir_p(session_dir) unless Dir.exists?(session_dir)

      padded = number.to_s.rjust(3, '0')
      slug = slugify(original_filename)
      stored_filename = "#{padded}_#{slug}"
      stored_path = (session_dir / stored_filename).to_s

      File.write(stored_path, content)
      stored_path
    rescue
      nil
    end

    # Compute SHA256 hash of file content for deduplication.
    def file_hash(path : String) : String
      Digest::SHA256.hexdigest(File.read(path))
    rescue
      ""
    end

    # Compute SHA256 hash of string content.
    def content_hash(content : String) : String
      Digest::SHA256.hexdigest(content)
    end

    # Get file size in bytes.
    def file_size(path : String) : Int64
      File.size(path).to_i64
    rescue
      0_i64
    end

    # Generate a title from a filename when no explicit title is given.
    # "quarterly-report.csv" => "quarterly report"
    # "001_data-export.json" => "data export"
    def title_from_filename(filename : String) : String
      name = File.basename(filename, File.extname(filename))
      # Strip leading number prefix (e.g., "001_")
      name = name.sub(/^\d+_/, "")
      # Convert hyphens/underscores to spaces, titleize
      name.gsub(/[-_]/, " ").strip
    end

    # Clean a filename into a safe slug.
    def slugify(filename : String) : String
      # Keep the extension, clean the base
      ext = File.extname(filename)
      base = File.basename(filename, ext)
      # Replace spaces and unsafe chars with hyphens
      safe_base = base.downcase
        .gsub(/[^a-z0-9\-_]/, "-")
        .gsub(/-+/, "-")
        .strip("-")
      "#{safe_base}#{ext.downcase}"
    end
  end
end
