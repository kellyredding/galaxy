require "json"

module GalaxyLedger
  module Hooks
    # Scans a Claude Code transcript JSONL file for
    # queue-operation entries that represent follow-up
    # messages sent by the user mid-turn.
    #
    # These messages are either:
    # - Queued during tool execution (fire UserPromptSubmit
    #   in batch, but also appear as queue-operation)
    # - Typed during response generation (no hook fires,
    #   only queue-operation records them)
    #
    # Filters out <task-notification> injections from
    # background agent completions.
    module TranscriptScanner
      struct FollowUpMessage
        getter content : String
        getter timestamp : String

        def initialize(
          @content : String,
          @timestamp : String,
        )
        end

        def to_json(json : JSON::Builder)
          json.object do
            json.field "content", @content
            json.field "timestamp", @timestamp
          end
        end
      end

      # Extract follow-up messages from the transcript JSONL.
      #
      # Looks for queue-operation entries with operation:
      # "enqueue" that occurred after `after_timestamp` and
      # belong to the given `claude_session_id`.
      #
      # Filters out entries where content starts with
      # <task-notification> (background agent completions).
      #
      # Returns an empty array if the file is missing,
      # empty, or unreadable.
      def self.follow_up_messages(
        transcript_path : String,
        after_timestamp : String,
        claude_session_id : String,
      ) : Array(FollowUpMessage)
        return [] of FollowUpMessage unless File.exists?(
                                              transcript_path,
                                            )

        after_time = Time.parse_rfc3339(after_timestamp)
        messages = [] of FollowUpMessage

        File.each_line(transcript_path) do |line|
          next if line.empty?

          begin
            json = JSON.parse(line)
          rescue
            next # Skip malformed JSONL lines
          end

          # Only queue-operation enqueue entries
          next unless json["type"]?.try(&.as_s?) ==
                        "queue-operation"
          next unless json["operation"]?.try(&.as_s?) ==
                        "enqueue"

          # Session ID must match
          next unless json["sessionId"]?.try(&.as_s?) ==
                        claude_session_id

          # Timestamp must be after the turn initiated_at
          ts_str = json["timestamp"]?.try(&.as_s?)
          next unless ts_str

          begin
            ts = Time.parse_rfc3339(ts_str)
          rescue
            next
          end
          next unless ts > after_time

          # Extract content, skip task-notifications
          content = json["content"]?.try(&.as_s?)
          next unless content
          next if content.starts_with?(
                    "<task-notification>",
                  )

          messages << FollowUpMessage.new(
            content: content,
            timestamp: ts_str,
          )
        end

        messages
      rescue
        [] of FollowUpMessage
      end
    end
  end
end
