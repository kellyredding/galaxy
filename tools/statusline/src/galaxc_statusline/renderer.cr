module GalaxcStatusline
  class Renderer
    SEPARATOR    = " | "
    FILLED_BLOCK = "█"
    EMPTY_BLOCK  = "░"

    @input : ClaudeInput
    @config : Config
    @git : Git
    @terminal_width : Int32

    def initialize(@input : ClaudeInput, @config : Config)
      @git = Git.new(@input.current_directory)
      @terminal_width = get_terminal_width
    end

    def render : String
      parts = [] of String

      # Always try to add context percentage (never drop)
      context_part = render_context

      # Calculate available width
      available = @terminal_width - context_part.size - SEPARATOR.size

      # Build parts from right to left priority
      # Cost (first to drop)
      cost_part = render_cost
      model_part = render_model

      # Directory and git
      dir_part = render_directory
      git_part = render_git

      # Assemble based on available width
      left_parts = [] of String
      right_parts = [] of String

      # Always include context
      right_parts << context_part

      # Try to include model
      if @config.layout.show_model && !model_part.empty?
        needed = strip_ansi(model_part).size + SEPARATOR.size
        if available >= needed
          right_parts.unshift(model_part)
          available -= needed
        end
      end

      # Try to include cost
      if @config.layout.show_cost && !cost_part.empty?
        needed = strip_ansi(cost_part).size + SEPARATOR.size
        if available >= needed
          right_parts.unshift(cost_part)
          available -= needed
        end
      end

      # Git status (rarely drop)
      if @git.in_git_repo? && !git_part.empty?
        needed = strip_ansi(git_part).size + SEPARATOR.size
        if available >= needed
          left_parts << git_part
          available -= needed
        end
      end

      # Directory (with progressive abbreviation)
      if !dir_part.empty?
        dir_display = fit_directory(dir_part, available)
        unless dir_display.empty?
          left_parts.unshift(dir_display)
        end
      end

      # Combine parts
      result = (left_parts + right_parts).join(SEPARATOR)
      result
    end

    private def render_directory : String
      dir = @input.current_directory
      return "" unless dir

      # Apply color
      Colors.colorize(dir, @config.colors.directory)
    end

    private def fit_directory(colored_dir : String, available_width : Int32) : String
      dir = @input.current_directory
      return "" unless dir

      # Try progressively shorter versions based on directory_style
      case @config.layout.directory_style
      when "full"
        # Only show full or nothing
        if strip_ansi(colored_dir).size <= available_width
          colored_dir
        else
          ""
        end
      when "smart"
        # Try full, then abbreviated, then basename
        if strip_ansi(colored_dir).size <= available_width
          return colored_dir
        end

        abbrev = abbreviate_path(dir)
        if abbrev.size <= available_width
          return Colors.colorize(abbrev, @config.colors.directory)
        end

        base = File.basename(dir)
        if base.size <= available_width
          return Colors.colorize(base, @config.colors.directory)
        end

        ""
      when "basename"
        base = File.basename(dir)
        Colors.colorize(base, @config.colors.directory)
      when "short"
        abbrev = abbreviate_path(dir)
        Colors.colorize(abbrev, @config.colors.directory)
      else
        colored_dir
      end
    end

    private def abbreviate_path(path : String) : String
      # Replace home with ~
      home = Path.home.to_s
      path = path.sub(home, "~") if path.starts_with?(home)

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

      parts.join
    end

    private def render_minimal_branch(branch : String) : String
      colored_branch = Colors.colorize(branch, @config.colors.branch)
      if @git.dirty || @git.staged
        colored_branch + Colors.colorize("*", @config.colors.dirty)
      else
        colored_branch
      end
    end

    private def render_context : String
      percentage = @input.context_percentage || 0.0

      # Determine color based on thresholds
      color = if percentage >= @config.context_thresholds.critical
                @config.colors.context_critical
              elsif percentage >= @config.context_thresholds.warning
                @config.colors.context_warning
              else
                @config.colors.context_normal
              end

      # Calculate bar width based on terminal width
      bar_width = calculate_bar_width

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

    private def calculate_bar_width : Int32
      min = @config.layout.context_bar_min_width
      max = @config.layout.context_bar_max_width

      # Scale based on terminal width
      if @terminal_width >= 120
        max
      elsif @terminal_width >= 80
        ((max + min) / 2).to_i
      else
        min
      end
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
      # Try to get terminal width
      begin
        result = `tput cols 2>/dev/null`.strip
        width = result.to_i?
        return width if width && width > 0
      rescue
      end

      # Fallback
      80
    end

    private def strip_ansi(text : String) : String
      text.gsub(/\e\[[0-9;]*m/, "")
    end
  end
end
