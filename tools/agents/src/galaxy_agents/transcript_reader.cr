require "json"

module GalaxyAgents
  module TranscriptReader
    # Extract the initial prompt from an agent
    # transcript. Returns nil if the file doesn't
    # exist or can't be parsed.
    def self.extract_prompt(
      transcript_path : String,
    ) : String?
      return nil unless File.exists?(transcript_path)

      File.each_line(transcript_path) do |line|
        next if line.strip.empty?
        begin
          entry = JSON.parse(line)
          # Transcript entries use "type" at top level
          entry_type = entry["type"]?.try(&.as_s?)
          next unless entry_type == "user"

          # Content is nested: entry.message.content
          message = entry["message"]?
          next unless message

          content = message["content"]?
          next unless content

          # Content may be string or array of blocks
          if text = content.as_s?
            return text
          elsif blocks = content.as_a?
            blocks.each do |block|
              if block["type"]?.try(&.as_s?) == "text"
                if text = block["text"]?
                     .try(&.as_s?)
                  return text
                end
              end
            end
          end
        rescue
          next
        end
      end
      nil
    rescue
      nil
    end
  end
end
