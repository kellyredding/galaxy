module GalaxyLedger
  module Hooks
    # Shared context restoration logic used by OnClear and OnCompact.
    #
    # Resolves the session, queries restoration data, and builds the
    # full handoff markdown for context restoration after a reset.
    # Stateless — receives all inputs as parameters, outputs result
    # directly to stdout.
    module ContextHandoff
      # Read-only cap on session files in the manifest
      READ_ONLY_FILES_CAP = 15

      # Maximum time (seconds) to wait for extraction summary data.
      # Leaves ~5s for handoff generation within the 30s hook timeout.
      # Override via GALAXY_EXTRACTION_WAIT_TIMEOUT env var for testing.
      EXTRACTION_WAIT_TIMEOUT = 25

      # Polling interval (seconds) between DB checks.
      # Override via GALAXY_EXTRACTION_POLL_INTERVAL env var for testing.
      EXTRACTION_POLL_INTERVAL = 2

      # Runs the full context handoff flow. Called by OnClear and
      # OnCompact with the parsed hook input.
      def self.run(
        stdin_session_identifier : String?,
        source : String?,
        event_name : String? = nil,
        transcript_path : String? = nil,
        timeline_event_id : Int64? = nil,
      )
        # Resolve session via 3-tier chain (env var → PID → hook session_id),
        # creating a new session as last resort.
        claude_pid = Process.ppid.to_i64
        env_session_id = ENV[Resolver::ENV_SESSION_ID_KEY]?

        ledger_session_id = Resolver.resolve_session(
          claude_pid: claude_pid,
          env_session_id: env_session_id,
          stdin_session_id: stdin_session_identifier,
          create_if_missing: true,
          cwd: Dir.current,
        )

        return output_empty unless ledger_session_id && ledger_session_id > 0

        # Register the new stdin session_id against the existing session.
        # On /clear, Claude generates a new UUID — register it so it maps
        # to the same logical session.
        if stdin_id = stdin_session_identifier
          unless stdin_id.empty?
            Database.register_session_identifier(ledger_session_id, stdin_id)
            Database.update_session(ledger_session_id, session_identifier: stdin_id)
          end
        end

        # Notify Galaxy.app of the session identity change (fire-and-forget)
        if evt = event_name
          EventPublisher.publish(
            ledger_session_id: ledger_session_id,
            event: evt,
          )
        end

        # Wait for extraction subprocess to write enriched summary data.
        # Polls last_interaction in the DB for up to EXTRACTION_WAIT_TIMEOUT
        # seconds, checking for the most recent exchange's summary. Returns
        # immediately if summary is already present or no transcript available.
        await_extraction_summary(ledger_session_id, transcript_path)

        # Fetch session record for cwd/git_branch and last_interaction
        session_record = Database.get_session_by_id(ledger_session_id)

        # Query restoration data using the resolved ledger_session_id
        restoration = Database.query_for_restoration(ledger_session_id)
        files = Database.session_files(ledger_session_id)
        exchanges = extract_exchanges(session_record)

        # Query snapshot stats for budget-aware rendering
        snapshot_stats = query_snapshot_stats(ledger_session_id)

        # Query artifact count via standalone artifacts CLI
        artifact_count = query_artifact_count(ledger_session_id)

        # Build systemMessage and additionalContext
        system_message = Helpers.build_system_message(
          prefix: "Handoff",
          empty_message: "No previous context to hand off.",
          restoration: restoration,
          files: files,
          last_exchange: exchanges.last?,
          snapshot_count: snapshot_stats[:count],
          artifact_count: artifact_count,
        )

        context = build_additional_context(
          claude_pid: claude_pid,
          ledger_session_id: ledger_session_id,
          restoration: restoration,
          files: files,
          exchanges: exchanges,
          cwd: handoff_cwd(session_record),
          git_branch: session_record.try(&.git_branch),
          snapshot_stats: snapshot_stats,
          artifact_count: artifact_count,
        )

        # Enrich timeline event with full handoff data
        if tl_id = timeline_event_id
          enrich_timeline_event(
            tl_id,
            source: source,
            restoration: restoration,
            files: files,
            exchanges: exchanges,
            snapshot_stats: snapshot_stats,
            artifact_count: artifact_count,
            cwd: handoff_cwd(session_record),
            git_branch: session_record.try(&.git_branch),
            handoff_system_message: system_message,
            handoff_content: context,
          )
        end

        puts Helpers.output_json(system_message, context)
      end

      # Determines the working directory to report in the handoff.
      #
      # Preference chain:
      #   1. last_stop_cwd  — stamped by the Stop hook at end-of-turn, once
      #      per turn at a deterministic boundary.  Most reliable because it
      #      is not affected by async status line tick timing.
      #   2. previous_cwd   — saved by update_session_metrics (status line)
      #      before each cwd overwrite.  Rolling one-step buffer, can drift
      #      in multi-repo workflows where Claude cd's between directories.
      #   3. cwd column     — live value, may already reflect the post-reset
      #      project root if the status line fired after the reset.
      private def self.handoff_cwd(session_record : Database::SessionRecord?) : String?
        return nil unless session_record

        begin
          ctx = JSON.parse(session_record.context)

          # Prefer last_stop_cwd (stamped by Stop hook)
          if stop_cwd = ctx["last_stop_cwd"]?.try(&.as_s?)
            return stop_cwd unless stop_cwd.empty?
          end

          # Fall back to previous_cwd (stamped by status line)
          if prev = ctx["previous_cwd"]?.try(&.as_s?)
            return prev unless prev.empty?
          end
        rescue
        end

        session_record.cwd
      end

      private def self.extract_exchanges(session_record : Database::SessionRecord?) : Array(Exchange::LastExchange)
        return [] of Exchange::LastExchange unless session_record
        Exchange::LastExchange.from_json_flexible(session_record.last_interaction)
      end

      # Polls the DB for up to EXTRACTION_WAIT_TIMEOUT seconds, waiting
      # for the extraction subprocess to write a summary for the most
      # recent exchange. Returns immediately when:
      #   - no transcript_path provided
      #   - transcript can't be read or has no exchanges
      #   - last assistant response is older than the timeout (extraction
      #     has already had its full window)
      #   - summary data is already present in the DB
      #   - timeout is reached (graceful degradation)
      #
      # Uses a dynamic timeout based on the last assistant message
      # timestamp: if the response was N seconds ago, only polls for
      # (EXTRACTION_WAIT_TIMEOUT - N) more seconds. This avoids a
      # full 25s wait when /clear fires well after the response.
      #
      # NOTE: Matching is by exact user_message string equality. If the
      # user sends the exact same message on consecutive turns and /clear
      # fires before the extraction subprocess updates the DB, this could
      # match the previous turn's enriched exchange and return early.
      # Extremely unlikely in practice.
      private def self.await_extraction_summary(
        ledger_session_id : Int64,
        transcript_path : String?,
      )
        return unless transcript_path
        return unless File.exists?(transcript_path)

        # Read transcript to determine the expected user_message and
        # the last assistant response timestamp for dynamic timeout.
        # The user message is flushed before the Stop hook fires,
        # so it's reliably available when the clear hook runs.
        entries = Transcript.parse(transcript_path)
        recent = Transcript.extract_recent_exchanges(entries, limit: 1)
        return if recent.empty?

        last_exchange = recent.last
        expected_user_message = last_exchange.user_message
        return if expected_user_message.strip.empty?

        # Allow env var overrides for testing (avoids 25s wall-clock specs).
        # .to_i? returns nil on non-numeric input instead of raising.
        timeout = ENV["GALAXY_EXTRACTION_WAIT_TIMEOUT"]?.try(&.to_i?) || EXTRACTION_WAIT_TIMEOUT
        interval = ENV["GALAXY_EXTRACTION_POLL_INTERVAL"]?.try(&.to_i?) || EXTRACTION_POLL_INTERVAL
        interval = {interval, 1}.max # Guard against zero/negative → infinite loop

        # Dynamic timeout: use the last assistant message timestamp as the
        # reference point instead of hook start time. If the response was
        # >timeout seconds ago, the extraction subprocess has already had
        # its full window — skip polling entirely. If more recent, poll
        # only for the remaining time.
        remaining = timeout
        if last_entry = last_exchange.assistant_entries.last?
          if ts_str = last_entry.timestamp
            begin
              # Strip fractional seconds; parse as UTC.
              # Transcript timestamps: "2026-02-28T16:50:10.319Z"
              normalized = ts_str.gsub(/\.\d+/, "")
              response_time = Time.parse_utc(normalized, "%Y-%m-%dT%H:%M:%SZ")
              elapsed_since_response = (Time.utc - response_time).total_seconds.to_i
              remaining = {timeout - elapsed_since_response, 0}.max
            rescue ex
              STDERR.puts "[galaxy-ledger] await: failed to parse timestamp #{ts_str.inspect}: #{ex.message}"
              # Fall back to full timeout
            end
          end
        end

        return if remaining <= 0

        elapsed = 0
        loop do
          session_record = Database.get_session_by_id(ledger_session_id)
          if session_record
            exchanges = extract_exchanges(session_record)
            if last = exchanges.last?
              if last.user_message == expected_user_message && last.summary
                return # Full enriched data available
              end
            end
          end

          elapsed += interval
          break if elapsed > remaining

          sleep interval.seconds
        end

        # Timeout reached — proceed with whatever data is in DB
      end

      private def self.build_additional_context(
        claude_pid : Int64,
        ledger_session_id : Int64,
        restoration : Database::RestorationResult,
        files : Array(Database::SessionFile),
        exchanges : Array(Exchange::LastExchange),
        cwd : String? = nil,
        git_branch : String? = nil,
        snapshot_stats : NamedTuple(count: Int32, total_chars: Int64) = {count: 0, total_chars: 0_i64},
        artifact_count : Int32 = 0,
      ) : String
        lines = [] of String
        lines << "## Session Context Handoff"
        lines << ""
        lines << "**Ledger PID**: `#{claude_pid}`"
        if cwd_val = cwd
          lines << "**Working directory**: `#{Helpers.shorten_home_path(cwd_val)}`" unless cwd_val.empty?
        end
        if branch = git_branch
          lines << "**Git branch**: `#{branch}`" unless branch.empty?
        end
        lines << ""

        has_any_data = restoration.total_count > 0 || files.size > 0 || exchanges.any? || snapshot_stats[:count] > 0 || artifact_count > 0

        unless has_any_data
          lines << "No previous context available."
          lines << ""
          lines << "---"
          lines << "\u{1f4da} Search this session: `galaxy-ledger search --query \"QUERY\" --pid #{claude_pid}`"
          lines << "\u{1f4cb} List this session: `galaxy-ledger list-entries --pid #{claude_pid}`"
          return lines.join("\n")
        end

        # Orientation paragraph
        lines << "Your context was just reset. Everything below was captured during the"
        lines << "session before the reset. The user will continue interacting as if"
        lines << "the reset never happened \u2014 they expect you to have full awareness of"
        lines << "all progress, decisions, and context from this session."
        lines << ""
        lines << "The Claude session ID may change on /clear. The ledger tracks your"
        lines << "session by process ID."
        lines << ""

        # Required Reading — guideline files (from file types)
        guideline_files = files
          .select { |f| f.file_type == "guideline" }
          .map(&.file_path)
          .uniq
          .sort
        has_guidelines = guideline_files.any?

        if has_guidelines
          lines << "### Required Reading"
          lines << ""
          lines << "You MUST re-read every file below using the Read tool before"
          lines << "responding. Summaries and memory are not substitutes for reading"
          lines << "the source files \u2014 they contain rules, conventions, and constraints"
          lines << "you are expected to follow exactly."
          lines << ""
          guideline_files.each do |path|
            lines << "- `#{Helpers.shorten_home_path(path)}`"
          end
          lines << ""
        end

        # Proactive directives
        lines << "### Before Your Next Response"
        lines << ""
        if has_guidelines
          lines << "1. **Re-read all guideline files** listed in Required Reading above \u2014 this is not optional"
        else
          lines << "1. **Check for guideline files** in the session file manifest below"
        end
        lines << "2. **Check recent code changes**: `git diff` and `git log --oneline -20`"
        lines << "3. **Review the session file manifest** below \u2014 these are the"
        lines << "   files actively worked on this session"
        lines << ""

        # Fallback recovery directives
        lines << "If you hit something unfamiliar during the session:"
        lines << ""
        lines << "1. **Query the ledger**: `galaxy-ledger search --query \"QUERY\" --pid #{claude_pid}`"
        lines << "2. **Check session files**: `galaxy-ledger list-files --pid #{claude_pid}`"
        lines << "3. **Fall back to normal exploration** \u2014 Grep, Glob, Read as usual"

        # Implementation plans section — list by discovery order.
        # Deduplicate on file_path (same file can have multiple rows
        # if both Read and Grep'd — keep the earliest first_seen_at).
        impl_plan_files = files
          .select { |f| f.file_type == "implementation_plan" }
          .sort_by { |f| f.first_seen_at || "" }
          .uniq(&.file_path)
        has_impl_plans = impl_plan_files.any?

        if has_impl_plans
          lines << "---"
          lines << ""
          lines << "### Implementation Plans"
          lines << ""
          lines << "The following implementation plans were referenced this"
          lines << "session (oldest first):"
          lines << ""
          impl_plan_files.each_with_index do |f, idx|
            lines << "#{idx + 1}. `#{Helpers.shorten_home_path(f.file_path)}`"
          end
          lines << ""
        end

        # Last interaction / Recent activity section
        if exchanges.any?
          lines << "---"
          lines << ""

          if exchanges.size == 1
            lines << "### Last Interaction"
          else
            lines << "### Recent Activity (last #{exchanges.size} exchanges)"
          end
          lines << ""

          # Render in reverse-chronological order, numbered from most recent
          exchanges.reverse_each.with_index do |exchange, rev_idx|
            num = exchanges.size - rev_idx

            if exchanges.size > 1
              lines << "**#{num}.** " + render_exchange_header(exchange)
            else
              lines << render_exchange_header(exchange)
            end

            render_exchange_body(exchange, lines)
            lines << ""
          end
        end

        # Session snapshots section (budget-aware)
        if snapshot_stats[:count] > 0
          inline_char_cap = config_inline_char_cap

          lines << "---"
          lines << ""

          if snapshot_stats[:total_chars] <= inline_char_cap
            # Under budget — get full content via CLI
            snapshots_json = query_snapshots_with_content(
              ledger_session_id,
            )
            lines << "### Session Snapshots " \
                     "(#{snapshots_json.size} saved)"
            lines << ""
            snapshots_json.each do |snap|
              exchange_count = snap["exchange_count"].as_i
              exchange_label = exchange_count == 1 ? "exchange" : "exchanges"
              time_str = snap["created_at"].as_s
              lines << "**##{snap["number"].as_i} \u2014 " \
                       "\"#{snap["title"].as_s}\"** " \
                       "(#{exchange_count} #{exchange_label}, #{time_str})"
              lines << ""
              lines << snap["content"].as_s
              lines << ""
            end
          else
            # Over budget — metadata only with CLI query commands
            snapshots_json = query_snapshots_metadata(ledger_session_id)
            lines << "### Session Snapshots " \
                     "(#{snapshots_json.size} saved \u2014 " \
                     "query for full content)"
            lines << ""
            lines << "Snapshots exceed inline budget. Load individually:"
            snapshots_json.each do |snap|
              exchange_count = snap["exchange_count"].as_i
              exchange_label = exchange_count == 1 ? "exchange" : "exchanges"
              char_count = snap["char_count"].as_i
              chars_formatted = format_char_count(char_count)
              number = snap["number"].as_i
              lines << "- ##{number} \"#{snap["title"].as_s}\" " \
                       "(#{exchange_count} #{exchange_label}, " \
                       "#{chars_formatted} chars) \u2192"
              lines << "  `galaxy-snapshots view --pid #{claude_pid} " \
                       "#{number}`"
            end
            lines << ""
          end
        end

        # Session artifacts section (metadata only — files can be large/binary)
        if artifact_count > 0
          artifacts_json = query_artifacts_metadata(ledger_session_id)
          lines << "---"
          lines << ""
          lines << "### Session Artifacts (#{artifacts_json.size} saved)"
          lines << ""
          lines << "| # | Type | Title | Size |"
          lines << "|---|------|-------|------|"
          artifacts_json.each do |art|
            size_formatted = format_file_size(art["file_size"].as_i64)
            lines << "| #{art["number"].as_i} " \
                     "| #{art["artifact_type"].as_s} " \
                     "| #{art["title"].as_s} " \
                     "| #{size_formatted} |"
          end
          lines << ""
          lines << "View: `galaxy-artifacts view --pid #{claude_pid} N`"
          lines << "Open: `galaxy-artifacts open --pid #{claude_pid} N`"
          lines << ""
        end

        # Artifact capture directive — behavioral reminder so the agent
        # continues registering Bash-produced files after context reset.
        lines << "### Artifact Capture"
        lines << ""
        lines << "**Bash-created artifacts** (pandoc, mermaid-cli, python scripts,"
        lines << "curl downloads) need manual registration:"
        lines << ""
        lines << "    galaxy-artifacts save --pid #{claude_pid} \\\\"
        lines << "      --title \"Title\" --source-path /path/to/file \\\\"
        lines << "      --description \"Brief context\""
        lines << ""
        lines << "Do this silently after Bash commands that produce document files."
        lines << "Write tool artifacts are captured automatically."
        lines << ""

        # Key decisions section (high + medium, labeled)
        high_decisions = restoration.tier1.high_importance_decisions
        medium_decisions = restoration.tier2.medium_decisions
        if high_decisions.any? || medium_decisions.any?
          lines << "---"
          lines << ""
          lines << "### Key Decisions"
          lines << ""
          high_decisions.each do |entry|
            lines << "- #{entry.content} (high)"
          end
          medium_decisions.each do |entry|
            lines << "- #{entry.content} (medium)"
          end
          lines << ""
        end

        # Learnings section
        learnings = restoration.tier2.learnings
        if learnings.any?
          lines << "---"
          lines << ""
          lines << "### Recent Learnings"
          lines << ""
          # Chronological order (oldest first) — reverse since DB returns DESC
          learnings.reverse_each do |entry|
            lines << "- #{entry.content}"
          end
          lines << ""
        end

        # Session file manifest
        if files.any?
          edited_written = files.select { |f| f.is_edited || f.is_written }
          read_only = files.select { |f| f.is_read && !f.is_edited && !f.is_written && !f.is_searched }

          lines << "---"
          lines << ""
          lines << "### Session File Manifest"
          lines << ""

          if edited_written.any?
            lines << "**Edited/Written:**"
            edited_written.each do |f|
              lines << "- `#{Helpers.shorten_home_path(f.file_path)}`"
            end
            lines << ""
          end

          if read_only.any?
            capped = read_only.size > READ_ONLY_FILES_CAP
            display = capped ? read_only[0, READ_ONLY_FILES_CAP] : read_only
            lines << "**Read:**"
            display.each do |f|
              lines << "- `#{Helpers.shorten_home_path(f.file_path)}`"
            end
            if capped
              lines << "- *(#{read_only.size - READ_ONLY_FILES_CAP} more \u2014 run `galaxy-ledger list-files --pid #{claude_pid}` to see all)*"
            end
            lines << ""
          end
        end

        lines.join("\n")
      end

      # Render the header line for a single exchange (the "You asked" part).
      private def self.render_exchange_header(exchange : Exchange::LastExchange) : String
        if summary = exchange.summary
          "**You asked**: #{summary.user_request}"
        else
          "**You asked**: #{exchange.user_message}"
        end
      end

      # Render the body of a single exchange (accomplished, decisions, learnings).
      private def self.render_exchange_body(exchange : Exchange::LastExchange, lines : Array(String))
        if summary = exchange.summary
          lines << "**What was accomplished**: #{summary.assistant_response}"

          unless summary.key_actions.empty?
            lines << ""
            lines << "**Key actions**: #{summary.key_actions.join(", ")}"
          end

          if decisions = summary.decisions
            decisions.each do |d|
              line = "- Decision: #{d.choice} \u2014 rationale: #{d.rationale}"
              if alt = d.alternatives
                line += ". Alternative considered: #{alt}" unless alt.empty?
              end
              lines << line
            end
          end

          if learnings = summary.learnings
            learnings.each do |l|
              lines << "- Learning: #{l}"
            end
          end
        else
          preview = Helpers.truncate(exchange.full_content, 500)
          lines << "**What was accomplished**: #{preview}"
        end
      end

      # Format file size for display (e.g., 1024 -> "1.0k", 1048576 -> "1.0M")
      private def self.format_file_size(bytes : Int64) : String
        if bytes >= 1_048_576
          "#{"%.1f" % (bytes / 1_048_576.0)}M"
        elsif bytes >= 1024
          "#{"%.1f" % (bytes / 1024.0)}k"
        else
          "#{bytes}B"
        end
      end

      # Format char count for display (e.g., 3241 -> "3.2k", 150 -> "150")
      private def self.format_char_count(chars : Int32) : String
        if chars >= 1000
          "#{(chars / 1000.0).round(1)}k"
        else
          chars.to_s
        end
      end

      private def self.query_snapshot_stats(
        ledger_session_id : Int64,
      ) : NamedTuple(count: Int32, total_chars: Int64)
        snapshots_bin = (
          GalaxyLedger::GALAXY_DIR / "bin" / "galaxy-snapshots"
        ).to_s
        return {count: 0, total_chars: 0_i64} unless File.exists?(
                                                       snapshots_bin,
                                                     )

        output = IO::Memory.new
        status = Process.run(
          snapshots_bin,
          args: [
            "stats",
            "--ledger-session-id", ledger_session_id.to_s,
            "--json",
          ],
          output: output,
          error: Process::Redirect::Close,
        )
        return {count: 0, total_chars: 0_i64} unless status.success?

        json = JSON.parse(output.to_s)
        {
          count:       json["count"].as_i,
          total_chars: json["total_chars"].as_i64,
        }
      rescue
        {count: 0, total_chars: 0_i64}
      end

      private def self.query_snapshots_with_content(
        ledger_session_id : Int64,
      ) : Array(JSON::Any)
        snapshots_bin = (
          GalaxyLedger::GALAXY_DIR / "bin" / "galaxy-snapshots"
        ).to_s

        output = IO::Memory.new
        status = Process.run(
          snapshots_bin,
          args: [
            "list",
            "--ledger-session-id", ledger_session_id.to_s,
            "--json",
            "--content",
          ],
          output: output,
          error: Process::Redirect::Close,
        )
        return [] of JSON::Any unless status.success?

        json = JSON.parse(output.to_s)
        json["snapshots"].as_a
      rescue
        [] of JSON::Any
      end

      private def self.query_snapshots_metadata(
        ledger_session_id : Int64,
      ) : Array(JSON::Any)
        snapshots_bin = (
          GalaxyLedger::GALAXY_DIR / "bin" / "galaxy-snapshots"
        ).to_s

        output = IO::Memory.new
        status = Process.run(
          snapshots_bin,
          args: [
            "list",
            "--ledger-session-id", ledger_session_id.to_s,
            "--json",
          ],
          output: output,
          error: Process::Redirect::Close,
        )
        return [] of JSON::Any unless status.success?

        json = JSON.parse(output.to_s)
        json["snapshots"].as_a
      rescue
        [] of JSON::Any
      end

      # Read inline_char_cap from snapshots tool's config
      private def self.config_inline_char_cap : Int32
        snapshots_config = GalaxyLedger::GALAXY_DIR / "snapshots" /
                           "config.json"
        if File.exists?(snapshots_config)
          json = JSON.parse(File.read(snapshots_config))
          json["inline_char_cap"]?.try(&.as_i?) || 15000
        else
          15000
        end
      rescue
        15000
      end

      private def self.query_artifact_count(
        ledger_session_id : Int64,
      ) : Int32
        artifacts_bin = (
          GalaxyLedger::GALAXY_DIR / "bin" / "galaxy-artifacts"
        ).to_s
        return 0 unless File.exists?(artifacts_bin)

        output = IO::Memory.new
        status = Process.run(
          artifacts_bin,
          args: [
            "stats",
            "--ledger-session-id", ledger_session_id.to_s,
            "--json",
          ],
          output: output,
          error: Process::Redirect::Close,
        )
        return 0 unless status.success?

        json = JSON.parse(output.to_s)
        json["count"].as_i
      rescue
        0
      end

      private def self.query_artifacts_metadata(
        ledger_session_id : Int64,
      ) : Array(JSON::Any)
        artifacts_bin = (
          GalaxyLedger::GALAXY_DIR / "bin" / "galaxy-artifacts"
        ).to_s

        output = IO::Memory.new
        status = Process.run(
          artifacts_bin,
          args: [
            "list",
            "--ledger-session-id", ledger_session_id.to_s,
            "--json",
          ],
          output: output,
          error: Process::Redirect::Close,
        )
        return [] of JSON::Any unless status.success?

        json = JSON.parse(output.to_s)
        json["artifacts"].as_a
      rescue
        [] of JSON::Any
      end

      private def self.enrich_timeline_event(
        event_id : Int64,
        source : String?,
        restoration : Database::RestorationResult,
        files : Array(Database::SessionFile),
        exchanges : Array(Exchange::LastExchange),
        snapshot_stats : NamedTuple(
          count: Int32, total_chars: Int64,
        ),
        artifact_count : Int32,
        cwd : String?,
        git_branch : String?,
        handoff_system_message : String,
        handoff_content : String,
      )
        edited = files.count { |f|
          f.is_edited || f.is_written
        }
        read_only = files.count { |f|
          f.is_read && !f.is_edited &&
            !f.is_written && !f.is_searched
        }
        decisions = restoration.tier1
          .high_importance_decisions.size +
                    restoration.tier2.medium_decisions.size
        learnings = restoration.tier2.learnings.size

        enriched = {
          source:                 source,
          cwd:                    cwd,
          git_branch:             git_branch,
          decisions_count:        decisions,
          learnings_count:        learnings,
          files_edited_count:     edited,
          files_read_count:       read_only,
          exchanges_count:        exchanges.size,
          snapshot_count:         snapshot_stats[:count],
          snapshot_total_chars:   snapshot_stats[:total_chars],
          artifact_count:         artifact_count,
          handoff_system_message: handoff_system_message,
          handoff_content:        handoff_content,
        }.to_json

        # Fire-and-forget update via stdin to avoid arg
        # length limits (handoff_content can be 8-10KB+)
        begin
          Process.new(
            "galaxy-timeline",
            args: [
              "update",
              event_id.to_s,
              "--detail-data-stdin",
            ],
            input: IO::Memory.new(enriched),
            output: Process::Redirect::Close,
            error: Process::Redirect::Close,
          )
        rescue
          # Best-effort — enrichment failure is not fatal
        end
      end

      private def self.output_empty
        puts Helpers.output_json(
          "Handoff \u2502 No previous context to hand off.",
          ""
        )
      end
    end
  end
end
