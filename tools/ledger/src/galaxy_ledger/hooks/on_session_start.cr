require "json"

module GalaxyLedger
  module Hooks
    # Handles the SessionStart(clear|compact) hook
    # - Reads last exchange from ledger_last-exchange.json
    # - Prints formatted terminal output showing what was happening before clear/compact
    # - Returns additionalContext with condensed summary for agent restoration
    class OnSessionStart
      @session_id : String?
      @source : String?

      # Box drawing constants for terminal output
      BOX_TOP_LEFT     = "╭"
      BOX_TOP_RIGHT    = "╮"
      BOX_BOTTOM_LEFT  = "╰"
      BOX_BOTTOM_RIGHT = "╯"
      BOX_HORIZONTAL   = "─"
      BOX_VERTICAL     = "│"
      BOX_WIDTH        = 72

      def run
        # Skip if GALAXY_SKIP_HOOKS is set (prevents recursion from extraction subprocesses)
        return if ENV["GALAXY_SKIP_HOOKS"]? == "1"

        # Parse hook input from stdin
        parse_hook_input

        session_id = @session_id
        return output_empty unless session_id

        # Read last exchange
        last_exchange = Exchange.read(session_id)

        # Print terminal output (visible to user)
        print_terminal_output(last_exchange)

        # Build and output JSON with additionalContext
        context = build_additional_context(last_exchange)
        output_json(context)
      end

      private def parse_hook_input
        # Hook receives JSON via stdin:
        # {
        #   "session_id": "abc123",
        #   "source": "clear|compact",
        #   ...
        # }
        begin
          input = STDIN.gets_to_end
          return if input.empty?

          json = JSON.parse(input)
          @session_id = json["session_id"]?.try(&.as_s?)
          @source = json["source"]?.try(&.as_s?)
        rescue
          # Silently ignore parse errors
        end
      end

      private def print_terminal_output(last_exchange : Exchange::LastExchange?)
        unless last_exchange
          # No last exchange to display
          puts ""
          puts "#{BOX_VERTICAL} No previous context to restore."
          puts ""
          return
        end

        # Print the boxed display
        puts ""
        print_box_top("📋 Last Interaction (Before #{@source || "clear"})")
        puts "#{BOX_VERTICAL}#{" " * (BOX_WIDTH - 2)}#{BOX_VERTICAL}"
        print_wrapped("You asked:", 2)
        print_wrapped(last_exchange.user_message, 4)
        puts "#{BOX_VERTICAL}#{" " * (BOX_WIDTH - 2)}#{BOX_VERTICAL}"
        print_wrapped("I responded:", 2)
        print_content_preview(last_exchange.full_content, 4)
        puts "#{BOX_VERTICAL}#{" " * (BOX_WIDTH - 2)}#{BOX_VERTICAL}"
        print_box_bottom
        puts ""
      end

      private def print_box_top(title : String)
        # ╭─ Title ──────────────────────────────────╮
        title_part = "#{BOX_HORIZONTAL} #{title} "
        remaining = BOX_WIDTH - title_part.size - 2 # -2 for corners
        remaining = 0 if remaining < 0
        puts "#{BOX_TOP_LEFT}#{title_part}#{BOX_HORIZONTAL * remaining}#{BOX_TOP_RIGHT}"
      end

      private def print_box_bottom
        # ╰──────────────────────────────────────────╯
        puts "#{BOX_BOTTOM_LEFT}#{BOX_HORIZONTAL * (BOX_WIDTH - 2)}#{BOX_BOTTOM_RIGHT}"
      end

      private def print_wrapped(text : String, indent : Int32)
        # Wrap text within the box
        max_width = BOX_WIDTH - indent - 4 # -4 for box borders and padding
        lines = wrap_text(text, max_width)

        lines.each do |line|
          padding = " " * indent
          right_padding = " " * (BOX_WIDTH - line.size - indent - 2)
          puts "#{BOX_VERTICAL}#{padding}#{line}#{right_padding}#{BOX_VERTICAL}"
        end
      end

      private def print_content_preview(content : String, indent : Int32)
        # Show preview of content (first ~5 lines or 300 chars)
        max_width = BOX_WIDTH - indent - 4
        preview = content[0, 500]? || content

        # Take first few lines
        lines = wrap_text(preview, max_width)
        display_lines = lines[0, 6]? || lines

        display_lines.each do |line|
          padding = " " * indent
          right_padding = " " * (BOX_WIDTH - line.size - indent - 2)
          puts "#{BOX_VERTICAL}#{padding}#{line}#{right_padding}#{BOX_VERTICAL}"
        end

        if lines.size > 6
          padding = " " * indent
          truncate_msg = "[... #{lines.size - 6} more lines]"
          right_padding = " " * (BOX_WIDTH - truncate_msg.size - indent - 2)
          puts "#{BOX_VERTICAL}#{padding}#{truncate_msg}#{right_padding}#{BOX_VERTICAL}"
        end
      end

      private def wrap_text(text : String, max_width : Int32) : Array(String)
        return [""] if text.empty?

        lines = [] of String
        text.split('\n').each do |paragraph|
          if paragraph.empty?
            lines << ""
            next
          end

          words = paragraph.split(/\s+/)
          current_line = ""

          words.each do |word|
            if current_line.empty?
              current_line = word
            elsif current_line.size + 1 + word.size <= max_width
              current_line += " #{word}"
            else
              lines << current_line
              current_line = word
            end
          end

          lines << current_line unless current_line.empty?
        end

        lines
      end

      private def build_additional_context(last_exchange : Exchange::LastExchange?) : String
        lines = [] of String
        lines << "## Restored Context"
        lines << ""

        if last_exchange
          lines << "### Last Interaction"
          lines << "**You asked**: #{last_exchange.user_message}"
          lines << ""

          # If we have a summary (Phase 6), use it
          if summary = last_exchange.summary
            lines << "**I responded**: #{summary.assistant_response}"
            lines << ""
            unless summary.files_modified.empty?
              lines << "**Files modified**: #{summary.files_modified.join(", ")}"
            end
            unless summary.key_actions.empty?
              lines << "**Key actions**: #{summary.key_actions.join(", ")}"
            end
          else
            # No summary yet (Phase 2), use truncated full_content
            preview = last_exchange.full_content[0, 300]? || last_exchange.full_content
            if last_exchange.full_content.size > 300
              preview += "..."
            end
            lines << "**I responded**: #{preview}"
          end
        else
          lines << "No previous context available."
        end

        lines << ""
        lines << "---"
        lines << "📚 Full session history available: `galaxy-ledger search \"query\"`"

        lines.join("\n")
      end

      private def output_json(context : String)
        output = {
          "hookSpecificOutput" => {
            "hookEventName"     => "SessionStart",
            "additionalContext" => context,
          },
        }
        puts output.to_json
      end

      private def output_empty
        output = {
          "hookSpecificOutput" => {
            "hookEventName"     => "SessionStart",
            "additionalContext" => "",
          },
        }
        puts output.to_json
      end
    end
  end
end
