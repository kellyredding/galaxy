module GalaxyLedger
  module Extraction
    # Claude CLI subprocess invocation
    # Runs claude in print mode with JSON output
    module ClaudeCLI
      # Default timeout for Claude CLI calls (60 seconds)
      DEFAULT_TIMEOUT = 60.seconds

      # Result of a Claude CLI one-shot invocation, containing both the
      # extracted result text and usage/cost metadata from the JSON envelope.
      alias RunResult = NamedTuple(
        result: String?,
        cost_usd: Float64,
        input_tokens: Int64,
        output_tokens: Int64,
        cache_creation_tokens: Int64,
        cache_read_tokens: Int64,
      )

      ZERO_USAGE_RESULT = RunResult.new(
        result: nil,
        cost_usd: 0.0,
        input_tokens: 0_i64,
        output_tokens: 0_i64,
        cache_creation_tokens: 0_i64,
        cache_read_tokens: 0_i64,
      )

      # Test stub: when set, run() wraps this in a zero-usage RunResult.
      # Used by existing pipeline specs for backward compatibility.
      @@test_response : String? = nil

      def self.test_response=(response : String?)
        @@test_response = response
      end

      # Test stub: when set, run() returns this full RunResult directly.
      # Takes precedence over @@test_response. Used by specs that need
      # to verify usage data flow through the pipeline.
      @@test_run_result : RunResult? = nil

      def self.test_run_result=(result : RunResult?)
        @@test_run_result = result
      end

      # Argument list for the `claude` one-shot, kept separate from the
      # subprocess call so it can be asserted directly.
      #
      # A flag that the CLI accepts and ignores is indistinguishable from one
      # that works, and an unasserted argument list hides that difference for
      # as long as the output still looks plausible. Building the list here
      # means a change to what gets passed is a change a spec can see.
      #
      # Claude CLI takes the full prompt as an argument rather than on stdin,
      # so the content is embedded rather than piped.
      def self.build_args(
        content : String,
        prompt : String,
        model : String? = nil,
        json_schema : String? = nil,
      ) : Array(String)
        args = ["-p", "--output-format", "json"]
        args.concat(["--model", model]) if model
        args.concat(["--json-schema", json_schema]) if json_schema
        args << "#{prompt}\n\nContent to analyze:\n#{content}"
        args
      end

      # Run a Claude CLI one-shot command
      # Returns a RunResult with the extracted content and usage metadata.
      # On error/timeout, returns a RunResult with result: nil and zero usage.
      # Optional model parameter overrides the default model for the one-shot call.
      def self.run(
        content : String,
        prompt : String,
        timeout : Time::Span = DEFAULT_TIMEOUT,
        model : String? = nil,
        json_schema : String? = nil,
      ) : RunResult
        return ZERO_USAGE_RESULT if content.strip.empty?
        return ZERO_USAGE_RESULT if prompt.strip.empty?

        # test_run_result takes precedence over test_response
        if run_result = @@test_run_result
          return run_result
        end

        if test_resp = @@test_response
          return RunResult.new(
            result: test_resp,
            cost_usd: 0.0,
            input_tokens: 0_i64,
            output_tokens: 0_i64,
            cache_creation_tokens: 0_i64,
            cache_read_tokens: 0_i64,
          )
        end

        begin
          args = build_args(
            content: content,
            prompt: prompt,
            model: model,
            json_schema: json_schema,
          )

          # Build the command
          # claude -p --output-format json [--model MODEL] "$full_prompt"
          # Set GALAXY_SKIP_HOOKS=1 to prevent recursion - the claude -p session
          # would otherwise trigger hooks, which spawn more extractions, infinitely
          process = Process.new(
            "claude",
            args: args,
            input: Process::Redirect::Close,
            output: Process::Redirect::Pipe,
            error: Process::Redirect::Pipe,
            env: {
              "GALAXY_SKIP_HOOKS" => "1",
              # Clear CLAUDECODE so the one-shot Claude CLI call doesn't hit
              # nested-session detection when running inside a Claude session
              # (e.g., extraction eval specs or Galaxy.app-launched sessions).
              "CLAUDECODE" => "",
            },
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
            return ZERO_USAGE_RESULT
          end

          status = process.wait

          if status.success?
            # Parse the outer JSON wrapper to get result and usage data
            extract_run_result_from_cli_output(output.strip)
          else
            STDERR.puts "[galaxy-ledger] Claude CLI error (exit #{status.exit_code}): #{error}"
            ZERO_USAGE_RESULT
          end
        rescue ex
          STDERR.puts "[galaxy-ledger] Claude CLI exception: #{ex.message}"
          ZERO_USAGE_RESULT
        end
      end

      # Extract the result text and usage data from Claude CLI's JSON output.
      # The --output-format json flag wraps the result in metadata:
      # {"type":"result","result":"...","total_cost_usd":0.12,"usage":{...}}
      #
      # Every path that yields a nil result logs why. A caller that receives
      # nil turns it into zero extractions, which is indistinguishable from
      # the model legitimately deciding there was nothing to extract. Without
      # a log line, a broken call and an empty-but-correct answer look the
      # same from the outside, and the difference is the whole diagnosis.
      # Public for the same reason build_args is: the failure paths are the
      # interesting ones, and they are unreachable through run() because the
      # test stubs short-circuit before the subprocess.
      def self.extract_run_result_from_cli_output(output : String) : RunResult
        if output.empty?
          STDERR.puts "[galaxy-ledger] Claude CLI produced no output"
          return ZERO_USAGE_RESULT
        end

        begin
          json = JSON.parse(output)

          # Extract usage data from the envelope
          cost_usd = json["total_cost_usd"]?.try(&.as_f?) || 0.0
          input_tokens = json["usage"]?.try(&.["input_tokens"]?.try(&.as_i64?)) || 0_i64
          output_tokens = json["usage"]?.try(&.["output_tokens"]?.try(&.as_i64?)) || 0_i64
          cache_creation_tokens = json["usage"]?.try(&.["cache_creation_input_tokens"]?.try(&.as_i64?)) || 0_i64
          cache_read_tokens = json["usage"]?.try(&.["cache_read_input_tokens"]?.try(&.as_i64?)) || 0_i64

          # A failed call still exits zero and still fills in the result
          # field — with the error text rather than an answer. Treating that
          # as content hands "API Error: 400 ..." to a JSON parser, which
          # fails somewhere far from the cause. Refusing it here keeps the
          # reason attached to the thing that went wrong. Schema-constrained
          # calls make this reachable: a schema the API rejects surfaces
          # exactly this way.
          if json["is_error"]?.try(&.as_bool?)
            STDERR.puts(
              "[galaxy-ledger] Claude CLI reported an error: " \
              "#{json["result"]?.try(&.as_s?) || "(no detail)"}"
            )
            return RunResult.new(
              result: nil,
              cost_usd: cost_usd,
              input_tokens: input_tokens,
              output_tokens: output_tokens,
              cache_creation_tokens: cache_creation_tokens,
              cache_read_tokens: cache_read_tokens,
            )
          end

          # Get the result field
          result = json["result"]?.try(&.as_s?)
          if result.nil? || result.empty?
            # Surface the envelope's own subtype — it says more about why the
            # field is empty than the emptiness itself does.
            subtype = json["subtype"]?.try(&.as_s?)
            STDERR.puts(
              "[galaxy-ledger] Claude CLI returned an empty result field" \
              "#{subtype.nil? ? "" : " (subtype=#{subtype})"}"
            )
            return RunResult.new(
              result: nil,
              cost_usd: cost_usd,
              input_tokens: input_tokens,
              output_tokens: output_tokens,
              cache_creation_tokens: cache_creation_tokens,
              cache_read_tokens: cache_read_tokens,
            )
          end

          # Strip markdown code blocks if present
          # Claude sometimes wraps JSON in ```json ... ```
          cleaned = strip_markdown_code_blocks(result)
          if cleaned.empty?
            STDERR.puts(
              "[galaxy-ledger] Claude CLI result was empty after stripping " \
              "markdown fences"
            )
          end

          RunResult.new(
            result: cleaned.empty? ? nil : cleaned,
            cost_usd: cost_usd,
            input_tokens: input_tokens,
            output_tokens: output_tokens,
            cache_creation_tokens: cache_creation_tokens,
            cache_read_tokens: cache_read_tokens,
          )
        rescue ex
          # Envelope did not parse. Fall back to treating the raw output as
          # the content, but say so — usage data is lost on this path, so a
          # silent fallback also silently zeroes the call's cost and tokens.
          STDERR.puts(
            "[galaxy-ledger] Claude CLI envelope parse failed " \
            "(#{ex.message}); treating raw output as content"
          )
          cleaned = strip_markdown_code_blocks(output)
          if cleaned.empty?
            STDERR.puts "[galaxy-ledger] Claude CLI raw output was empty too"
          end
          RunResult.new(
            result: cleaned.empty? ? nil : cleaned,
            cost_usd: 0.0,
            input_tokens: 0_i64,
            output_tokens: 0_i64,
            cache_creation_tokens: 0_i64,
            cache_read_tokens: 0_i64,
          )
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
          # The subprocess will handle the actual Claude CLI call and database insert
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
