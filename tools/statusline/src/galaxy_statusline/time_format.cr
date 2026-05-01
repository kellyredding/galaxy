module GalaxyStatusline
  # Wrapper around Time#to_s that pre-expands a small set of
  # strftime directives Crystal's stdlib does not support
  # natively. Mirrors Ruby's Time#strftime semantics so the
  # `layout.time_format` config value behaves the way most
  # users expect from `date(1)` or Ruby.
  #
  # Supported extensions (none are recognized by Crystal alone):
  #
  #   %-I   unpadded hour, 12-hour clock (1..12)
  #   %-l   unpadded hour, 12-hour clock (BSD alias for %-I)
  #   %-H   unpadded hour, 24-hour clock (0..23)
  #   %-M   unpadded minute
  #   %-S   unpadded second
  #   %-d   unpadded day of month
  #   %-m   unpadded month
  #   %^p   uppercase meridiem (AM/PM) — Ruby standard
  #   %P    uppercase meridiem (AM/PM) — date(1) standard
  #
  # All other directives pass through to Crystal's Time#to_s.
  module TimeFormat
    def self.format(time : Time, fmt : String) : String
      hour_12 = time.hour % 12
      hour_12 = 12 if hour_12 == 0
      ampm = time.hour < 12 ? "AM" : "PM"

      expanded = fmt
        .gsub("%-I", hour_12.to_s)
        .gsub("%-l", hour_12.to_s)
        .gsub("%-H", time.hour.to_s)
        .gsub("%-M", time.minute.to_s)
        .gsub("%-S", time.second.to_s)
        .gsub("%-d", time.day.to_s)
        .gsub("%-m", time.month.to_s)
        .gsub("%^p", ampm)
        .gsub("%P", ampm)

      time.to_s(expanded)
    end
  end
end
