require "json"

module GalaxyArtifacts
  # Publishes timeline events via the galaxy-timeline CLI.
  #
  # All events are fire-and-forget — Process.new spawns an
  # async child process. Failures are silently rescued so
  # artifact operations are never blocked by timeline issues.
  module TimelinePublisher
    # Record an artifact:created event.
    def self.artifact_created(
      ledger_session_id : Int64,
      number : Int32,
      title : String,
      artifact_type : String,
      source_path : String?,
      file_size : Int64,
      content_hash : String,
      trigger : String = "manual",
    )
      detail_data = JSON.build do |json|
        json.object do
          json.field "number", number
          json.field "title", title
          json.field "artifact_type", artifact_type
          json.field "source_path", source_path
          json.field "file_size", file_size
          json.field "content_hash", content_hash
          json.field "trigger", trigger
        end
      end

      record_event(
        ledger_session_id,
        "artifact:created",
        detail_data,
      )
    end

    # Record an artifact:updated event.
    def self.artifact_updated(
      ledger_session_id : Int64,
      number : Int32,
      title : String,
      artifact_type : String,
      source_path : String?,
      file_size : Int64,
      content_hash : String,
      previous_file_size : Int64,
      previous_content_hash : String,
    )
      detail_data = JSON.build do |json|
        json.object do
          json.field "number", number
          json.field "title", title
          json.field "artifact_type", artifact_type
          json.field "source_path", source_path
          json.field "file_size", file_size
          json.field "content_hash", content_hash
          json.field "previous_file_size",
            previous_file_size
          json.field "previous_content_hash",
            previous_content_hash
        end
      end

      record_event(
        ledger_session_id,
        "artifact:updated",
        detail_data,
      )
    end

    # Record an artifact:deleted event.
    def self.artifact_deleted(
      ledger_session_id : Int64,
      number : Int32,
      title : String,
      artifact_type : String,
    )
      detail_data = JSON.build do |json|
        json.object do
          json.field "number", number
          json.field "title", title
          json.field "artifact_type", artifact_type
        end
      end

      record_event(
        ledger_session_id,
        "artifact:deleted",
        detail_data,
      )
    end

    # Record an artifact.annotation:created event.
    def self.annotation_created(
      ledger_session_id : Int64,
      artifact_id : Int64,
      artifact_number : Int32,
      artifact_title : String,
      annotation_number : Int32,
      content : String,
    )
      detail_data = JSON.build do |json|
        json.object do
          json.field "artifact_id", artifact_id
          json.field "artifact_number",
            artifact_number
          json.field "artifact_title",
            artifact_title
          json.field "annotation_number",
            annotation_number
          json.field "content",
            truncate(content, 200)
        end
      end

      record_event(
        ledger_session_id,
        "artifact.annotation:created",
        detail_data,
      )
    end

    # Record an artifact.annotation:updated event.
    def self.annotation_updated(
      ledger_session_id : Int64,
      artifact_id : Int64,
      artifact_number : Int32,
      artifact_title : String,
      annotation_number : Int32,
      content : String,
    )
      detail_data = JSON.build do |json|
        json.object do
          json.field "artifact_id", artifact_id
          json.field "artifact_number",
            artifact_number
          json.field "artifact_title",
            artifact_title
          json.field "annotation_number",
            annotation_number
          json.field "content",
            truncate(content, 200)
        end
      end

      record_event(
        ledger_session_id,
        "artifact.annotation:updated",
        detail_data,
      )
    end

    # Record an artifact.annotation:deleted event.
    def self.annotation_deleted(
      ledger_session_id : Int64,
      artifact_id : Int64,
      artifact_number : Int32,
      artifact_title : String,
      annotation_number : Int32,
      content : String? = nil,
    )
      detail_data = JSON.build do |json|
        json.object do
          json.field "artifact_id", artifact_id
          json.field "artifact_number",
            artifact_number
          json.field "artifact_title",
            artifact_title
          json.field "annotation_number",
            annotation_number
          if c = content
            json.field "content",
              truncate(c, 200)
          end
        end
      end

      record_event(
        ledger_session_id,
        "artifact.annotation:deleted",
        detail_data,
      )
    end

    # Record an artifact.review:created event.
    def self.review_created(
      ledger_session_id : Int64,
      artifact_id : Int64,
      artifact_number : Int32,
      artifact_title : String,
      review_number : Int32,
      annotation_count : Int32,
    )
      detail_data = JSON.build do |json|
        json.object do
          json.field "artifact_id", artifact_id
          json.field "artifact_number",
            artifact_number
          json.field "artifact_title",
            artifact_title
          json.field "review_number", review_number
          json.field "annotation_count",
            annotation_count
        end
      end

      record_event(
        ledger_session_id,
        "artifact.review:created",
        detail_data,
      )
    end

    private def self.truncate(
      text : String, max : Int32,
    ) : String
      return text if text.size <= max
      text[0, max - 1] + "\u2026"
    end

    # Fire-and-forget: spawn galaxy-timeline record process.
    private def self.record_event(
      ledger_session_id : Int64,
      event_type : String,
      detail_data : String,
    )
      Process.new(
        TIMELINE_BIN.to_s,
        args: [
          "record",
          "--ledger-session-id",
          ledger_session_id.to_s,
          "--event-type", event_type,
          "--source", "galaxy-artifacts",
          "--detail-data-stdin",
        ],
        input: IO::Memory.new(detail_data),
        output: Process::Redirect::Close,
        error: Process::Redirect::Close,
      )
    rescue
      # Best-effort — timeline unavailable is not fatal
    end
  end
end
