require "json"

module GalaxyAgents
  # Whether an agent recorded its own death.
  #
  # A subagent that dies on an API error writes a final record saying so and
  # then stops. `SubagentStop` never lands for these: measured across the 500
  # most recent transcripts, no error death has ever reached `stopped`, while
  # 486 clean completions all did. The dispatcher drops silently on any of
  # four conditions and from this side "never fired" and "fired without the
  # fields" look identical, so the transcript is the only place that outcome
  # exists, and reading it is the only recovery available.
  #
  # Deliberately narrow. This reports a death the agent itself declared; it
  # does not guess about silence. A transcript that stopped growing might
  # belong to an agent that died or to one that is thinking, and telling those
  # apart needs a threshold — which `stop_agent` would then make permanent,
  # because it will not move a terminal row back.
  module AgentOutcome
    # A death the agent wrote down, with the moment it happened.
    record ErrorDeath, message : String, died_at : String?

    DEFAULT_MESSAGE = "Agent ended on an API error"

    # Where Claude Code keeps subagent transcripts, two levels down:
    # projects/<project>/<session-uuid>/subagents/agent-<id>.jsonl
    def self.transcript_path(agent_id : String) : String?
      return nil if agent_id.empty?

      root = GalaxyAgents::CLAUDE_CONFIG_DIR / "projects"
      Dir.glob(
        "#{root}/*/*/subagents/agent-#{agent_id}.jsonl",
      ).first?
    rescue
      nil
    end

    # The death the agent declared, or nil for anything else.
    #
    # Located by glob rather than a stored path: `agent_id` is unique across
    # every row ever recorded, so at most one file can match and nothing has
    # to have been persisted when the agent started. That also means rows
    # stranded before this code existed are recoverable.
    #
    # Every uncertain answer is nil — a clean final record, a missing file, an
    # unreadable one, a line that will not parse. Each of those means "not
    # proven dead", and the caller keeps the row.
    def self.error_death(agent_id : String) : ErrorDeath?
      path = transcript_path(agent_id)
      return nil unless path

      last = last_line(path)
      return nil if last.nil? || last.empty?

      json = JSON.parse(last)
      return nil unless json["isApiErrorMessage"]?.try(&.as_bool?)

      ErrorDeath.new(
        message: error_text(json),
        died_at: normalized_timestamp(
          json["timestamp"]?.try(&.as_s?),
        ),
      )
    rescue
      nil
    end

    # Milliseconds from `started_at` to the declared death.
    #
    # Nil when either end is unreadable, so the caller falls back to its own
    # derivation rather than recording a number nothing supports.
    def self.duration_ms(
      started_at : String?, died_at : String?,
    ) : Int64?
      return nil unless started_at && died_at

      from = parse_db_time(started_at)
      to = parse_db_time(died_at)
      return nil unless from && to

      span = ((to - from).total_milliseconds).to_i64
      span < 0 ? nil : span
    rescue
      nil
    end

    # The last non-empty line, streamed.
    #
    # These transcripts reach several megabytes, and the sweep reads one per
    # running row on every tick, so the whole file must never be held.
    private def self.last_line(path : String) : String?
      last : String? = nil
      File.each_line(path) do |line|
        stripped = line.strip
        last = stripped unless stripped.empty?
      end
      last
    rescue
      nil
    end

    # What the agent said went wrong.
    #
    # Never nil: writing `failed` instead of `abandoned` is only worth doing
    # if it carries a reason, so this falls back rather than giving up.
    private def self.error_text(json : JSON::Any) : String
      if content = json["message"]?.try(&.["content"]?).try(&.as_a?)
        content.each do |block|
          next unless block["type"]?.try(&.as_s?) == "text"
          text = block["text"]?.try(&.as_s?)
          return text.strip if text && !text.strip.empty?
        end
      end

      if err = json["error"]?.try(&.as_s?)
        return "API error: #{err}" unless err.empty?
      end

      DEFAULT_MESSAGE
    end

    # Transcripts stamp RFC3339; the database stores
    # `YYYY-MM-DD HH:MM:SS` in UTC. Nil rather than a guess when it will not
    # parse, so the caller stamps its own time instead.
    private def self.normalized_timestamp(
      raw : String?,
    ) : String?
      return nil unless raw

      Time.parse_rfc3339(raw).to_utc
        .to_s("%Y-%m-%d %H:%M:%S")
    rescue
      nil
    end

    private def self.parse_db_time(value : String) : Time?
      Time.parse_utc(value, "%Y-%m-%d %H:%M:%S")
    rescue
      nil
    end
  end
end
