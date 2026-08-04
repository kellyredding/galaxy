require "json"

module GalaxyAgents
  module MetaReader
    # How many times to look for the sidecar before giving
    # up, and how long to wait between looks.
    #
    # Claude Code writes agent-<id>.meta.json at roughly the
    # same moment the SubagentStart hook fires, so a single
    # read is close to a coin flip — and losing it means the
    # agent shows a raw id instead of its description for its
    # entire life, since nothing re-reads the file later.
    # Waiting is free here: the hook dispatches this process
    # detached and never waits on it, so the delay is paid by
    # a background process rather than by agent startup.
    DEFAULT_ATTEMPTS = 5
    DEFAULT_DELAY    = 20.milliseconds

    # Read description from .meta.json file.
    # Returns nil if the file never appears or can't
    # be parsed within the retry budget.
    def self.read_description(
      parent_transcript_path : String,
      agent_id : String,
      attempts : Int32 = DEFAULT_ATTEMPTS,
      delay : Time::Span = DEFAULT_DELAY,
    ) : String?
      path = derive_meta_path(
        parent_transcript_path, agent_id,
      )
      return nil unless path

      attempts.times do |attempt|
        if description = read_once(path)
          return description
        end
        sleep(delay) if attempt < attempts - 1
      end

      nil
    end

    # One read attempt. Returns nil when the file is absent,
    # unparseable, or carries no description — the sidecar is
    # written non-atomically, so a half-written file is as
    # expected as a missing one and both are worth retrying.
    private def self.read_once(path : String) : String?
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
