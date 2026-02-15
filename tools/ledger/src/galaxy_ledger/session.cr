require "file_utils"

module GalaxyLedger
  # Session management for Galaxy Ledger
  # Handles listing, showing, and removing sessions
  module Session
    # List all sessions with basic stats
    def self.list : Array(SessionInfo)
      sessions = [] of SessionInfo

      return sessions unless Dir.exists?(SESSIONS_DIR)

      Dir.each_child(SESSIONS_DIR) do |session_identifier|
        session_path = SESSIONS_DIR / session_identifier
        next unless Dir.exists?(session_path)

        info = get_session_info(session_identifier)
        sessions << info if info
      end

      # Sort by last modified (most recent first)
      sessions.sort_by! { |s| -s.last_modified.to_unix }
      sessions
    end

    # Get detailed info for a specific session
    def self.show(session_identifier : String) : SessionInfo?
      session_path = SESSIONS_DIR / session_identifier
      return nil unless Dir.exists?(session_path)

      get_session_info(session_identifier)
    end

    # Remove a session completely (folder + database entries)
    def self.remove(session_identifier : String) : RemoveResult
      session_path = SESSIONS_DIR / session_identifier
      folder_existed = Dir.exists?(session_path)

      # Remove session folder if it exists
      if folder_existed
        FileUtils.rm_rf(session_path.to_s)
      end

      # Purge from SQLite (FK cascades handle session_files cleanup)
      sqlite_purged = false
      deleted_count = Database.delete_session(session_identifier)
      sqlite_purged = deleted_count > 0 || folder_existed # Mark as purged if we deleted entries or had folder

      # Purge from PostgreSQL if enabled (future)
      postgres_purged = false
      config = Config.load
      if config.storage.postgres_enabled
        # TODO: DELETE FROM ledger.entries WHERE session_identifier = ?
      end

      RemoveResult.new(
        session_identifier: session_identifier,
        folder_removed: folder_existed,
        sqlite_purged: sqlite_purged,
        postgres_purged: postgres_purged
      )
    end

    # Check if a session exists
    def self.exists?(session_identifier : String) : Bool
      Dir.exists?(SESSIONS_DIR / session_identifier)
    end

    private def self.get_session_info(session_identifier : String) : SessionInfo?
      session_path = SESSIONS_DIR / session_identifier
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

      # Read context percentage from DB (written by statusline → update-session-metrics)
      context_percentage : Float64? = nil
      session_record = Database.get_session(session_identifier)
      if session_record
        pct = session_record.context_percentage
        context_percentage = pct if pct > 0.0
      end

      SessionInfo.new(
        session_identifier: session_identifier,
        path: session_path,
        files: files,
        total_size: total_size,
        last_modified: last_modified,
        context_percentage: context_percentage
      )
    end

    # Session information struct
    struct SessionInfo
      getter session_identifier : String
      getter path : Path
      getter files : Array(String)
      getter total_size : Int64
      getter last_modified : Time
      getter context_percentage : Float64?

      def initialize(
        @session_identifier,
        @path,
        @files,
        @total_size,
        @last_modified,
        @context_percentage,
      )
      end

      def to_s(io : IO)
        io << session_identifier
      end
    end

    # Result of remove operation
    struct RemoveResult
      getter session_identifier : String
      getter folder_removed : Bool
      getter sqlite_purged : Bool
      getter postgres_purged : Bool

      def initialize(@session_identifier, @folder_removed, @sqlite_purged, @postgres_purged)
      end
    end
  end
end
