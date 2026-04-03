require "json"

module GalaxySnapshots
  # Publishes timeline events via the galaxy-timeline CLI.
  #
  # All events are fire-and-forget. Failures are silently
  # rescued so snapshot operations are never blocked.
  module TimelinePublisher
    def self.snapshot_created(
      ledger_session_id : Int64,
      snapshot_number : Int32,
      title : String,
      exchange_count : Int32?,
      char_count : Int32,
    )
      detail_data = JSON.build do |json|
        json.object do
          json.field "snapshot_number", snapshot_number
          json.field "title", title
          json.field "exchange_count", exchange_count
          json.field "char_count", char_count
        end
      end

      record_event(
        ledger_session_id,
        "snapshot:created",
        detail_data,
        source: "galaxy-snapshots/cli/create",
      )
    end

    def self.annotation_created(
      ledger_session_id : Int64,
      snapshot_id : Int64,
      snapshot_number : Int32,
      snapshot_title : String,
      annotation_number : Int32,
      start_line : Int32,
      end_line : Int32,
      content : String,
    )
      detail_data = JSON.build do |json|
        json.object do
          json.field "snapshot_id", snapshot_id
          json.field "snapshot_number",
            snapshot_number
          json.field "snapshot_title",
            snapshot_title
          json.field "annotation_number",
            annotation_number
          json.field "start_line", start_line
          json.field "end_line", end_line
          json.field "content",
            truncate(content, 200)
        end
      end

      record_event(
        ledger_session_id,
        "snapshot.annotation:created",
        detail_data,
      )
    end

    def self.annotation_updated(
      ledger_session_id : Int64,
      snapshot_id : Int64,
      snapshot_number : Int32,
      snapshot_title : String,
      annotation_number : Int32,
      content : String,
    )
      detail_data = JSON.build do |json|
        json.object do
          json.field "snapshot_id", snapshot_id
          json.field "snapshot_number",
            snapshot_number
          json.field "snapshot_title",
            snapshot_title
          json.field "annotation_number",
            annotation_number
          json.field "content",
            truncate(content, 200)
        end
      end

      record_event(
        ledger_session_id,
        "snapshot.annotation:updated",
        detail_data,
      )
    end

    def self.annotation_deleted(
      ledger_session_id : Int64,
      snapshot_id : Int64,
      snapshot_number : Int32,
      snapshot_title : String,
      annotation_number : Int32,
      content : String? = nil,
    )
      detail_data = JSON.build do |json|
        json.object do
          json.field "snapshot_id", snapshot_id
          json.field "snapshot_number",
            snapshot_number
          json.field "snapshot_title",
            snapshot_title
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
        "snapshot.annotation:deleted",
        detail_data,
      )
    end

    def self.review_created(
      ledger_session_id : Int64,
      snapshot_id : Int64,
      snapshot_number : Int32,
      snapshot_title : String,
      review_number : Int32,
      annotation_count : Int32,
    )
      detail_data = JSON.build do |json|
        json.object do
          json.field "snapshot_id", snapshot_id
          json.field "snapshot_number",
            snapshot_number
          json.field "snapshot_title",
            snapshot_title
          json.field "review_number", review_number
          json.field "annotation_count",
            annotation_count
        end
      end

      record_event(
        ledger_session_id,
        "snapshot.review:created",
        detail_data,
      )
    end

    private def self.truncate(
      text : String, max : Int32,
    ) : String
      return text if text.size <= max
      text[0, max - 1] + "\u2026"
    end

    private def self.record_event(
      ledger_session_id : Int64,
      event_type : String,
      detail_data : String,
      source : String = "galaxy-snapshots",
    )
      args = [
        "record",
        "--ledger-session-id",
        ledger_session_id.to_s,
        "--event-type", event_type,
        "--source", source,
        "--detail-data-stdin",
      ]

      Process.new(
        TIMELINE_BIN,
        args: args,
        input: IO::Memory.new(detail_data),
        output: Process::Redirect::Close,
        error: Process::Redirect::Close,
      )
    rescue
      # Best-effort — timeline unavailable is not fatal
    end
  end
end
