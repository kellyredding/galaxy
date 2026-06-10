module GalaxyLedger
  # Single source of truth for "what day is it" when attributing cost and
  # token usage to a daily bucket.
  #
  # Uses local time so a day's spend lands on the calendar day the work was
  # actually done in the user's timezone, rather than the UTC day. This
  # matches the rest of the galaxy toolkit (timeline, artifacts, snapshots
  # all bucket by local day) and keeps the daily totals intuitive for
  # someone reviewing their own usage.
  #
  # The GALAXY_LEDGER_TODAY override (a YYYY-MM-DD string) pins the current
  # day for deterministic tests of both the recording and reporting paths.
  module LedgerTime
    # Current moment for day-attribution, as a local Time — or midnight of
    # the GALAXY_LEDGER_TODAY override date when that env var is set.
    def self.now : Time
      if override = ENV["GALAXY_LEDGER_TODAY"]?
        Time.parse(override, "%Y-%m-%d", Time::Location.local)
      else
        Time.local
      end
    end

    # Current day key (YYYY-MM-DD) that cost and tokens are attributed to.
    def self.today_str : String
      now.to_s("%Y-%m-%d")
    end
  end
end
