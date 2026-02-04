module GalaxyLedger
  module Extraction
    # Claude CLI subprocess invocation
    # Runs claude in print mode with JSON output
    module ClaudeCLI
      # Default timeout for Claude CLI calls (60 seconds)
      DEFAULT_TIMEOUT = 60.seconds

      # Run a Claude CLI one-shot command
      # Returns the JSON output string, or nil on error
      def self.run(
        content : String,
        prompt : String,
        timeout : Time::Span = DEFAULT_TIMEOUT,
      ) : String?
        return nil if content.strip.empty?
        return nil if prompt.strip.empty?

        begin
          # Build the full prompt with content embedded
          # Claude CLI expects the full prompt as an argument, not piped input
          full_prompt = "#{prompt}\n\nContent to analyze:\n#{content}"

          # Build the command
          # claude -p --output-format json "$full_prompt"
          # Set GALAXY_SKIP_HOOKS=1 to prevent recursion - the claude -p session
          # would otherwise trigger hooks, which spawn more extractions, infinitely
          process = Process.new(
            "claude",
            args: ["-p", "--output-format", "json", full_prompt],
            input: Process::Redirect::Close,
            output: Process::Redirect::Pipe,
            error: Process::Redirect::Pipe,
            env: {"GALAXY_SKIP_HOOKS" => "1"},
          )

          # Read output with timeout
          output = ""
          error = ""
          done = Channel(Nil).new

          spawn do
            output = process.output.gets_to_end
            error = process.error.gets_to_end
            done.send(nil)
          end

          select
          when done.receive
            # Process completed
          when timeout(timeout)
            # Timeout - kill the process
            process.terminate
            STDERR.puts "[galaxy-ledger] Claude CLI timeout after #{timeout.total_seconds}s"
            return nil
          end

          status = process.wait

          if status.success?
            # Parse the outer JSON wrapper to get the result field
            extract_result_from_cli_output(output.strip)
          else
            STDERR.puts "[galaxy-ledger] Claude CLI error (exit #{status.exit_code}): #{error}"
            nil
          end
        rescue ex
          STDERR.puts "[galaxy-ledger] Claude CLI exception: #{ex.message}"
          nil
        end
      end

      # Extract the actual result from Claude CLI's JSON output
      # The --output-format json flag wraps the result in metadata:
      # {"type":"result","result":"...actual content...","...":"..."}
      private def self.extract_result_from_cli_output(output : String) : String?
        return nil if output.empty?

        begin
          json = JSON.parse(output)

          # Get the result field
          result = json["result"]?.try(&.as_s?)
          return nil if result.nil? || result.empty?

          # Strip markdown code blocks if present
          # Claude sometimes wraps JSON in ```json ... ```
          cleaned = strip_markdown_code_blocks(result)

          cleaned.empty? ? nil : cleaned
        rescue
          # If outer parsing fails, maybe it's already just the content
          strip_markdown_code_blocks(output)
        end
      end

      # Strip markdown code blocks from the result
      private def self.strip_markdown_code_blocks(text : String) : String
        result = text.strip

        # Remove ```json ... ``` or ``` ... ```
        if result.starts_with?("```")
          # Find the first newline (end of opening fence)
          first_newline = result.index('\n')
          if first_newline
            result = result[(first_newline + 1)..]
          end

          # Remove closing fence
          if result.ends_with?("```")
            result = result[0...-3]
          end
        end

        result.strip
      end

      # Run extraction asynchronously (spawns detached process)
      # Returns immediately, extraction runs in background
      def self.run_async(
        session_id : String,
        extraction_type : String,
        content : String,
        prompt : String,
      ) : Bool
        return false if session_id.empty?
        return false if content.strip.empty?

        begin
          # Find the galaxy-ledger binary
          binary = Process.executable_path || "galaxy-ledger"

          # Spawn a detached subprocess to run the extraction
          # The subprocess will handle the actual Claude CLI call and buffer append
          process = Process.new(
            binary,
            args: ["extract-async", "--session", session_id, "--type", extraction_type],
            input: IO::Memory.new(content),
            output: Process::Redirect::Close,
            error: Process::Redirect::Close,
          )

          true
        rescue
          false
        end
      end
    end
  end
end
