require "json"

module GalaxyAgents
  # Publishes timeline events via the galaxy-timeline CLI.
  #
  # All events are fire-and-forget. Failures are silently
  # rescued so agent operations are never blocked.
  module TimelinePublisher
    def self.agent_started(
      ledger_session_id : Int64,
      agent_id : String,
      agent_type : String,
      description : String? = nil,
    )
      detail_data = JSON.build do |json|
        json.object do
          json.field "agent_id", agent_id
          json.field "agent_type", agent_type
          json.field "description", description
        end
      end

      record_event(
        ledger_session_id,
        "agent:started",
        detail_data,
        duration_identifier: "agent--#{agent_id}",
      )
    end

    def self.agent_stopped(
      ledger_session_id : Int64,
      agent_id : String,
      agent_type : String,
      duration_ms : Int64,
      prompt : String?,
      last_message : String?,
    )
      detail_data = JSON.build do |json|
        json.object do
          json.field "agent_id", agent_id
          json.field "agent_type", agent_type
          json.field "duration_ms", duration_ms
          json.field "prompt",
            truncate(prompt, 500)
          json.field "last_message",
            truncate(last_message, 500)
        end
      end

      record_event(
        ledger_session_id,
        "agent:stopped",
        detail_data,
        duration_identifier: "agent--#{agent_id}",
      )
    end

    def self.agent_failed(
      ledger_session_id : Int64,
      agent_id : String,
      agent_type : String,
      duration_ms : Int64,
      prompt : String?,
      last_message : String?,
    )
      detail_data = JSON.build do |json|
        json.object do
          json.field "agent_id", agent_id
          json.field "agent_type", agent_type
          json.field "duration_ms", duration_ms
          json.field "prompt",
            truncate(prompt, 500)
          json.field "last_message",
            truncate(last_message, 500)
        end
      end

      record_event(
        ledger_session_id,
        "agent:failed",
        detail_data,
        duration_identifier: "agent--#{agent_id}",
      )
    end

    def self.agent_abandoned(
      ledger_session_id : Int64,
      agent_id : String,
      agent_type : String,
    )
      detail_data = JSON.build do |json|
        json.object do
          json.field "agent_id", agent_id
          json.field "agent_type", agent_type
        end
      end

      record_event(
        ledger_session_id,
        "agent:abandoned",
        detail_data,
        duration_identifier: "agent--#{agent_id}",
      )
    end

    private def self.truncate(
      text : String?, max : Int32,
    ) : String?
      return nil unless text
      return text if text.size <= max
      text[0, max - 1] + "\u2026"
    end

    private def self.record_event(
      ledger_session_id : Int64,
      event_type : String,
      detail_data : String,
      duration_identifier : String? = nil,
    )
      args = [
        "record",
        "--ledger-session-id",
        ledger_session_id.to_s,
        "--event-type", event_type,
        "--source", "galaxy-agents",
        "--detail-data-stdin",
      ]
      if di = duration_identifier
        args << "--duration-identifier"
        args << di
      end

      Process.new(
        TIMELINE_BIN_NAME,
        args: args,
        input: IO::Memory.new(detail_data),
        output: Process::Redirect::Close,
        error: Process::Redirect::Close,
      )
    rescue
      # Best-effort
    end
  end
end
