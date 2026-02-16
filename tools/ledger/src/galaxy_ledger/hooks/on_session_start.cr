require "json"

module GalaxyLedger
  module Hooks
    # Handles the SessionStart(clear|compact) hook — RESOLVE MODE
    #
    # This hook is RESOLVE-ONLY — it resolves the original session by
    # Claude Code PID. All data accumulates under the one session record
    # created by on_startup for the entire life of the Claude Code process,
    # regardless of how many /clears happen.
    #
    # On /clear, Claude generates a new session_id. This hook registers that
    # new identifier in the mapping table and updates the session's
    # current_session_identifier, maintaining continuity.
    #
    # - Resolves session by PID (Process.ppid) → ledger_session_id
    # - Registers the new stdin session_id against the resolved session
    # - Queries tiered restoration data from SQLite using ledger_session_id
    # - Builds systemMessage status line for user display
    # - Returns additionalContext with full handoff markdown for agent restoration
    class OnSessionStart
      @stdin_session_identifier : String?
      @source : String?

      # Read-only cap on session files in the manifest
      READ_ONLY_FILES_CAP = 15

      def run
        # Skip if GALAXY_SKIP_HOOKS is set (prevents recursion from extraction subprocesses)
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        # Parse hook input from stdin
        parse_hook_input

        # Resolve session via 3-tier chain (PID → env var → hook session_id),
        # creating a new session as last resort.
        claude_pid = Process.ppid.to_i64
        env_session_id = ENV[Resolver::ENV_SESSION_ID_KEY]?

        ledger_session_id = Resolver.resolve_session(
          claude_pid: claude_pid,
          env_session_id: env_session_id,
          stdin_session_id: @stdin_session_identifier,
          create_if_missing: true,
          cwd: Dir.current,
        )

        return output_empty unless ledger_session_id && ledger_session_id > 0

        # Register the new stdin session_id against the existing session.
        # On /clear, Claude generates a new UUID — register it so it maps
        # to the same logical session.
        if stdin_id = @stdin_session_identifier
          unless stdin_id.empty?
            Database.register_session_identifier(ledger_session_id, stdin_id)
            Database.update_session(ledger_session_id, session_identifier: stdin_id)
          end
        end

        # Query restoration data using the resolved ledger_session_id
        restoration = Database.query_for_restoration(ledger_session_id)
        files = Database.session_files(ledger_session_id)
        last_exchange = read_last_exchange_from_db(ledger_session_id)

        # Build systemMessage and additionalContext
        system_message = Helpers.build_system_message(
          prefix: "Handoff",
          empty_message: "No previous context to hand off.",
          restoration: restoration,
          files: files,
          last_exchange: last_exchange,
        )

        context = build_additional_context(
          claude_pid: claude_pid,
          restoration: restoration,
          files: files,
          last_exchange: last_exchange,
        )

        puts Helpers.output_json(system_message, context)
      end

      private def parse_hook_input
        begin
          input = STDIN.gets_to_end
          return if input.empty?

          json = JSON.parse(input)
          @stdin_session_identifier = json["session_id"]?.try(&.as_s?)
          @source = json["source"]?.try(&.as_s?)
        rescue
          # Silently ignore parse errors
        end
      end

      private def read_last_exchange_from_db(ledger_session_id : Int64) : Exchange::LastExchange?
        session_record = Database.get_session_by_id(ledger_session_id)
        return nil unless session_record

        json_str = session_record.last_interaction
        return nil unless json_str

        begin
          Exchange::LastExchange.from_json(json_str)
        rescue
          nil
        end
      end

      private def build_additional_context(
        claude_pid : Int64,
        restoration : Database::RestorationResult,
        files : Array(Database::SessionFile),
        last_exchange : Exchange::LastExchange?,
      ) : String
        lines = [] of String
        lines << "## Session Context Handoff"
        lines << ""
        lines << "**Ledger PID**: `#{claude_pid}`"
        lines << ""

        has_any_data = restoration.total_count > 0 || files.size > 0 || last_exchange

        unless has_any_data
          lines << "No previous context available."
          lines << ""
          lines << "---"
          lines << "\u{1f4da} Search this session: `galaxy-ledger search --query \"QUERY\" --pid #{claude_pid}`"
          lines << "\u{1f4cb} List this session: `galaxy-ledger list --pid #{claude_pid}`"
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

        # Recovery directives
        lines << "When the user references something you don't recognize or something"
        lines << "doesn't make sense:"
        lines << ""
        lines << "1. **Query the ledger**: `galaxy-ledger search --query \"QUERY\" --pid #{claude_pid}`"
        lines << "2. **Check recent code changes**: `git diff` and `git log --oneline -20`"
        lines << "3. **Review the session file manifest** listed below \u2014 these are the"
        lines << "   files actively worked on this session; start searches here before"
        lines << "   going broader"
        lines << "4. **Check session files**: if a file isn't in the manifest below, run"
        lines << "   `galaxy-ledger list-files --pid #{claude_pid}` to see every"
        lines << "   file read, edited, written, or searched this session"
        lines << "5. **Fall back to normal exploration** \u2014 Grep, Glob, Read as usual"

        # Guidelines section
        guidelines = restoration.tier1.guidelines
        if guidelines.any?
          lines << ""
          lines << "---"
          lines << ""
          lines << "### Guidelines Active This Session"
          lines << ""
          grouped = Helpers.group_entries_by_source_file(guidelines)
          grouped.each do |source_file, entries|
            lines << "**#{Helpers.shorten_home_path(source_file)}**"
            entries.each do |entry|
              lines << "- #{entry.content}"
            end
            lines << ""
          end
        end

        # Implementation plans section
        impl_plans = restoration.tier1.implementation_plans
        if impl_plans.any?
          lines << "---"
          lines << ""
          lines << "### Implementation Plans"
          lines << ""
          grouped = Helpers.group_entries_by_source_file(impl_plans)
          grouped.each do |source_file, entries|
            lines << "**#{Helpers.shorten_home_path(source_file)}**"
            entries.each do |entry|
              lines << "- #{entry.content}"
            end
            lines << ""
          end
        end

        # Last interaction section
        if last_exchange
          lines << "---"
          lines << ""
          lines << "### Last Interaction"
          lines << ""

          if summary = last_exchange.summary
            lines << "**You asked**: #{summary.user_request}"
            lines << ""
            lines << "**What was accomplished**: #{summary.assistant_response}"

            unless summary.files_modified.empty?
              lines << ""
              lines << "**Files modified**: #{summary.files_modified.join(", ")}"
            end

            unless summary.key_actions.empty?
              lines << ""
              lines << "**Key actions**: #{summary.key_actions.join(", ")}"
            end
          else
            lines << "**You asked**: #{last_exchange.user_message}"
            lines << ""
            preview = Helpers.truncate(last_exchange.full_content, 500)
            lines << "**What was accomplished**: #{preview}"
          end
          lines << ""
        end

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

      private def output_empty
        puts Helpers.output_json(
          "Handoff \u2502 No previous context to hand off.",
          ""
        )
      end
    end
  end
end
