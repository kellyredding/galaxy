require "json"

module GalaxyLedger
  # Entry types that can be stored in the ledger
  ENTRY_TYPES = [
    "file_read",
    "file_edit",
    "file_write",
    "search",
    "direction",
    "preference",
    "constraint",
    "learning",
    "decision",
    "discovery",
    "guideline",
    "implementation_plan",
    "reference",
  ]

  # Importance levels for entries
  IMPORTANCE_LEVELS = ["high", "medium", "low"]

  # A single ledger entry (input DTO for creating entries)
  # This is used to create entries before inserting into the database.
  # For entries retrieved from the database, see Database::StoredEntry.
  class Entry
    include JSON::Serializable

    # Entry type (file_read, learning, decision, etc.)
    @[JSON::Field(key: "entry_type")]
    property entry_type : String

    # Source: "user" or "assistant" (nil for file operations)
    property source : String?

    # The content of the entry
    property content : String

    # Optional metadata (JSON object)
    property metadata : JSON::Any?

    # Importance level: high, medium, low
    property importance : String

    # Timestamp when entry was created
    @[JSON::Field(key: "created_at")]
    property created_at : String

    # Category/domain for filtering (e.g., "ruby-style", "rspec", "testing")
    # Phase 6.2: Enhanced extraction schema
    property category : String?

    # Searchable keywords for FTS (e.g., ["ruby", "strings", "quotes"])
    # Phase 6.2: Enhanced extraction schema
    # Store as nilable to handle JSON without keywords field; code should handle nil as empty array
    property keywords : Array(String)?

    # When this entry applies (e.g., "Writing Ruby code")
    # Phase 6.2: Enhanced extraction schema
    @[JSON::Field(key: "applies_when")]
    property applies_when : String?

    # Source file basename (e.g., "ruby-style.md")
    # Phase 6.2: Enhanced extraction schema
    @[JSON::Field(key: "source_file")]
    property source_file : String?

    def initialize(
      @entry_type : String,
      @content : String,
      @importance : String = "medium",
      @source : String? = nil,
      @metadata : JSON::Any? = nil,
      @created_at : String = Time.utc.to_rfc3339,
      @category : String? = nil,
      @keywords : Array(String)? = nil,
      @applies_when : String? = nil,
      @source_file : String? = nil,
    )
    end

    # Helper to get keywords as non-nil array
    def keywords_array : Array(String)
      keywords || [] of String
    end

    # Validate entry has required fields and valid values
    def valid? : Bool
      return false if entry_type.empty?
      return false if content.empty?
      return false unless ENTRY_TYPES.includes?(entry_type)
      return false unless IMPORTANCE_LEVELS.includes?(importance)
      return false if source && !["user", "assistant"].includes?(source)
      true
    end
  end
end
