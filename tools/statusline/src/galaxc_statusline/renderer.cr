module GalaxcStatusline
  class Renderer
    SEPARATOR    = " | "
    FILLED_BLOCK = "█"
    EMPTY_BLOCK  = "░"

    # TIOCGWINSZ ioctl constant for macOS
    TIOCGWINSZ = 0x40087468_u64

    @[Link("c")]
    lib TerminalLib
      struct Winsize
        ws_row : UInt16
        ws_col : UInt16
        ws_xpixel : UInt16
        ws_ypixel : UInt16
      end

      fun ioctl(fd : Int32, request : UInt64, ...) : Int32
    end

    @input : ClaudeInput
    @config : Config
    @git : Git
    @terminal_width : Int32
    @max_status_width : Int32

    def initialize(@input : ClaudeInput, @config : Config)
      @git = Git.new(@input.current_directory)
      @terminal_width = get_terminal_width
      @max_status_width = @terminal_width // 2  # Half of terminal, rounded down
    end

    def render : String
      # Priority order for fitting (shrink first → last):
      # 1. Context bar (shrink to min)
      # 2. Cost (drop)
      # 3. Model (drop)
      # 4. Directory (shrink: full → abbreviated → basename → drop)
      # 5. Git (drop - last resort)

      # Get base content
      dir_full = render_directory_full
      git_part = render_git
      model_part = render_model
      cost_part = render_cost

      # Calculate fixed widths
      dir_full_width = strip_ansi(dir_full).size
      git_width = strip_ansi(git_part).size
      model_width = strip_ansi(model_part).size
      cost_width = strip_ansi(cost_part).size

      # Start with max context bar and all components
      bar_width = @config.layout.context_bar_max_width
      min_bar_width = @config.layout.context_bar_min_width
      include_cost = @config.layout.show_cost && !cost_part.empty?
      include_model = @config.layout.show_model && !model_part.empty?
      include_git = @git.in_git_repo? && !git_part.empty?

      # Calculate what directory display to use
      dir_display = dir_full
      dir_width = dir_full_width

      # Iteratively shrink to fit
      loop do
        total = calculate_total_width(
          dir_width: dir_width,
          git_width: include_git ? git_width : 0,
          model_width: include_model ? model_width : 0,
          bar_width: bar_width,
          cost_width: include_cost ? cost_width : 0,
        )

        break if total <= @max_status_width

        # Step 1: Shrink context bar
        if bar_width > min_bar_width
          bar_width -= 1
          next
        end

        # Step 2: Drop cost
        if include_cost
          include_cost = false
          next
        end

        # Step 3: Drop model
        if include_model
          include_model = false
          next
        end

        # Step 4: Shrink directory
        if dir_width > 0
          # Try abbreviated
          abbrev = render_directory_abbreviated
          abbrev_width = strip_ansi(abbrev).size
          if dir_width > abbrev_width && abbrev_width > 0
            dir_display = abbrev
            dir_width = abbrev_width
            next
          end

          # Try basename
          base = render_directory_basename
          base_width = strip_ansi(base).size
          if dir_width > base_width && base_width > 0
            dir_display = base
            dir_width = base_width
            next
          end

          # Drop directory entirely
          dir_display = ""
          dir_width = 0
          next
        end

        # Step 5: Drop git (last resort)
        if include_git
          include_git = false
          next
        end

        # Nothing left to shrink
        break
      end

      # Build final output
      parts = [] of String

      # Left side: directory + git (no separator between them)
      left_side = ""
      left_side += dir_display unless dir_display.empty?
      left_side += git_part if include_git
      parts << left_side unless left_side.empty?

      # Right side: model, context bar, cost
      parts << model_part if include_model
      parts << render_context_bar(bar_width)
      parts << cost_part if include_cost

      parts.join(SEPARATOR)
    end

    private def calculate_total_width(
      dir_width : Int32,
      git_width : Int32,
      model_width : Int32,
      bar_width : Int32,
      cost_width : Int32,
    ) : Int32
      # Context bar width = bar chars + space + percentage (e.g., "100%")
      context_width = bar_width + 1 + 4  # " 100%" = 5 chars max

      parts_count = 0
      total = 0

      # Directory + git are combined (no separator between them)
      left_width = dir_width + git_width
      if left_width > 0
        total += left_width
        parts_count += 1
      end

      if model_width > 0
        total += model_width
        parts_count += 1
      end

      total += context_width
      parts_count += 1

      if cost_width > 0
        total += cost_width
        parts_count += 1
      end

      # Add separators
      total += (parts_count - 1) * SEPARATOR.size if parts_count > 1

      total
    end

    private def render_directory_full : String
      dir = @input.current_directory
      return "" unless dir

      home = Path.home.to_s
      display_dir = dir.starts_with?(home) ? dir.sub(home, "~") : dir

      Colors.colorize(display_dir, @config.colors.directory)
    end

    private def render_directory_abbreviated : String
      dir = @input.current_directory
      return "" unless dir

      home = Path.home.to_s
      display_dir = dir.starts_with?(home) ? dir.sub(home, "~") : dir

      abbrev = abbreviate_path(display_dir)
      Colors.colorize(abbrev, @config.colors.directory)
    end

    private def render_directory_basename : String
      dir = @input.current_directory
      return "" unless dir

      base = File.basename(dir)
      Colors.colorize(base, @config.colors.directory)
    end

    private def abbreviate_path(path : String) : String
      parts = path.split("/")
      return path if parts.size <= 2

      # Keep first char of each component except last
      abbreviated = parts[0..-2].map { |p| p.empty? ? "" : p[0].to_s }
      abbreviated << parts.last

      abbreviated.join("/")
    end

    private def render_git : String
      return "" unless @git.in_git_repo?

      branch = @git.branch
      return "" unless branch

      case @config.branch_style
      when "symbolic"
        render_symbolic_branch(branch)
      when "arrows"
        render_arrows_branch(branch)
      when "minimal"
        render_minimal_branch(branch)
      else
        render_symbolic_branch(branch)
      end
    end

    private def render_symbolic_branch(branch : String) : String
      status = ""

      # Upstream status
      if @git.behind > 0 && @git.ahead > 0
        status += Colors.colorize("<>", @config.colors.upstream_behind)
      elsif @git.behind > 0
        status += Colors.colorize("<", @config.colors.upstream_behind)
      elsif @git.ahead > 0
        status += Colors.colorize(">", @config.colors.upstream_ahead)
      else
        status += Colors.colorize("=", @config.colors.upstream_synced)
      end

      # Working tree status
      if @git.dirty
        status += Colors.colorize("*", @config.colors.dirty)
      end
      if @git.staged
        status += Colors.colorize("+", @config.colors.staged)
      end
      if @git.stashed
        status += Colors.colorize("^", @config.colors.stashed)
      end

      colored_branch = Colors.colorize(branch, @config.colors.branch)
      "[#{colored_branch}#{status}]"
    end

    private def render_arrows_branch(branch : String) : String
      parts = [Colors.colorize(branch, @config.colors.branch)]

      if @git.ahead > 0
        parts << Colors.colorize("↑#{@git.ahead}", @config.colors.upstream_ahead)
      end
      if @git.behind > 0
        parts << Colors.colorize("↓#{@git.behind}", @config.colors.upstream_behind)
      end
      if @git.synced? && @git.ahead == 0 && @git.behind == 0
        # Check if we have upstream tracking
        parts << Colors.colorize("✓", @config.colors.upstream_synced)
      end

      if @git.dirty
        parts << Colors.colorize("*", @config.colors.dirty)
      end

      "[#{parts.join}]"
    end

    private def render_minimal_branch(branch : String) : String
      colored_branch = Colors.colorize(branch, @config.colors.branch)
      inner = if @git.dirty || @git.staged
                colored_branch + Colors.colorize("*", @config.colors.dirty)
              else
                colored_branch
              end
      "[#{inner}]"
    end

    private def render_context_bar(bar_width : Int32) : String
      percentage = @input.context_percentage || 0.0

      # Determine color based on thresholds
      color = if percentage >= @config.context_thresholds.critical
                @config.colors.context_critical
              elsif percentage >= @config.context_thresholds.warning
                @config.colors.context_warning
              else
                @config.colors.context_normal
              end

      # Render bar
      filled = ((percentage / 100.0) * bar_width).round.to_i
      filled = filled.clamp(0, bar_width)
      empty = bar_width - filled

      bar = FILLED_BLOCK * filled + EMPTY_BLOCK * empty
      colored_bar = Colors.colorize(bar, color)

      # Format percentage
      pct_str = "#{percentage.round.to_i}%"
      colored_pct = Colors.colorize(pct_str, color)

      "#{colored_bar} #{colored_pct}"
    end

    private def render_model : String
      name = @input.model_name
      return "" unless name

      # Truncate if narrow
      display_name = if @terminal_width < 80 && name.size > 3
                       name[0, 3]
                     else
                       name
                     end

      Colors.colorize(display_name, @config.colors.model)
    end

    private def render_cost : String
      cost = @input.total_cost
      return "" unless cost

      # Format as currency
      formatted = "$#{sprintf("%.2f", cost)}"
      Colors.colorize(formatted, @config.colors.cost)
    end

    private def get_terminal_width : Int32
      # Open /dev/tty directly to get terminal width
      # This works even when stdin/stdout/stderr are all piped
      begin
        File.open("/dev/tty", "r") do |tty|
          ws = TerminalLib::Winsize.new
          result = TerminalLib.ioctl(tty.fd, TIOCGWINSZ, pointerof(ws))
          if result == 0 && ws.ws_col > 0
            return ws.ws_col.to_i32
          end
        end
      rescue
        # /dev/tty not available
      end
      80  # Fallback
    end

    private def strip_ansi(text : String) : String
      text.gsub(/\e\[[0-9;]*m/, "")
    end
  end
end
