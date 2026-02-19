module GalaxyLedger
  module Hooks
    module Helpers
      extend self

      # Build the systemMessage status line for hook JSON output.
      #
      # Format:  {prefix} | {counts} | {file_count} session files | Last: "snippet"
      # Empty:   {prefix} | {empty_message}
      def build_system_message(
        prefix : String,
        empty_message : String,
        restoration : Database::RestorationResult? = nil,
        files : Array(Database::SessionFile)? = nil,
        last_exchange : Exchange::LastExchange? = nil,
        snapshot_count : Int32 = 0,
        artifact_count : Int32 = 0,
      ) : String
        parts = [] of String

        if restoration
          counts = [] of String
          gl = restoration.tier1.guidelines.size
          ip = restoration.tier1.implementation_plans.size
          hd = restoration.tier1.high_importance_decisions.size
          md = restoration.tier2.medium_decisions.size
          lr = restoration.tier2.learnings.size

          total_decisions = hd + md
          counts << "#{gl} guideline#{gl == 1 ? "" : "s"}" if gl > 0
          counts << "#{ip} plan#{ip == 1 ? "" : "s"}" if ip > 0
          counts << "#{snapshot_count} snapshot#{snapshot_count == 1 ? "" : "s"}" if snapshot_count > 0
          counts << "#{artifact_count} artifact#{artifact_count == 1 ? "" : "s"}" if artifact_count > 0
          counts << "#{total_decisions} decision#{total_decisions == 1 ? "" : "s"}" if total_decisions > 0
          counts << "#{lr} learning#{lr == 1 ? "" : "s"}" if lr > 0

          parts << counts.join(", ") if counts.any?
        end

        if files && files.size > 0
          parts << "#{files.size} session file#{files.size == 1 ? "" : "s"}"
        end

        if last_exchange
          snippet = last_exchange_snippet(last_exchange, 125)
          parts << "Last: \"#{snippet}\"" if snippet && !snippet.empty?
        end

        if parts.empty?
          "#{prefix} \u2502 #{empty_message}"
        else
          "#{prefix} \u2502 #{parts.join(" \u2502 ")}"
        end
      end

      # Replace the home directory prefix with ~ for readability.
      def shorten_home_path(path : String) : String
        home = Path.home.to_s
        if path.starts_with?(home)
          "~#{path[home.size..]}"
        else
          path
        end
      end

      # Truncate text to a maximum length, appending a suffix if truncated.
      def truncate(text : String, max : Int32, suffix : String = "...") : String
        return text if text.size <= max
        cutoff = max - suffix.size
        cutoff = 0 if cutoff < 0
        "#{text[0, cutoff]}#{suffix}"
      end

      # Group an array of StoredEntry by source_file into an ordered hash.
      # Entries without a source_file are grouped under "(unknown)".
      def group_entries_by_source_file(
        entries : Array(Database::StoredEntry),
      ) : Hash(String, Array(Database::StoredEntry))
        grouped = {} of String => Array(Database::StoredEntry)
        entries.each do |entry|
          key = entry.source_file || "(unknown)"
          grouped[key] ||= [] of Database::StoredEntry
          grouped[key] << entry
        end
        grouped
      end

      # Build the final JSON output hash with systemMessage and additionalContext.
      def output_json(system_message : String, additional_context : String) : String
        output = {
          "systemMessage"      => system_message,
          "hookSpecificOutput" => {
            "hookEventName"     => "SessionStart",
            "additionalContext" => additional_context,
          },
        }
        output.to_json
      end

      # Extract a short snippet from the last exchange for the systemMessage.
      # Prefers summary.user_request, falls back to user_message.
      private def last_exchange_snippet(
        exchange : Exchange::LastExchange,
        max_length : Int32,
      ) : String?
        text = if summary = exchange.summary
                 summary.user_request
               else
                 exchange.user_message
               end
        return nil if text.strip.empty?
        truncate(text.gsub('\n', ' ').strip, max_length)
      end
    end
  end
end
