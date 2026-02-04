require "file_utils"

module GalaxyLedger
  # Session management for Galaxy Ledger
  # Handles listing, showing, and removing sessions
  module Session
    # List all sessions with basic stats
    def self.list : Array(SessionInfo)
      sessions = [] of SessionInfo

      return sessions unless Dir.exists?(SESSIONS_DIR)

      Dir.each_child(SESSIONS_DIR) do |session_id|
        session_path = SESSIONS_DIR / session_id
        next unless Dir.exists?(session_path)

        info = get_session_info(session_id)
        sessions << info if info
      end

      # Sort by last modified (most recent first)
      sessions.sort_by! { |s| -s.last_modified.to_unix }
      sessions
    end

    # Get detailed info for a specific session
    def self.show(session_id : String) : SessionInfo?
      session_path = SESSIONS_DIR / session_id
      return nil unless Dir.exists?(session_path)

      get_session_info(session_id)
    end

    # Remove a session completely (folder + database entries)
    def self.remove(session_id : String) : RemoveResult
      session_path = SESSIONS_DIR / session_id
      folder_existed = Dir.exists?(session_path)

      # Remove session folder if it exists
      if folder_existed
        FileUtils.rm_rf(session_path.to_s)
      end

      # Purge from SQLite
      sqlite_purged = false
      deleted_count = Database.delete_session(session_id)
      sqlite_purged = deleted_count > 0 || folder_existed # Mark as purged if we deleted entries or had folder

      # Purge from PostgreSQL if enabled (future: implement in Phase 8)
      postgres_purged = false
      config = Config.load
      if config.storage.postgres_enabled
        # TODO: DELETE FROM ledger.entries WHERE session_id = ?
      end

      RemoveResult.new(
        session_id: session_id,
        folder_removed: folder_existed,
        sqlite_purged: sqlite_purged,
        postgres_purged: postgres_purged
      )
    end

    # Check if a session exists
    def self.exists?(session_id : String) : Bool
      Dir.exists?(SESSIONS_DIR / session_id)
    end

    private def self.get_session_info(session_id : String) : SessionInfo?
      session_path = SESSIONS_DIR / session_id
      return nil unless Dir.exists?(session_path)

      # Get folder stats
      files = [] of String
      total_size : Int64 = 0

      Dir.each_child(session_path) do |file|
        file_path = session_path / file
        if File.file?(file_path)
          files << file
          total_size += File.size(file_path)
        end
      end

      # Get last modified time from directory
      last_modified = File.info(session_path).modification_time

      # Check for specific ledger files
      has_context_status = File.exists?(session_path / CONTEXT_STATUS_FILENAME)
      has_last_exchange = File.exists?(session_path / LEDGER_LAST_EXCHANGE_FILENAME)

      # Read context percentage if available
      context_percentage : Float64? = nil
      if has_context_status
        begin
          json = File.read(session_path / CONTEXT_STATUS_FILENAME)
          parsed = JSON.parse(json)
          context_percentage = parsed["percentage"]?.try(&.as_f?)
        rescue
          # Ignore parse errors
        end
      end

      SessionInfo.new(
        session_id: session_id,
        path: session_path,
        files: files,
        total_size: total_size,
        last_modified: last_modified,
        has_context_status: has_context_status,
        has_last_exchange: has_last_exchange,
        context_percentage: context_percentage
      )
    end

    # Session information struct
    struct SessionInfo
      getter session_id : String
      getter path : Path
      getter files : Array(String)
      getter total_size : Int64
      getter last_modified : Time
      getter has_context_status : Bool
      getter has_last_exchange : Bool
      getter context_percentage : Float64?

      def initialize(
        @session_id,
        @path,
        @files,
        @total_size,
        @last_modified,
        @has_context_status,
        @has_last_exchange,
        @context_percentage,
      )
      end

      def to_s(io : IO)
        io << session_id
      end
    end

    # Result of remove operation
    struct RemoveResult
      getter session_id : String
      getter folder_removed : Bool
      getter sqlite_purged : Bool
      getter postgres_purged : Bool

      def initialize(@session_id, @folder_removed, @sqlite_purged, @postgres_purged)
      end

      def anything_removed? : Bool
        folder_removed || sqlite_purged || postgres_purged
      end
    end
  end
end
