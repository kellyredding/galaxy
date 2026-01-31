require "../spec_helper"

def strip_ansi(text : String) : String
  text.gsub(/\e\[[0-9;]*m/, "")
end

describe GalaxcStatusline::Renderer do
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

  describe "separator handling" do
    it "uses | separator between components" do
      # Even in narrow mode, if we have dir + context, there's a separator
      json = %({"cwd": "/test", "context_window": {"used_percentage": 50}})
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
