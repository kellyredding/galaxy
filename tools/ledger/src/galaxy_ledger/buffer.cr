require "json"

module GalaxyLedger
  # Buffer module for ledger entries
  # Note: Direct database writes replaced the buffering system in Phase 6.1.
  # This module now only provides the Entry class and constants for validation.
  module Buffer
    # Entry types that can be stored
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

    # Importance levels
    IMPORTANCE_LEVELS = ["high", "medium", "low"]

    # A single ledger entry
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

      def initialize(
        @entry_type : String,
        @content : String,
        @importance : String = "medium",
        @source : String? = nil,
        @metadata : JSON::Any? = nil,
        @created_at : String = Time.utc.to_rfc3339,
      )
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
end
