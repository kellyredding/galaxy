require "json"
require "file_utils"

module GalaxyLedger
  # Buffer system for ledger entries
  # Provides concurrent-safe buffering with atomic flush operations
  #
  # Buffer files are stored per-session in:
  #   ~/.claude/galaxy/sessions/{session_id}/
  #     - ledger_buffer.jsonl          # Buffered entries
  #     - ledger_buffer.flushing.jsonl # Entries being flushed
  #     - ledger_buffer.lock           # File lock for concurrency
  module Buffer
    # Entry types that can be buffered
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

    # A single buffer entry
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

    # Get the buffer file path for a session
    def self.buffer_path(session_id : String) : Path
      GalaxyLedger.session_dir(session_id) / LEDGER_BUFFER_FILENAME
    end

    # Get the flushing file path for a session
    def self.flushing_path(session_id : String) : Path
      GalaxyLedger.session_dir(session_id) / LEDGER_BUFFER_FLUSHING_FILENAME
    end

    # Get the lock file path for a session
    def self.lock_path(session_id : String) : Path
      GalaxyLedger.session_dir(session_id) / LEDGER_BUFFER_LOCK_FILENAME
    end

    # Append an entry to the buffer (lock-protected)
    # Creates session directory if needed
    # Returns true on success, false on failure
    def self.append(session_id : String, entry : Entry) : Bool
      return false if session_id.empty?
      return false unless entry.valid?

      begin
        session_dir = GalaxyLedger.session_dir(session_id)
        Dir.mkdir_p(session_dir) unless Dir.exists?(session_dir)

        with_lock(session_id) do
          buffer_file = buffer_path(session_id)
          File.open(buffer_file, "a") do |file|
            file.puts(entry.to_json)
          end
        end
        true
      rescue
        false
      end
    end

    # Append multiple entries to the buffer (lock-protected, single lock acquisition)
    # Returns number of entries successfully written
    def self.append_many(session_id : String, entries : Array(Entry)) : Int32
      return 0 if session_id.empty?
      return 0 if entries.empty?

      valid_entries = entries.select(&.valid?)
      return 0 if valid_entries.empty?

      begin
        session_dir = GalaxyLedger.session_dir(session_id)
        Dir.mkdir_p(session_dir) unless Dir.exists?(session_dir)

        with_lock(session_id) do
          buffer_file = buffer_path(session_id)
          File.open(buffer_file, "a") do |file|
            valid_entries.each do |entry|
              file.puts(entry.to_json)
            end
          end
        end
        valid_entries.size
      rescue
        0
      end
    end

    # Read all entries from the buffer
    # Returns empty array if buffer doesn't exist or on error
    def self.read(session_id : String) : Array(Entry)
      return [] of Entry if session_id.empty?

      buffer_file = buffer_path(session_id)
      return [] of Entry unless File.exists?(buffer_file)

      entries = [] of Entry
      begin
        File.each_line(buffer_file) do |line|
          next if line.strip.empty?
          begin
            entry = Entry.from_json(line)
            entries << entry
          rescue
            # Skip malformed lines
          end
        end
      rescue
        # Return empty on read error
      end
      entries
    end

    # Get the count of entries in the buffer without loading all of them
    def self.count(session_id : String) : Int32
      return 0 if session_id.empty?

      buffer_file = buffer_path(session_id)
      return 0 unless File.exists?(buffer_file)

      count = 0
      begin
        File.each_line(buffer_file) do |line|
          count += 1 unless line.strip.empty?
        end
      rescue
        0
      end
      count
    end

    # Check if buffer exists and has entries
    def self.exists?(session_id : String) : Bool
      return false if session_id.empty?
      File.exists?(buffer_path(session_id))
    end

    # Check if a flush is currently in progress
    def self.flush_in_progress?(session_id : String) : Bool
      return false if session_id.empty?
      File.exists?(flushing_path(session_id))
    end

    # Clear the buffer without flushing (delete file)
    # Returns true on success
    def self.clear(session_id : String) : Bool
      return false if session_id.empty?

      begin
        with_lock(session_id) do
          buffer_file = buffer_path(session_id)
          File.delete(buffer_file) if File.exists?(buffer_file)
        end
        true
      rescue
        false
      end
    end

    # Synchronous flush - blocks until complete
    # Returns a FlushResult with details of the operation
    def self.flush_sync(session_id : String) : FlushResult
      perform_flush(session_id)
    end

    # Asynchronous flush - spawns a detached subprocess
    # Returns immediately with FlushResult indicating spawn status
    # The subprocess performs the actual flush independently
    def self.flush_async(session_id : String) : FlushResult
      return FlushResult.new(
        success: false,
        entries_flushed: 0,
        reason: "empty session_id"
      ) if session_id.empty?

      begin
        # Find the binary path - use PROGRAM_NAME or fall back to PATH lookup
        binary = Process.executable_path || "galaxy-ledger"

        # Spawn a detached subprocess to perform the flush
        # The subprocess runs independently and survives parent exit
        process = Process.new(
          binary,
          args: ["buffer", "flush", session_id],
          input: Process::Redirect::Close,
          output: Process::Redirect::Close,
          error: Process::Redirect::Close,
        )

        FlushResult.new(
          success: true,
          entries_flushed: 0,
          reason: "async flush started (pid: #{process.pid})"
        )
      rescue ex
        FlushResult.new(
          success: false,
          entries_flushed: 0,
          reason: "spawn failed: #{ex.message}"
        )
      end
    end

    # Process an orphaned flushing file (from crashed flush)
    # Called during startup to recover orphaned entries
    # Returns number of entries processed
    def self.process_orphaned_flushing_file(session_id : String) : Int32
      return 0 if session_id.empty?

      flushing_file = flushing_path(session_id)
      return 0 unless File.exists?(flushing_file)

      entries_count = 0
      begin
        # Read and count entries from the flushing file
        File.each_line(flushing_file) do |line|
          next if line.strip.empty?
          entries_count += 1
          # Phase 3: Just count entries
          # Phase 4: Will persist to SQLite here
        end

        # Log the recovery (to stderr so it doesn't interfere with JSON output)
        STDERR.puts "[galaxy-ledger] Recovered #{entries_count} orphaned entries from #{session_id}"

        # Delete the flushing file after processing
        File.delete(flushing_file)
      rescue
        # Best effort - ignore errors
      end

      entries_count
    end

    # Result of a flush operation
    struct FlushResult
      getter success : Bool
      getter entries_flushed : Int32
      getter reason : String?

      def initialize(@success, @entries_flushed, @reason = nil)
      end
    end

    # Internal: Perform the actual flush operation
    # This is the core flush logic used by both sync and async flush
    private def self.perform_flush(session_id : String) : FlushResult
      return FlushResult.new(
        success: false,
        entries_flushed: 0,
        reason: "empty session_id"
      ) if session_id.empty?

      session_dir = GalaxyLedger.session_dir(session_id)
      return FlushResult.new(
        success: false,
        entries_flushed: 0,
        reason: "session directory does not exist"
      ) unless Dir.exists?(session_dir)

      buffer_file = buffer_path(session_id)
      flushing_file = flushing_path(session_id)

      # Acquire lock for the atomic rename
      entries_count = 0
      begin
        with_lock(session_id) do
          # Check if another flush is already in progress
          if File.exists?(flushing_file)
            return FlushResult.new(
              success: false,
              entries_flushed: 0,
              reason: "another flush in progress"
            )
          end

          # Check if there's anything to flush
          unless File.exists?(buffer_file)
            return FlushResult.new(
              success: true,
              entries_flushed: 0,
              reason: "nothing to flush"
            )
          end

          # Atomic rename: buffer -> flushing
          File.rename(buffer_file, flushing_file)
        end
        # Lock released here - new writes can now go to fresh buffer file

        # Process the flushing file (without lock)
        File.each_line(flushing_file) do |line|
          next if line.strip.empty?
          entries_count += 1
          # Phase 3: Just count entries and log
          # Phase 4: Will persist to SQLite here
        end

        # Log the flush (to stderr so it doesn't interfere with JSON output)
        if entries_count > 0
          STDERR.puts "[galaxy-ledger] Flushed #{entries_count} entries for session #{session_id}"
        end

        # Delete the flushing file after successful processing
        File.delete(flushing_file)

        FlushResult.new(
          success: true,
          entries_flushed: entries_count,
          reason: nil
        )
      rescue ex
        FlushResult.new(
          success: false,
          entries_flushed: entries_count,
          reason: "flush error: #{ex.message}"
        )
      end
    end

    # Internal: Execute a block while holding the buffer lock
    # Uses flock for cross-process synchronization
    private def self.with_lock(session_id : String, &)
      session_dir = GalaxyLedger.session_dir(session_id)
      Dir.mkdir_p(session_dir) unless Dir.exists?(session_dir)

      lock_file = lock_path(session_id)

      # Open or create the lock file
      File.open(lock_file, "w") do |file|
        # Acquire exclusive lock (blocks until available)
        file.flock_exclusive do
          yield
        end
      end
    end
  end
end
