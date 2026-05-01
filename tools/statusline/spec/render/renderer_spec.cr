require "../spec_helper"

def strip_ansi(text : String) : String
  text.gsub(/\e\[[0-9;]*m/, "")
end

describe GalaxyStatusline::Renderer do
  describe "git branch styles all have brackets" do
    # Note: In spec context (no git repo), git info won't appear
    # These tests verify the render succeeds with each style

    describe "symbolic style" do
      it "renders successfully" do
        json = read_fixture("claude_input/valid_complete.json")
        result = run_binary(["render"], stdin: json)
        result[:status].should eq(0)
      end
    end

    describe "arrows style" do
      it "renders successfully" do
        run_binary(["config", "set", "branch_style", "arrows"])
        json = read_fixture("claude_input/valid_complete.json")
        result = run_binary(["render"], stdin: json)
        result[:status].should eq(0)
        run_binary(["config", "reset"])
      end
    end

    describe "minimal style" do
      it "renders successfully" do
        run_binary(["config", "set", "branch_style", "minimal"])
        json = read_fixture("claude_input/valid_complete.json")
        result = run_binary(["render"], stdin: json)
        result[:status].should eq(0)
        run_binary(["config", "reset"])
      end
    end
  end

  describe "output format" do
    it "always includes context bar with percentage" do
      # Context bar is never dropped - it's the last thing to remain
      json = read_fixture("claude_input/valid_complete.json")
      result = run_binary(["render"], stdin: json)
      output = strip_ansi(result[:output])

      output.should contain("%")
      output.should contain("█")
    end

    it "includes context percentage from input" do
      json = read_fixture("claude_input/valid_complete.json")
      result = run_binary(["render"], stdin: json)
      output = strip_ansi(result[:output])

      # Fixture has 45.2% which rounds to 45%
      output.should contain("45%")
    end
  end

  describe "context bar" do
    it "rounds percentage to integer" do
      json = %({"cwd": "/test", "context_window": {"used_percentage": 75.5}})
      result = run_binary(["render"], stdin: json)
      output = strip_ansi(result[:output])

      output.should contain("76%")
    end

    it "handles 0% context" do
      json = %({"cwd": "/test", "context_window": {"used_percentage": 0}})
      result = run_binary(["render"], stdin: json)
      output = strip_ansi(result[:output])

      output.should contain("0%")
    end

    it "handles 100% context" do
      json = %({"cwd": "/test", "context_window": {"used_percentage": 100}})
      result = run_binary(["render"], stdin: json)
      output = strip_ansi(result[:output])

      output.should contain("100%")
    end
  end

  describe "shrinking behavior" do
    # In narrow terminal (test env), components are shrunk/dropped
    # Priority: shrink bar → drop cost → drop model → shrink dir → drop git

    it "always shows context bar even when narrow" do
      json = %({"cwd": "/very/long/path/that/would/need/shrinking", "model": {"display_name": "VeryLongModelName"}, "cost": {"total_cost_usd": 999.99}, "context_window": {"used_percentage": 50}})
      result = run_binary(["render"], stdin: json)
      output = strip_ansi(result[:output])

      # Context bar should always be present
      output.should contain("%")
      output.should contain("█")
    end

    it "shrinks directory to basename when needed" do
      # With narrow terminal, long paths get shortened
      json = %({"cwd": "/some/very/long/directory/path/here", "context_window": {"used_percentage": 50}})
      result = run_binary(["render"], stdin: json)
      output = strip_ansi(result[:output])

      # Should show at least the basename or abbreviated form
      # (the exact form depends on available width)
      result[:status].should eq(0)
    end
  end

  describe "directory display" do
    it "shows directory when space available" do
      json = %({"cwd": "/test", "context_window": {"used_percentage": 50}})
      result = run_binary(["render"], stdin: json)
      output = strip_ansi(result[:output])

      output.should contain("test")
    end
  end

  describe "time display" do
    # The test environment's /dev/tty falls back to 80 cols, giving a
    # 40-char session-line budget. Shrink bar bounds so model+bar+cost+
    # time all fit and we can verify ordering and presence.
    narrow_session = -> {
      run_binary(["config", "set", "layout.context_bar_max_width", "8"])
      run_binary(["config", "set", "layout.context_bar_min_width", "4"])
    }

    it "renders current time in 12-hour format with AM/PM" do
      narrow_session.call
      json = read_fixture("claude_input/valid_complete.json")
      result = run_binary(["render"], stdin: json)
      output = strip_ansi(result[:output])

      # 12-hour, no leading zero, single space before AM/PM
      # e.g. "6:41 AM" or "12:41 PM"
      output.should match(/\b\d{1,2}:\d{2} (AM|PM)\b/)
      run_binary(["config", "reset"])
    end

    it "places time after cost on the session line" do
      narrow_session.call
      json = %({"cwd": "/x", "context_window": {"used_percentage": 50}, "cost": {"total_cost_usd": 1.23}})
      result = run_binary(["render"], stdin: json)
      output = strip_ansi(result[:output])

      cost_idx = output.index("$1.23")
      time_match = output.match(/\d{1,2}:\d{2} (AM|PM)/)

      cost_idx.should_not be_nil
      time_match.should_not be_nil

      if cost_idx && time_match
        time_idx = output.index(time_match[0])
        time_idx.should_not be_nil
        time_idx.not_nil!.should be > cost_idx
      end
      run_binary(["config", "reset"])
    end

    it "hides time when layout.show_time is false" do
      narrow_session.call
      run_binary(["config", "set", "layout.show_time", "false"])
      json = read_fixture("claude_input/valid_complete.json")
      result = run_binary(["render"], stdin: json)
      output = strip_ansi(result[:output])

      output.should_not match(/\b\d{1,2}:\d{2} (AM|PM)\b/)
      run_binary(["config", "reset"])
    end

    it "drops time before cost when width is constrained" do
      # Force a width-constrained scenario where exactly one of
      # {time, cost} can fit. Time should drop first; cost survives.
      run_binary(["config", "set", "layout.show_model", "false"])
      run_binary(["config", "set", "layout.context_bar_max_width", "20"])
      run_binary(["config", "set", "layout.context_bar_min_width", "20"])
      json = %({"cwd": "/x", "context_window": {"used_percentage": 50}, "cost": {"total_cost_usd": 1.23}})
      result = run_binary(["render"], stdin: json)
      output = strip_ansi(result[:output])

      # bar(20) + " 50%"(4) + " | "(3) + "$1.23"(5) = 32 ≤ 40
      # adding " | X:XX AM"(10) = 42 > 40, so time must drop, cost stays
      output.should contain("$1.23")
      output.should_not match(/\b\d{1,2}:\d{2} (AM|PM)\b/)
      run_binary(["config", "reset"])
    end
  end

  describe "separator handling" do
    it "uses | separator between session line components" do
      # Session line uses separator when cost is present alongside context bar
      json = %({"cwd": "/test", "context_window": {"used_percentage": 50}, "cost": {"total_cost_usd": 1.23}})
      result = run_binary(["render"], stdin: json)
      output = strip_ansi(result[:output])

      output.should contain(" | ")
    end

    it "directory and git are adjacent without separator" do
      # This is verified by the fact that when both are present,
      # they appear as "dir[branch]" not "dir | [branch]"
      # In test env without git, we just verify the render succeeds
      json = read_fixture("claude_input/valid_complete.json")
      result = run_binary(["render"], stdin: json)
      output = strip_ansi(result[:output])

      # If there were a directory followed by git, it should NOT have " | ["
      # Since we're not in a git repo in test, we just verify format is valid
      result[:status].should eq(0)

      # The output should not have the pattern " | [" which would indicate
      # a separator between directory and git brackets
      output.should_not contain(" | [")
    end
  end
end
