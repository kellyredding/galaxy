require "json"

module GalaxyDiff
  # Classification for a single diff line. Serializes as
  # lowercase strings ("context", "add", "delete") to
  # match the on-wire `.gdiff` format consumed by
  # Galaxy.app.
  enum GdiffLineType
    Context
    Add
    Delete

    def to_json(json : JSON::Builder)
      json.string(to_s.downcase)
    end

    # Parse from JSON — `Enum.parse` is case-insensitive
    # so "context" → Context, "add" → Add, etc.
    def self.new(pull : JSON::PullParser)
      GdiffLineType.parse(pull.read_string)
    end
  end

  struct GdiffLine
    include JSON::Serializable

    getter type : GdiffLineType
    getter old_no : Int32?
    getter new_no : Int32?
    getter content : String

    def initialize(
      @type, @old_no, @new_no, @content,
    )
    end
  end

  class GdiffHunk
    include JSON::Serializable

    getter old_start : Int32
    getter old_count : Int32
    getter new_start : Int32
    getter new_count : Int32
    property lines : Array(GdiffLine) = [] of GdiffLine

    def initialize(
      @old_start, @old_count,
      @new_start, @new_count,
    )
    end
  end

  struct GdiffFile
    include JSON::Serializable

    getter path : String
    getter old_path : String?
    getter status : String
    getter language : String?
    getter before : String?
    getter after : String?
    getter hunks : Array(GdiffHunk)

    def initialize(
      @path, @old_path, @status, @language,
      @before, @after, @hunks,
    )
    end
  end

  # `ref_from` and `ref_to` are full 40-char commit
  # SHAs when resolvable — commit snapshots are durable,
  # branch names aren't. Non-SHA fallbacks: the original
  # input string (e.g., "main" for an unresolvable ref)
  # or "working-tree" when diffing against an uncommitted
  # tree. The reader treats "both refs SHA-shape AND
  # repo non-empty" as the signal for showing a
  # remote-link affordance, so no separate flag is
  # needed to mark a capture as linkable.
  #
  # `repo` stores `owner/repo` when origin is a GitHub
  # remote, otherwise an empty string.
  struct GdiffMetadata
    include JSON::Serializable

    getter ref_from : String
    getter ref_to : String
    getter repo : String
    getter created_at : String
    getter summary : String

    def initialize(
      @ref_from, @ref_to,
      @repo, @created_at, @summary,
    )
    end
  end

  struct GdiffDocument
    include JSON::Serializable

    getter version : Int32
    getter metadata : GdiffMetadata
    getter files : Array(GdiffFile)

    def initialize(@version, @metadata, @files)
    end
  end
end
