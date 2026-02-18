module GalaxyLedger
  # Terminal chart rendering utilities for the spend subcommand.
  # Provides sparkline and horizontal bar chart output using Unicode block characters.
  module Chart
    # Unicode block characters for sparklines (8 levels, low to high)
    SPARK_BLOCKS = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█']

    # Bar chart fill characters
    BAR_FILLED = '█'
    BAR_EMPTY  = '░'

    # Render a sparkline from an array of values.
    # Maps each value to one of 8 block characters proportional to the max.
    # Returns a single-line string.
    def self.sparkline(values : Array(Float64)) : String
      return "" if values.empty?

      max = values.max
      return SPARK_BLOCKS[0].to_s * values.size if max <= 0.0

      String.build do |s|
        values.each do |v|
          # Map value to 0..7 index
          idx = ((v / max) * 7).round.to_i.clamp(0, 7)
          s << SPARK_BLOCKS[idx]
        end
      end
    end

    # A row for the bar chart
    struct BarRow
      getter label : String
      getter value : Float64
      getter extra : String

      def initialize(@label, @value, @extra = "")
      end
    end

    # Render a horizontal bar chart.
    # Each row gets a label, a proportional bar, and right-aligned value + extra columns.
    # Returns a multi-line string.
    def self.bar_chart(
      rows : Array(BarRow),
      bar_width : Int32 = 20,
    ) : String
      return "" if rows.empty?

      max_val = rows.max_of(&.value)
      peak_idx = rows.index { |r| r.value == max_val && max_val > 0 }

      # Find max label width for alignment
      max_label = rows.max_of(&.label.size)

      String.build do |s|
        rows.each_with_index do |row, idx|
          # Left-pad label
          label = row.label.ljust(max_label)

          if row.value <= 0.0 && max_val > 0.0
            bar = BAR_EMPTY.to_s * bar_width
            value_str = "  —"
          else
            # Calculate filled portion
            filled = if max_val > 0.0
                       ((row.value / max_val) * bar_width).round.to_i.clamp(0, bar_width)
                     else
                       0
                     end
            empty = bar_width - filled
            bar = BAR_FILLED.to_s * filled + BAR_EMPTY.to_s * empty
            value_str = row.extra.empty? ? "" : row.extra
          end

          line = "  #{label}  #{bar}"
          line += "  #{value_str}" unless value_str.empty?

          # Mark peak
          if idx == peak_idx && rows.size > 1
            line += "   ← peak"
          end

          s << line
          s << "\n" unless idx == rows.size - 1
        end
      end
    end

    # Format a cost value for display
    def self.format_cost(value : Float64) : String
      if value > 0.0
        "$#{"%.2f" % value}"
      else
        "$0.00"
      end
    end

    # Format a token count in compact notation (156.8k, 6.4M)
    def self.format_tokens(tokens : Int64) : String
      if tokens >= 1_000_000
        "#{"%.1f" % (tokens / 1_000_000.0)}M tok"
      elsif tokens >= 1_000
        "#{"%.1f" % (tokens / 1_000.0)}k tok"
      else
        "#{tokens} tok"
      end
    end
  end
end
