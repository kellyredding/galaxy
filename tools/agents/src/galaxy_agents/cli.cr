require "json"

module GalaxyAgents
  module CLI
    def self.run(args : Array(String))
      if args.empty?
        show_help
        return
      end

      command = args.first
      rest = args[1..]

      case command
      when "start"
        if rest.includes?("-h") || rest.includes?("--help")
          show_start_help
        else
          handle_start(rest)
        end
      when "stop"
        if rest.includes?("-h") || rest.includes?("--help")
          show_stop_help
        else
          handle_stop(rest)
        end
      when "abandon"
        if rest.includes?("-h") || rest.includes?("--help")
          show_abandon_help
        else
          handle_abandon(rest)
        end
      when "reconcile"
        if rest.includes?("-h") || rest.includes?("--help")
          show_reconcile_help
        else
          handle_reconcile(rest)
        end
      when "list"
        if rest.includes?("-h") || rest.includes?("--help")
          show_list_help
        else
          handle_list(rest)
        end
      when "show"
        if rest.includes?("-h") || rest.includes?("--help")
          show_show_help
        else
          handle_show(rest)
        end
      when "stats"
        if rest.includes?("-h") || rest.includes?("--help")
          show_stats_help
        else
          handle_stats(rest)
        end
      when "running"
        if rest.includes?("-h") || rest.includes?("--help")
          show_running_help
        else
          handle_running(rest)
        end
      when "backup"
        handle_backup_command(rest)
      when "version"
        puts "galaxy-agents #{VERSION}"
      when "help", "-h", "--help"
        if rest.empty?
          show_help
        else
          show_subcommand_help(rest.first)
        end
      when "-v", "--version"
        puts "galaxy-agents #{VERSION}"
      else
        STDERR.puts "Error: Unknown command '#{command}'"
        STDERR.puts(
          "Run 'galaxy-agents --help' for usage",
        )
        exit(1)
      end
    end

    # ==========================================================
    # start
    # ==========================================================

    private def self.handle_start(args : Array(String))
      ledger_session_id_str : String? = nil
      agent_id : String? = nil
      agent_type : String? = nil
      parent_transcript_path : String? = nil

      i = 0
      while i < args.size
        case args[i]
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        when "--agent-id"
          if i + 1 < args.size
            agent_id = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --agent-id requires a value",
            )
            exit(1)
          end
        when "--agent-type"
          if i + 1 < args.size
            agent_type = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --agent-type requires a value",
            )
            exit(1)
          end
        when "--parent-transcript-path"
          if i + 1 < args.size
            parent_transcript_path = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --parent-transcript-path " \
              "requires a value",
            )
            exit(1)
          end
        else
          STDERR.puts(
            "Error: Unknown option '#{args[i]}'",
          )
          STDERR.puts(
            "Run 'galaxy-agents start --help' " \
            "for usage",
          )
          exit(1)
        end
      end

      ledger_session_id = resolve_required_session_id(
        ledger_session_id_str, "start",
      )

      unless agent_id
        STDERR.puts "Error: --agent-id is required"
        STDERR.puts(
          "Run 'galaxy-agents start --help' " \
          "for usage",
        )
        exit(1)
      end

      unless agent_type
        STDERR.puts "Error: --agent-type is required"
        STDERR.puts(
          "Run 'galaxy-agents start --help' " \
          "for usage",
        )
        exit(1)
      end

      # Read description from .meta.json (best-effort)
      description : String? = nil
      if ptp = parent_transcript_path
        description = MetaReader.read_description(
          ptp, agent_id,
        )
      end

      # Detect an already-running row so the lifecycle
      # timeline event below can be suppressed. Resuming a
      # subagent re-fires SubagentStart, and the hook carries
      # no flag distinguishing a resume from a fresh spawn,
      # so without this guard the second start publishes a
      # duplicate durationStart paired with the same
      # agent--<id> identifier: it double-increments the
      # running-agent badge in Galaxy.app and leaves an
      # orphaned bar in the Timeline tab that never closes.
      # The badge only ever drifts upward, because the
      # matching decrement clamps at zero while the increment
      # has no ceiling. Mirrors the already_terminal guard on
      # the stop path.
      existing = Database.get_agent(
        ledger_session_id, agent_id,
      )
      already_running =
        existing.try(&.status) == "running"

      Database.start_agent(
        ledger_session_id,
        agent_id,
        agent_type,
        description,
      )

      # Timeline event + socket signal (fire-and-forget)
      unless already_running
        TimelinePublisher.agent_started(
          ledger_session_id,
          agent_id: agent_id,
          agent_type: agent_type,
          description: description,
        )
      end

      if already_running
        puts(
          "Agent #{agent_id} start recorded " \
          "(was already running)",
        )
      else
        puts "Agent #{agent_id} started"
      end
    end

    # ==========================================================
    # stop
    # ==========================================================

    private def self.handle_stop(args : Array(String))
      ledger_session_id_str : String? = nil
      agent_id : String? = nil
      agent_transcript_path : String? = nil
      last_message_stdin = false

      i = 0
      while i < args.size
        case args[i]
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        when "--agent-id"
          if i + 1 < args.size
            agent_id = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --agent-id requires a value",
            )
            exit(1)
          end
        when "--agent-transcript-path"
          if i + 1 < args.size
            agent_transcript_path = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --agent-transcript-path " \
              "requires a value",
            )
            exit(1)
          end
        when "--last-message-stdin"
          last_message_stdin = true
          i += 1
        else
          STDERR.puts(
            "Error: Unknown option '#{args[i]}'",
          )
          STDERR.puts(
            "Run 'galaxy-agents stop --help' " \
            "for usage",
          )
          exit(1)
        end
      end

      ledger_session_id = resolve_required_session_id(
        ledger_session_id_str, "stop",
      )

      unless agent_id
        STDERR.puts "Error: --agent-id is required"
        STDERR.puts(
          "Run 'galaxy-agents stop --help' for usage",
        )
        exit(1)
      end

      # Read last_message from stdin
      last_message : String? = nil
      if last_message_stdin
        raw = STDIN.gets_to_end.strip
        last_message = raw unless raw.empty?
      end

      # Extract prompt from transcript (best-effort)
      prompt : String? = nil
      if atp = agent_transcript_path
        prompt = TranscriptReader.extract_prompt(atp)
      end

      # Look up existing agent for started_at
      existing = Database.get_agent(
        ledger_session_id, agent_id,
      )

      # Detect already-terminal so the lifecycle timeline
      # event below can be suppressed. Without this guard,
      # a SubagentStop following a manual abandon would
      # publish a second durationEnd event paired with the
      # same agent--<id> identifier and double-decrement
      # the running-agent badge in Galaxy.app. The DB write
      # below still captures last_message / transcript_path
      # / duration_ms so the detail view reflects the real
      # completion data — only the redundant lifecycle
      # broadcast is dropped.
      already_terminal = false
      if e = existing
        already_terminal =
          Database::TERMINAL_STATUSES.includes?(e.status)
      end

      # Compute duration
      duration_ms : Int64? = nil
      if existing
        begin
          started = Time.parse_utc(
            existing.started_at, "%Y-%m-%d %H:%M:%S",
          )
          elapsed = Time.utc - started
          duration_ms = elapsed.total_milliseconds.to_i64
        rescue
          # Can't compute duration
        end
      end

      # Determine status: stopped or failed
      status = determine_stop_status(last_message)

      result = Database.stop_agent(
        ledger_session_id,
        agent_id,
        status: status,
        prompt: prompt,
        last_message: last_message,
        transcript_path: agent_transcript_path,
        duration_ms: duration_ms,
      )

      unless result
        STDERR.puts(
          "Error: agent #{agent_id} not found",
        )
        exit(1)
      end

      # Save transcript as artifact (best-effort)
      if atp = agent_transcript_path
        save_transcript_artifact(
          ledger_session_id, agent_id,
          existing.try(&.agent_type) || "unknown",
          atp,
          existing.try(&.description),
        )
      end

      dm = duration_ms || 0_i64
      at = existing.try(&.agent_type) || "unknown"

      # Timeline event — suppress when the agent was
      # already terminal. The prior end event (e.g. from a
      # manual abandon) already paired with start; emitting
      # a second one would over-decrement the
      # running-agent badge.
      unless already_terminal
        if status == "stopped"
          TimelinePublisher.agent_stopped(
            ledger_session_id,
            agent_id: agent_id,
            agent_type: at,
            duration_ms: dm,
            prompt: prompt,
            last_message: last_message,
          )
        else
          TimelinePublisher.agent_failed(
            ledger_session_id,
            agent_id: agent_id,
            agent_type: at,
            duration_ms: dm,
            prompt: prompt,
            last_message: last_message,
          )
        end
      end

      if already_terminal
        prior = existing.try(&.status) || "terminal"
        puts(
          "Agent #{agent_id} stop recorded " \
          "(was already #{prior}; details captured)",
        )
      else
        duration_str = format_duration(dm)
        puts(
          "Agent #{agent_id} #{status} (#{duration_str})",
        )
      end
    end

    # ==========================================================
    # abandon
    # ==========================================================

    private def self.handle_abandon(args : Array(String))
      ledger_session_id_str : String? = nil
      agent_id : String? = nil

      i = 0
      while i < args.size
        case args[i]
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        when "--agent-id"
          if i + 1 < args.size
            agent_id = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --agent-id requires a value",
            )
            exit(1)
          end
        else
          STDERR.puts(
            "Error: Unknown option '#{args[i]}'",
          )
          STDERR.puts(
            "Run 'galaxy-agents abandon --help' " \
            "for usage",
          )
          exit(1)
        end
      end

      ledger_session_id = resolve_required_session_id(
        ledger_session_id_str, "abandon",
      )

      # Single-agent path: scope to one row.
      if aid = agent_id
        agent = Database.abandon_agent(
          ledger_session_id, aid,
        )

        if agent
          TimelinePublisher.agent_abandoned(
            ledger_session_id,
            agent_id: agent.agent_id,
            agent_type: agent.agent_type,
          )
          puts "Abandoned agent #{aid}"
        else
          # No-op is success from the caller's point of
          # view: either the agent was already terminal or
          # doesn't exist. Exit 0 so SwiftUI clients don't
          # have to distinguish "race lost" from real errors.
          puts(
            "Agent #{aid} not running " \
            "(already terminal or not found)",
          )
        end
        return
      end

      # Bulk path: abandon all running agents for the session.
      abandoned = Database.abandon_running(
        ledger_session_id,
      )

      abandoned.each do |agent|
        TimelinePublisher.agent_abandoned(
          ledger_session_id,
          agent_id: agent.agent_id,
          agent_type: agent.agent_type,
        )
      end

      puts "Abandoned #{abandoned.size} agents"
    end

    # ==========================================================
    # reconcile
    # ==========================================================

    # Sweep every running row whose owning process is gone, then
    # report the running count per session.
    #
    # Global rather than session-scoped, deliberately. Scoping to
    # live sessions would find nothing by construction: a live
    # session has a live pid, and a live pid means none of its
    # rows are sweepable. The rows worth sweeping belong to
    # sessions that are no longer running, which no caller can
    # enumerate — so this resolves ownership itself rather than
    # being told.
    private def self.handle_reconcile(args : Array(String))
      dry_run = false

      i = 0
      while i < args.size
        case args[i]
        when "--dry-run"
          dry_run = true
          i += 1
        else
          STDERR.puts(
            "Error: Unknown option '#{args[i]}'",
          )
          STDERR.puts(
            "Run 'galaxy-agents reconcile --help' " \
            "for usage",
          )
          exit(1)
        end
      end

      # Mirrors GALAXY_SKIP_HOOKS: one variable stops the writing
      # without stopping the tool, so a sweep behaving badly can
      # be halted without editing settings or waiting on a
      # release. Reported in the output rather than silently, so
      # a caller cannot mistake "disabled" for "nothing to do".
      if ENV["GALAXY_AGENTS_SKIP_RECONCILE"]? == "1"
        puts(
          {
            skipped: true,
            dry_run: dry_run,
            swept:   [] of String,
            running: {} of String => Int64,
          }.to_json,
        )
        return
      end

      # Ordered deliberately. A death the agent recorded about
      # itself outranks an inference drawn from whether some
      # process is still alive — it is a fact rather than a
      # deduction, it is true even while the session runs on, and
      # it can say why, which abandonment never can.
      died = [] of {Database::RunningOwner, AgentOutcome::ErrorDeath}
      orphaned = [] of Database::RunningOwner

      Database.running_with_owner_pids.each do |row|
        if death = AgentOutcome.error_death(row.agent_id)
          died << {row, death}
        elsif !ProcessLiveness.claude_alive?(row.owner_pid)
          orphaned << row
        end
      end

      unless dry_run
        died.each do |(row, death)|
          # The ordinary completion write, so a recovered row
          # ends up the same shape a normal stop would have left.
          recorded = Database.stop_agent(
            row.ledger_session_id,
            row.agent_id,
            "failed",
            last_message: death.message,
            duration_ms: AgentOutcome.duration_ms(
              started_at: row.started_at,
              died_at: death.died_at,
            ),
            completed_at: death.died_at,
          )
          next unless recorded

          TimelinePublisher.agent_failed(
            row.ledger_session_id,
            agent_id: row.agent_id,
            agent_type: row.agent_type,
            duration_ms: AgentOutcome.duration_ms(
              started_at: row.started_at,
              died_at: death.died_at,
            ) || 0_i64,
            prompt: nil,
            last_message: death.message,
          )
        end

        orphaned.each do |row|
          agent = Database.abandon_agent(
            row.ledger_session_id, row.agent_id,
          )
          next unless agent

          # Same publication a manual abandon makes. The
          # timeline opened a duration for this agent at start
          # and needs its close, or the bar runs forever.
          TimelinePublisher.agent_abandoned(
            row.ledger_session_id,
            agent_id: agent.agent_id,
            agent_type: agent.agent_type,
          )
        end
      end

      swept = orphaned

      # Read after the sweep, so a caller can never render a
      # pre-sweep number and sit wrong until the next tick.
      counts = Database.running_counts_by_session

      puts(
        JSON.build do |json|
          json.object do
            json.field "skipped", false
            json.field "dry_run", dry_run
            json.field "failed" do
              json.array do
                died.each do |(row, death)|
                  json.object do
                    json.field "agent_id", row.agent_id
                    json.field "agent_type", row.agent_type
                    json.field(
                      "ledger_session_id",
                      row.ledger_session_id,
                    )
                    json.field "message", death.message
                    json.field "died_at", death.died_at
                  end
                end
              end
            end
            json.field "swept" do
              json.array do
                swept.each do |row|
                  json.object do
                    json.field "agent_id", row.agent_id
                    json.field "agent_type", row.agent_type
                    json.field(
                      "ledger_session_id",
                      row.ledger_session_id,
                    )
                    json.field "owner_pid", row.owner_pid
                  end
                end
              end
            end
            json.field "running" do
              json.object do
                counts.each do |session_id, count|
                  json.field session_id.to_s, count
                end
              end
            end
          end
        end,
      )
    end

    # ==========================================================
    # list
    # ==========================================================

    private def self.handle_list(args : Array(String))
      ledger_session_id_str : String? = nil
      pid_str : String? = nil
      session_id : String? = nil
      json_mode = false
      limit : Int32? = nil

      i = 0
      while i < args.size
        case args[i]
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        when "--pid"
          if i + 1 < args.size
            pid_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --pid requires a value",
            )
            exit(1)
          end
        when "--session"
          if i + 1 < args.size
            session_id = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --session requires a value",
            )
            exit(1)
          end
        when "--json"
          json_mode = true
          i += 1
        when "--limit"
          if i + 1 < args.size
            limit = args[i + 1].to_i?
            i += 2
          else
            STDERR.puts(
              "Error: --limit requires a value",
            )
            exit(1)
          end
        else
          STDERR.puts(
            "Error: Unknown option '#{args[i]}'",
          )
          STDERR.puts(
            "Run 'galaxy-agents list --help' " \
            "for usage",
          )
          exit(1)
        end
      end

      ledger_session_id = resolve_session_id(
        ledger_session_id_str, pid_str, session_id,
        "list",
      )

      agents = Database.list_agents(
        ledger_session_id, limit,
      )

      if json_mode
        JSON.build(STDOUT) do |json|
          json.object do
            json.field "agents" do
              json.array do
                agents.each do |a|
                  agent_to_json(json, a)
                end
              end
            end
          end
        end
        puts ""
        return
      end

      if agents.empty?
        puts "No agents for this session."
        return
      end

      puts "Agents for session " \
           "(#{agents.size} total):"
      puts ""

      agents.each do |a|
        aid = a.agent_id
        if aid.size > 8
          aid = aid[0, 8] + ".."
        end
        dur = a.duration_ms
        dur_str = dur ? format_duration(dur) : "\u2014"
        time_str = format_time_short(a.started_at)
        puts "  %-12s %-17s %-10s %6s  %s" % [
          aid, a.agent_type, a.status, dur_str,
          time_str,
        ]
      end
    end

    # ==========================================================
    # show
    # ==========================================================

    private def self.handle_show(args : Array(String))
      ledger_session_id_str : String? = nil
      agent_id : String? = nil
      json_mode = false

      i = 0
      while i < args.size
        case args[i]
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        when "--agent-id"
          if i + 1 < args.size
            agent_id = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --agent-id requires a value",
            )
            exit(1)
          end
        when "--json"
          json_mode = true
          i += 1
        else
          STDERR.puts(
            "Error: Unknown option '#{args[i]}'",
          )
          STDERR.puts(
            "Run 'galaxy-agents show --help' " \
            "for usage",
          )
          exit(1)
        end
      end

      ledger_session_id = resolve_required_session_id(
        ledger_session_id_str, "show",
      )

      unless agent_id
        STDERR.puts "Error: --agent-id is required"
        STDERR.puts(
          "Run 'galaxy-agents show --help' for usage",
        )
        exit(1)
      end

      agent = Database.get_agent(
        ledger_session_id, agent_id,
      )

      unless agent
        STDERR.puts(
          "Error: agent '#{agent_id}' not found",
        )
        exit(1)
      end

      if json_mode
        JSON.build(STDOUT) do |json|
          agent_to_json(json, agent)
        end
        puts ""
      else
        show_agent_detail(agent)
      end
    end

    # ==========================================================
    # stats
    # ==========================================================

    private def self.handle_stats(args : Array(String))
      ledger_session_id_str : String? = nil
      pid_str : String? = nil
      session_id : String? = nil

      i = 0
      while i < args.size
        case args[i]
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        when "--pid"
          if i + 1 < args.size
            pid_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --pid requires a value",
            )
            exit(1)
          end
        when "--session"
          if i + 1 < args.size
            session_id = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --session requires a value",
            )
            exit(1)
          end
        when "--json"
          # accepted but stats always outputs JSON
          i += 1
        else
          STDERR.puts(
            "Error: Unknown option '#{args[i]}'",
          )
          STDERR.puts(
            "Run 'galaxy-agents stats --help' " \
            "for usage",
          )
          exit(1)
        end
      end

      ledger_session_id = resolve_session_id(
        ledger_session_id_str, pid_str, session_id,
        "stats",
      )

      counts = Database.status_counts(
        ledger_session_id,
      )
      total = counts.values.sum

      JSON.build(STDOUT) do |json|
        json.object do
          json.field "total", total
          json.field "running",
            counts["running"]
          json.field "stopped",
            counts["stopped"]
          json.field "failed",
            counts["failed"]
          json.field "abandoned",
            counts["abandoned"]
        end
      end
      puts ""
    end

    # ==========================================================
    # running
    # ==========================================================

    private def self.handle_running(args : Array(String))
      ledger_session_id_str : String? = nil
      pid_str : String? = nil

      i = 0
      while i < args.size
        case args[i]
        when "--ledger-session-id"
          if i + 1 < args.size
            ledger_session_id_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --ledger-session-id " \
              "requires a value",
            )
            exit(1)
          end
        when "--pid"
          if i + 1 < args.size
            pid_str = args[i + 1]
            i += 2
          else
            STDERR.puts(
              "Error: --pid requires a value",
            )
            exit(1)
          end
        when "--json"
          # accepted
          i += 1
        else
          STDERR.puts(
            "Error: Unknown option '#{args[i]}'",
          )
          STDERR.puts(
            "Run 'galaxy-agents running --help' " \
            "for usage",
          )
          exit(1)
        end
      end

      ledger_session_id = resolve_session_id(
        ledger_session_id_str, pid_str, nil, "running",
      )

      count = Database.running_count(
        ledger_session_id,
      )

      JSON.build(STDOUT) do |json|
        json.object do
          json.field "count", count
        end
      end
      puts ""
    end

    # ==========================================================
    # backup
    # ==========================================================

    private def self.handle_backup_command(
      args : Array(String),
    )
      if args.includes?("-h") || args.includes?("--help")
        show_backup_help
        return
      end

      list_mode = false
      prune_only = false
      session_id = 0_i64

      i = 0
      while i < args.size
        case args[i]
        when "--list"
          list_mode = true
        when "--prune-only"
          prune_only = true
        when "--session-id"
          if i + 1 < args.size
            session_id = args[i + 1].to_i64? || 0_i64
            i += 1
          end
        end
        i += 1
      end

      config = SharedBackupConfig.load

      if list_mode
        backup_list(config)
      elsif prune_only
        backup_prune_only(config)
      else
        backup_create_and_prune(config, session_id)
      end
    end

    private def self.backup_list(
      config : SharedBackupConfig,
    )
      backup_dir = config.effective_backup_path

      unless Dir.exists?(backup_dir)
        puts "No backups found."
        puts "Backup directory: #{backup_dir}"
        return
      end

      date_dirs = [] of String
      Dir.each_child(backup_dir) do |entry|
        entry_path = backup_dir / entry
        next unless File.directory?(entry_path)
        begin
          Time.parse(
            entry, "%Y-%m-%d",
            Time::Location.local,
          )
          date_dirs << entry
        rescue Time::Format::Error
        end
      end

      if date_dirs.empty?
        puts "No backups found."
        puts "Backup directory: #{backup_dir}"
        return
      end

      date_dirs.sort!.reverse!

      puts "Backups in #{backup_dir} " \
           "(retention: " \
           "#{config.backups.retention_days} days)"
      puts ""

      total_count = 0
      total_bytes = 0_i64

      date_dirs.each do |date_dir|
        dir_path = backup_dir / date_dir
        files = [] of {name: String, size: Int64, time: Time}

        Dir.each_child(dir_path) do |file|
          file_path = dir_path / file
          next unless File.file?(file_path) &&
                      file.ends_with?(".db")
          info = File.info(file_path)
          files << {
            name: file,
            size: info.size,
            time: info.modification_time,
          }
        end

        next if files.empty?
        files.sort_by! { |f| f[:time] }.reverse!

        dir_size = files.sum(&.[:size])
        count_label = files.size == 1 ? "backup" : "backups"
        puts "  #{date_dir}/ " \
             "(#{files.size} #{count_label}, " \
             "#{format_size(dir_size)})"

        files.each do |f|
          time_str = f[:time].to_s(
            "%l:%M %p",
          ).strip
          puts "    %-25s %8s   %s" % [
            f[:name],
            format_size(f[:size]),
            time_str,
          ]
        end
        puts ""

        total_count += files.size
        total_bytes += dir_size
      end

      total_label = total_count == 1 ? "backup" : "backups"
      puts "  Total: #{total_count} " \
           "#{total_label}, " \
           "#{format_size(total_bytes)}"
    end

    private def self.backup_create_and_prune(
      config : SharedBackupConfig,
      session_id : Int64,
    )
      unless config.backups.enabled
        puts "Backups are disabled."
        return
      end

      backup_dir = config.effective_backup_path

      result = Database.backup(backup_dir, session_id)
      if result
        size = File.size(result)
        puts "Backup created: #{result} " \
             "(#{format_size(size)})"
      else
        STDERR.puts "Backup failed."
      end

      pruned = Database.prune_backups(
        backup_dir, config.backups.retention_days,
      )
      if pruned > 0
        dir_label = pruned == 1 ? "directory" : "directories"
        puts "Pruned #{pruned} old backup " \
             "#{dir_label}."
      end
    end

    private def self.backup_prune_only(
      config : SharedBackupConfig,
    )
      backup_dir = config.effective_backup_path
      pruned = Database.prune_backups(
        backup_dir, config.backups.retention_days,
      )
      if pruned > 0
        dir_label = pruned == 1 ? "directory" : "directories"
        puts "Pruned #{pruned} old backup " \
             "#{dir_label}."
      else
        puts "No backups to prune."
      end
    end

    # ==========================================================
    # Helpers
    # ==========================================================

    # Determine if a stopped agent succeeded or failed.
    # Start simple: has last_message = stopped (success);
    # empty/nil last_message = failed.
    private def self.determine_stop_status(
      last_message : String?,
    ) : String
      if last_message && !last_message.empty?
        "stopped"
      else
        "failed"
      end
    end

    # Save the agent transcript as an artifact via
    # galaxy-artifacts CLI (best-effort, fire-and-forget).
    private def self.save_transcript_artifact(
      ledger_session_id : Int64,
      agent_id : String,
      agent_type : String,
      transcript_path : String,
      description : String? = nil,
    )
      return unless File.exists?(transcript_path)

      title = if d = description
                "Agent: #{agent_type} " \
                "(#{d}) (#{agent_id})"
              else
                "Agent: #{agent_type} (#{agent_id})"
              end

      Process.new(
        ARTIFACTS_BIN.to_s,
        args: [
          "save",
          "--ledger-session-id",
          ledger_session_id.to_s,
          "--source-path", transcript_path,
          "--title", title,
          "--artifact-type", "jsonl",
          "--description", "Agent transcript",
          # Agent transcripts are a side-effect of agent
          # lifecycle, not user-initiated saves. Suppress
          # the artifact.show socket event so Galaxy.app
          # doesn't auto-open a reader on the user. The
          # artifact remains available in the Artifacts tab.
          "--skip-event",
        ],
        input: Process::Redirect::Close,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close,
      )
    rescue
      # Best-effort
    end

    # Session ID resolution helpers

    private def self.resolve_required_session_id(
      ledger_session_id_str : String?,
      command : String,
    ) : Int64
      if lsid_str = ledger_session_id_str
        return resolve_ledger_session_id_str(lsid_str)
      end

      STDERR.puts(
        "Error: --ledger-session-id is required",
      )
      STDERR.puts(
        "Run 'galaxy-agents #{command} --help' " \
        "for usage",
      )
      exit(1)
    end

    private def self.resolve_session_id(
      ledger_session_id_str : String?,
      pid_str : String?,
      session_id : String?,
      command : String,
    ) : Int64
      if lsid_str = ledger_session_id_str
        return resolve_ledger_session_id_str(lsid_str)
      elsif ps = pid_str
        return resolve_pid_to_ledger_session_id(ps)
      elsif sid = session_id
        return resolve_session_to_ledger_session_id(
          sid,
        )
      end

      STDERR.puts(
        "Error: --pid, --session, or " \
        "--ledger-session-id is required",
      )
      STDERR.puts(
        "Run 'galaxy-agents #{command} --help' " \
        "for usage",
      )
      exit(1)
    end

    private def self.resolve_ledger_session_id_str(
      id_str : String,
    ) : Int64
      id = id_str.to_i64?
      unless id
        STDERR.puts(
          "Error: invalid --ledger-session-id " \
          "value '#{id_str}' (must be an integer)",
        )
        exit(1)
      end
      id
    end

    private def self.resolve_pid_to_ledger_session_id(
      pid_str : String,
    ) : Int64
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run(
        LEDGER_BIN.to_s,
        args: [
          "resolve-session", "--pid", pid_str,
        ],
        output: output,
        error: error,
      )

      unless status.success?
        err = error.to_s.strip
        if err.empty?
          STDERR.puts(
            "Error: failed to resolve PID " \
            "#{pid_str}",
          )
        else
          STDERR.puts err
        end
        exit(1)
      end

      result = output.to_s.strip.to_i64?
      unless result
        STDERR.puts(
          "Error: invalid response from ledger " \
          "for PID #{pid_str}",
        )
        exit(1)
      end

      result
    end

    private def self.resolve_session_to_ledger_session_id(
      session_identifier : String,
    ) : Int64
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run(
        LEDGER_BIN.to_s,
        args: [
          "resolve-session",
          "--session", session_identifier,
        ],
        output: output,
        error: error,
      )

      unless status.success?
        err = error.to_s.strip
        if err.empty?
          STDERR.puts(
            "Error: failed to resolve session " \
            "'#{session_identifier}'",
          )
        else
          STDERR.puts err
        end
        exit(1)
      end

      result = output.to_s.strip.to_i64?
      unless result
        STDERR.puts(
          "Error: invalid response from ledger " \
          "for session '#{session_identifier}'",
        )
        exit(1)
      end

      result
    end

    # JSON serialization for an agent
    private def self.agent_to_json(
      json : JSON::Builder, a : Database::Agent,
    )
      json.object do
        json.field "agent_id", a.agent_id
        json.field "agent_type", a.agent_type
        json.field "description", a.description
        json.field "status", a.status
        json.field "started_at", a.started_at
        json.field "completed_at", a.completed_at
        json.field "duration_ms", a.duration_ms
        json.field "prompt", a.prompt
        json.field "last_message", a.last_message
        json.field "transcript_path",
          a.transcript_path
      end
    end

    # Human-readable detail for show command
    private def self.show_agent_detail(
      a : Database::Agent,
    )
      puts "Agent: #{a.agent_id}"
      puts "  Type:        #{a.agent_type}"
      puts "  Status:      #{a.status}"
      if desc = a.description
        puts "  Description: #{desc}"
      end
      puts "  Started:     #{a.started_at}"
      if ca = a.completed_at
        puts "  Completed:   #{ca}"
      end
      if dm = a.duration_ms
        puts "  Duration:    #{format_duration(dm)}"
      end
      if tp = a.transcript_path
        puts "  Transcript:  #{tp}"
      end
      if p = a.prompt
        puts "  Prompt:      #{p}"
      end
      if lm = a.last_message
        puts "  Last msg:    #{lm}"
      end
    end

    # Formatting helpers

    private def self.format_duration(
      ms : Int64,
    ) : String
      if ms >= 60_000
        # Floor division: `/` on two integers yields a Float
        # in Crystal, which put the whole fractional duration
        # into the minutes component beside an already-correct
        # seconds remainder.
        minutes = ms // 60_000
        seconds = (ms % 60_000) / 1000.0
        "#{minutes}m#{"%.1f" % seconds}s"
      else
        "#{"%.1f" % (ms / 1000.0)}s"
      end
    end

    private def self.format_time_short(
      utc_str : String,
    ) : String
      begin
        utc_time = Time.parse_utc(
          utc_str, "%Y-%m-%d %H:%M:%S",
        )
        local_time = utc_time.to_local
        hour = local_time.hour % 12
        hour = 12 if hour == 0
        ampm = local_time.hour >= 12 ? "PM" : "AM"
        "#{hour}:#{local_time.to_s("%M")} #{ampm}"
      rescue
        utc_str
      end
    end

    private def self.format_size(
      bytes : Int64,
    ) : String
      if bytes < 1024
        "#{bytes} B"
      elsif bytes < 1024 * 1024
        "%.1f KB" % (bytes / 1024.0)
      else
        "%.1f MB" % (bytes / (1024.0 * 1024.0))
      end
    end

    # ==========================================================
    # Help Text
    # ==========================================================

    private def self.show_subcommand_help(
      cmd : String,
    )
      case cmd
      when "start"   then show_start_help
      when "stop"    then show_stop_help
      when "abandon" then show_abandon_help
      when "list"    then show_list_help
      when "show"    then show_show_help
      when "stats"   then show_stats_help
      when "running" then show_running_help
      when "backup"  then show_backup_help
      else
        STDERR.puts(
          "Error: Unknown command '#{cmd}'",
        )
        show_help
      end
    end

    private def self.show_help
      puts <<-HELP
      galaxy-agents - Track subagent lifecycle

      USAGE:
        galaxy-agents <command> [options]

      COMMANDS:
        start       Record a new agent starting
        stop        Record an agent stopping
        abandon     Mark running agents as abandoned
        reconcile   Sweep agents whose process is gone (JSON)
        list        List agents for a session
        show        Show full agent detail
        stats       Get agent counts by status (JSON)
        running     Get count of running agents (JSON)
        backup      Manage database backups
        version     Show version

      Run 'galaxy-agents <command> --help' for detailed usage.
      HELP
    end

    private def self.show_start_help
      puts <<-HELP
      galaxy-agents start - Record a new agent starting

      USAGE:
        galaxy-agents start --ledger-session-id ID \\
          --agent-id AID --agent-type TYPE \\
          [--parent-transcript-path PATH]

      REQUIRED:
        --ledger-session-id ID        Ledger session ID
        --agent-id AID                Agent identifier
        --agent-type TYPE             Agent type (e.g. Explore)

      OPTIONS:
        --parent-transcript-path PATH Parent transcript for .meta.json lookup

      DESCRIPTION:
        Records a new agent with status 'running'. Reads the
        agent description from .meta.json if the parent
        transcript path is provided. Publishes agent:started
        timeline event and agent.started socket event.
      HELP
    end

    private def self.show_stop_help
      puts <<-HELP
      galaxy-agents stop - Record an agent stopping

      USAGE:
        galaxy-agents stop --ledger-session-id ID \\
          --agent-id AID \\
          [--agent-transcript-path PATH] \\
          [--last-message-stdin]

      REQUIRED:
        --ledger-session-id ID           Ledger session ID
        --agent-id AID                   Agent identifier

      OPTIONS:
        --agent-transcript-path PATH     Agent transcript JSONL
        --last-message-stdin             Read last message from stdin

      DESCRIPTION:
        Stops a running agent. Determines success (stopped) or
        failure (failed) based on last_message presence. Extracts
        the prompt from the transcript, computes duration, saves
        transcript as artifact, and publishes timeline/socket events.
      HELP
    end

    private def self.show_abandon_help
      puts <<-HELP
      galaxy-agents abandon - Mark running agents as abandoned

      USAGE:
        galaxy-agents abandon --ledger-session-id ID
        galaxy-agents abandon --ledger-session-id ID \\
          --agent-id AID

      REQUIRED:
        --ledger-session-id ID   Ledger session ID

      OPTIONS:
        --agent-id AID           Abandon only this agent.
                                 When omitted, abandons all
                                 running agents for the
                                 session.

      DESCRIPTION:
        Marks running agents as abandoned. Used at session
        end to clean up orphaned agents (bulk path), or
        manually to clean up a specific agent that was
        killed externally — e.g. after a crash — using the
        --agent-id option. Publishes agent:abandoned timeline
        event and agent.abandoned socket event for each
        affected agent.

        When --agent-id is provided and the agent is already
        terminal (or doesn't exist), the command exits 0
        with a no-op message so callers can retry safely.
      HELP
    end

    private def self.show_reconcile_help
      puts <<-HELP
      galaxy-agents reconcile - Sweep agents whose process is gone

      USAGE:
        galaxy-agents reconcile
        galaxy-agents reconcile --dry-run

      OPTIONS:
        --dry-run    Report what would be swept without
                     writing anything.

      DESCRIPTION:
        Closes running agents that cannot still be running, then
        reports the running count for each session as JSON.

        Two ways an agent qualifies.

        It recorded its own death. An agent that ends on an API
        error writes a final transcript record saying so, and
        SubagentStop never lands for those — so the row is closed
        as FAILED, carrying that error as its last message and
        the time from the record rather than from this sweep.
        True even while the session runs on, which is the case
        the liveness check below structurally cannot see.

        Or its owning Claude Code process is gone, in which case
        the row is marked ABANDONED.

        A clean final record, an unreadable transcript, or no
        transcript at all leaves the row alone. None of those
        prove death, and a wrong close cannot be undone.

        Takes no session argument, deliberately. A live session
        has a live process, so none of its rows are ever
        sweepable — the rows worth sweeping belong to sessions
        that already exited, which no caller can enumerate.
        Ownership is resolved here instead.

        Liveness is judged against the pid that owned the
        session when the agent STARTED, read from
        ledger_session_pids, not the session's current pid. Most
        recorded agents belong to sessions resumed since they
        started, where the current pid is a different and often
        live process.

        A row is swept only when its owner is provably gone: a
        pid that no longer exists, a session with no ledger row,
        or a pid now held by some other command. A process that
        exists but cannot be signalled counts as alive.

        Publishes agent:abandoned per swept row, exactly as a
        manual abandon does.

        Set GALAXY_AGENTS_SKIP_RECONCILE=1 to disable sweeping;
        the output then reports "skipped": true.

        Output:
          {"skipped":false,"dry_run":false,
           "swept":[{"agent_id":"…","agent_type":"…",
                     "ledger_session_id":1,"owner_pid":123}],
           "running":{"2":1}}
      HELP
    end

    private def self.show_list_help
      puts <<-HELP
      galaxy-agents list - List agents for a session

      USAGE:
        galaxy-agents list --ledger-session-id ID [--json]
        galaxy-agents list --pid PID [--json]
        galaxy-agents list --session SESSION_ID [--json]

      REQUIRED (one of):
        --ledger-session-id ID   Direct ledger session ID
        --pid PID                Claude Code process ID
        --session ID             Session identifier

      OPTIONS:
        --json                   Output as JSON
        --limit N                Max agents to return (default: all)

      DESCRIPTION:
        Lists all agents for the specified session with agent_id,
        type, status, duration, and start time.
      HELP
    end

    private def self.show_show_help
      puts <<-HELP
      galaxy-agents show - Show full agent detail

      USAGE:
        galaxy-agents show --ledger-session-id ID \\
          --agent-id AID [--json]

      REQUIRED:
        --ledger-session-id ID   Ledger session ID
        --agent-id AID           Agent identifier

      OPTIONS:
        --json                   Output as JSON

      DESCRIPTION:
        Shows complete agent detail including prompt,
        last_message, transcript path, and timing.
      HELP
    end

    private def self.show_stats_help
      puts <<-HELP
      galaxy-agents stats - Get agent counts by status

      USAGE:
        galaxy-agents stats --ledger-session-id ID
        galaxy-agents stats --pid PID
        galaxy-agents stats --session SESSION_ID

      REQUIRED (one of):
        --ledger-session-id ID   Direct ledger session ID
        --pid PID                Claude Code process ID
        --session ID             Session identifier

      DESCRIPTION:
        Returns JSON with agent counts broken down by status.

        Output: {"total":N,"running":N,"stopped":N,
                 "failed":N,"abandoned":N}
      HELP
    end

    private def self.show_running_help
      puts <<-HELP
      galaxy-agents running - Get count of running agents

      USAGE:
        galaxy-agents running --ledger-session-id ID
        galaxy-agents running --pid PID

      REQUIRED (one of):
        --ledger-session-id ID   Direct ledger session ID
        --pid PID                Claude Code process ID

      DESCRIPTION:
        Returns JSON with the count of currently running agents.
        Used by Galaxy App for the agents tab badge.

        Output: {"count": N}
      HELP
    end

    private def self.show_backup_help
      puts <<-HELP
      galaxy-agents backup - Manage database backups

      USAGE:
        galaxy-agents backup                   Create backup and prune
        galaxy-agents backup --list            List all backups
        galaxy-agents backup --prune-only      Prune old backups only

      OPTIONS:
        --session-id ID   Session record ID for backup filename (default: 0)
        --list            List all existing backups
        --prune-only      Only prune old backups

      CONFIGURATION:
        Backup settings are managed by the shared Galaxy config.
        Use 'galaxy config' to view and 'galaxy config set' to change:
          galaxy config set backups.enabled true
          galaxy config set backups.retention_days 7
          galaxy config set backups.path /path/to/backups

      DESCRIPTION:
        Creates point-in-time database backups using SQLite
        VACUUM INTO. Backups are stored in date-based directories
        and old ones are automatically pruned.

      EXAMPLES:
        galaxy-agents backup                  # Create + prune
        galaxy-agents backup --list           # See all backups
        galaxy-agents backup --prune-only     # Clean up old
      HELP
    end
  end
end
