require "json"

module GalaxyAgents
  module MetaReader
    # Read description from .meta.json file.
    # Returns nil if file doesn't exist or can't
    # be parsed.
    def self.read_description(
      parent_transcript_path : String,
      agent_id : String,
    ) : String?
      path = derive_meta_path(
        parent_transcript_path, agent_id,
      )
      return nil unless path
      return nil unless File.exists?(path)

      json = JSON.parse(File.read(path))
      json["description"]?.try(&.as_s?)
    rescue
      nil
    end

    # Derive .meta.json path from parent transcript
    # path and agent_id.
    def self.derive_meta_path(
      parent_transcript_path : String,
      agent_id : String,
    ) : String?
      return nil unless parent_transcript_path
                          .ends_with?(".jsonl")

      base = parent_transcript_path[0...-6]
      "#{base}/subagents/" \
      "agent-#{agent_id}.meta.json"
    end
  end
end
