require "json"

module GalaxyLedger
  module Hooks
    # Handles the Notification hook, matched on `idle_prompt` — the agent
    # reporting that it is waiting for input.
    #
    # ### Why this exists
    #
    # A turn ends three ways and only two of them announce it. `Stop` and
    # `StopFailure` each fire a hook; **an abort fires nothing at all** — the
    # query loop returns before the Stop dispatcher, verified from the agent's
    # own binary. Galaxy compensates by watching for the Escape keystroke, but
    # a keystroke says a turn was *asked* to stop, not that the agent has
    # finished unwinding and can read again. Writing into that window loses the
    # write: measured at 125 bytes and a submit chord reaching a transcript as
    # nothing at all.
    #
    # This is the only report that the window has closed, and it comes from the
    # agent rather than from a guess about a keystroke.
    #
    # ### Why it is a backstop rather than the answer
    #
    # Claude Code gates the notification behind its own idle threshold — 60
    # seconds by default, and suppressed entirely if the user touches anything
    # in that window. So the normal recovery is the queue's own retry, which
    # resolves an abort in about two seconds. This catches the reader who
    # aborted and walked away, where nothing else ever would.
    #
    # ### Why a socket event rather than a timeline row
    #
    # Idleness is operational and has no history worth keeping — the same
    # reasoning that keeps `session.metrics` off the timeline. A row per
    # abandoned session would be noise in every view that reads the timeline.
    class OnIdle
      @stdin_session_identifier : String?
      @notification_type : String?

      # The notification the agent sends when it is waiting for input. Asserted
      # here as well as declared as the installed matcher: a `Notification`
      # hook that lost its matcher would start reporting permission prompts as
      # idleness, which is the opposite fact, and nothing would say so.
      IDLE_NOTIFICATION = "idle_prompt"

      def run
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        parse_hook_input

        kind = @notification_type
        return if kind && kind != IDLE_NOTIFICATION

        claude_pid = Process.ppid.to_i64
        env_session_id = ENV[Resolver::ENV_SESSION_ID_KEY]?

        ledger_session_id = Resolver.resolve_session(
          claude_pid: claude_pid,
          env_session_id: env_session_id,
          stdin_session_id: @stdin_session_identifier,
        )
        return unless ledger_session_id

        session_record = Database.get_session_by_id(ledger_session_id)
        current_sid = session_record
          .try(&.current_session_identifier) ||
                      @stdin_session_identifier
        return unless current_sid

        stdin_sid = @stdin_session_identifier
        return unless stdin_sid

        # Filter: session_id must match the ledger's current session
        # identifier, so an extraction sub-session going idle — which they all
        # do, being short-lived one-shots — is not reported as this session's
        # agent waiting for input.
        return unless stdin_sid == current_sid

        EventPublisher.publish(
          ledger_session_id: ledger_session_id,
          event: "session.idle",
        )
      rescue
        # Silent: a hook must never disrupt the session.
      end

      private def parse_hook_input
        input = STDIN.gets_to_end
        return if input.empty?

        json = JSON.parse(input)
        @stdin_session_identifier = json["session_id"]?.try(&.as_s?)
        @notification_type = json["notification_type"]?.try(&.as_s?)
      rescue
        # Silently ignore parse errors
      end
    end
  end
end
