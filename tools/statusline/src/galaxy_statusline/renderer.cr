module GalaxyStatusline
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
      fun getppid : Int32
      fun getsid(pid : Int32) : Int32
    end

    @input : ClaudeInput
    @config : Config
    @git : Git
    @terminal_width : Int32
    @max_status_width : Int32

    def initialize(@input : ClaudeInput, @config : Config)
      @git = Git.new(@input.current_directory)
      @terminal_width = get_terminal_width
      @max_status_width = @terminal_width // 2 # Half of terminal, rounded down
    end

    # Expose git branch for external consumers (e.g., ledger metrics)
    def git_branch : String?
      @git.branch
    end

    def render : String
      # Two-line layout, each line independently caps at @max_status_width:
      #   Line 1 (location): directory + git
      #   Line 2 (session):  model | context_bar | cost
      location = render_location_line
      session = render_session_line
      "#{location}\n#{session}"
    end

    # Line 1: directory + git (concatenated, no separator)
    # Shrink order: full dir → abbreviated → basename → drop dir → drop git
    private def render_location_line : String
      dir_full = render_directory_full
      git_part = render_git

      dir_display = dir_full
      dir_width = strip_ansi(dir_full).size
      git_width = strip_ansi(git_part).size
      include_git = @git.in_git_repo? && !git_part.empty?

      loop do
        total = dir_width + (include_git ? git_width : 0)
        break if total <= @max_status_width

        # Shrink directory
        if dir_width > 0
          abbrev = render_directory_abbreviated
          abbrev_width = strip_ansi(abbrev).size
          if dir_width > abbrev_width && abbrev_width > 0
            dir_display = abbrev
            dir_width = abbrev_width
            next
          end

          base = render_directory_basename
          base_width = strip_ansi(base).size
          if dir_width > base_width && base_width > 0
            dir_display = base
            dir_width = base_width
            next
          end

          dir_display = ""
          dir_width = 0
          next
        end

        # Drop git (last resort)
        if include_git
          include_git = false
          next
        end

        break
      end

      result = ""
      result += dir_display unless dir_display.empty?
      result += git_part if include_git
      result
    end

    # Line 2: model | context_bar | cost | time (joined with separator)
    # Shrink order: shrink context bar → drop time → drop cost → drop model
    private def render_session_line : String
      model_part = render_model
      cost_part = render_cost
      time_part = render_time

      model_width = strip_ansi(model_part).size
      cost_width = strip_ansi(cost_part).size
      time_width = strip_ansi(time_part).size

      bar_width = @config.layout.context_bar_max_width
      min_bar_width = @config.layout.context_bar_min_width
      include_cost = @config.layout.show_cost && !cost_part.empty?
      include_model = @config.layout.show_model && !model_part.empty?
      include_time = @config.layout.show_time && !time_part.empty?

      loop do
        total = calculate_session_line_width(
          model_width: include_model ? model_width : 0,
          bar_width: bar_width,
          cost_width: include_cost ? cost_width : 0,
          time_width: include_time ? time_width : 0,
        )

        break if total <= @max_status_width

        # Shrink context bar
        if bar_width > min_bar_width
          bar_width -= 1
          next
        end

        # Drop time (first, so cost survives longer)
        if include_time
          include_time = false
          next
        end

        # Drop cost
        if include_cost
          include_cost = false
          next
        end

        # Drop model
        if include_model
          include_model = false
          next
        end

        break
      end

      parts = [] of String
      parts << model_part if include_model
      parts << render_context_bar(bar_width)
      parts << cost_part if include_cost
      parts << time_part if include_time
      parts.join(SEPARATOR)
    end

    private def calculate_session_line_width(
      model_width : Int32,
      bar_width : Int32,
      cost_width : Int32,
      time_width : Int32,
    ) : Int32
      context_width = bar_width + 1 + 4 # " 100%" = 5 chars max

      parts_count = 0
      total = 0

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

      if time_width > 0
        total += time_width
        parts_count += 1
      end

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
      # Order matches PS1: branch, stash, upstream, staged, dirty
      status = ""

      if @git.stashed
        status += Colors.colorize("^", @config.colors.stashed)
      end

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

      if @git.staged
        status += Colors.colorize("+", @config.colors.staged)
      end
      if @git.dirty
        status += Colors.colorize("*", @config.colors.dirty)
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

    private def render_time : String
      # Format string is user-configurable via layout.time_format.
      # Default "%-I:%M %^p" reproduces the historical hardcoded
      # output (e.g. "6:41 AM", "12:41 PM") via the TimeFormat
      # helper, which expands the GNU/Ruby strftime extensions
      # Crystal's stdlib does not handle natively.
      formatted = TimeFormat.format(Time.local, @config.layout.time_format)
      Colors.colorize(formatted, @config.colors.time)
    end

    # Resolve the columns of the controlling terminal. Tries four
    # tiers in order; only the slow paths (ps forks) run when the
    # cheap controlling-TTY lookup fails.
    #
    # Tier 0: GALAXY_STATUSLINE_FORCE_WIDTH env override. Primarily
    # an escape hatch for tests (deterministic width regardless of
    # host TTY state); also useful in detached-process setups where
    # neither detection tier can reach a real PTY.
    #
    # Tier 1: ioctl on /dev/tty. Zero-cost when the hook subprocess
    # still has a controlling TTY.
    #
    # Tier 2: getsid(getppid()) → ps → ioctl. Deterministic single
    # hop to the parent's session leader. Handles the typical
    # detached-hook case where claude inherited the shell's TTY
    # and the shell is still the session leader.
    #
    # Tier 3: walk ancestors until we find one whose ps tty column
    # is a real PTY name, then ioctl that. Crosses setsid
    # boundaries that tier 2 cannot — the user's actual terminal
    # TTY may be held by an older-session ancestor when an
    # intermediate process created its own session. Bounded at 10
    # hops as defense against pathological process trees.
    private def get_terminal_width : Int32
      if forced = ENV["GALAXY_STATUSLINE_FORCE_WIDTH"]?
        cols = forced.to_i?
        return cols if cols && cols > 0
      end

      if cols = read_tty_width("/dev/tty")
        return cols
      end

      if cols = session_leader_tty_width
        return cols
      end

      if cols = ancestor_tty_width
        return cols
      end

      80
    end

    private def read_tty_width(path : String) : Int32?
      File.open(path, "r") do |tty|
        ws = TerminalLib::Winsize.new
        result = TerminalLib.ioctl(tty.fd, TIOCGWINSZ, pointerof(ws))
        return ws.ws_col.to_i32 if result == 0 && ws.ws_col > 0
      end
      nil
    rescue
      nil
    end

    private def session_leader_tty_width : Int32?
      sid = TerminalLib.getsid(TerminalLib.getppid)
      return nil if sid <= 1
      pid_tty_width(sid)
    rescue
      nil
    end

    private def ancestor_tty_width : Int32?
      pid = TerminalLib.getppid
      10.times do
        break if pid <= 1
        line = `ps -o tty=,ppid= -p #{pid} 2>/dev/null`.strip
        break if line.empty?

        tty, _, ppid_str = line.partition(/\s+/)
        if !tty.empty? && tty != "??" && tty != "-"
          if cols = read_tty_width("/dev/#{tty}")
            return cols
          end
        end

        next_pid = ppid_str.strip.to_i?
        break unless next_pid
        pid = next_pid
      end
      nil
    rescue
      nil
    end

    private def pid_tty_width(pid : Int32) : Int32?
      line = `ps -o tty= -p #{pid} 2>/dev/null`.strip
      return nil if line.empty? || line == "??" || line == "-"
      read_tty_width("/dev/#{line}")
    end

    private def strip_ansi(text : String) : String
      text.gsub(/\e\[[0-9;]*m/, "")
    end
  end
end
