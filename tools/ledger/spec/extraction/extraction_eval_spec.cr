require "../spec_helper"

# Smoke tests that call the actual Claude CLI to verify extraction prompts
# produce parseable, reasonable output. One test per extraction type, plus
# two end-to-end CLI tests for extract-assistant.
#
# Tagged "eval" — excluded from default `crystal spec` runs.
# Run explicitly:  crystal spec --tag eval
#                  make test-eval
#
# Parsing correctness is covered by extraction_pipeline_spec.cr (fast, stubbed).
# These only validate that Claude + our prompts return sensible results.
#
# All 6 evals run CONCURRENTLY using fibers. Each eval is ~30s (Claude
# one-shot latency), so concurrent execution reduces wall-clock from ~180s
# to ~30-35s. Crystal's Process.new is fiber-friendly (yields via SIGCHLD),
# so subprocess-based evals work correctly inside spawned fibers.

record EvalResult,
  name : String,
  passed : Bool,
  message : String,
  duration : Time::Span

# --- Extraction evals (in-process Claude calls) ---

def eval_user_directions(fixtures_path : Path) : EvalResult
  start = Time.monotonic
  begin
    content = File.read(fixtures_path / "user_prompts" / "02_direction_explicit.txt")
    result = GalaxyLedger::Extraction.extract_user_directions(content)

    if result.extractions.size != 2
      return EvalResult.new(
        name: "user_directions",
        passed: false,
        message: "Expected 2 extractions, got #{result.extractions.size}",
        duration: Time.monotonic - start,
      )
    end

    STDERR.puts "\n  [user:direction_explicit] Extractions:"
    result.extractions.each do |e|
      STDERR.puts "    - #{e.entry_type} (#{e.importance}): #{e.content[0, 60]}..."
    end

    EvalResult.new(
      name: "user_directions",
      passed: true,
      message: "#{result.extractions.size} extractions",
      duration: Time.monotonic - start,
    )
  rescue ex
    EvalResult.new(
      name: "user_directions",
      passed: false,
      message: "Exception: #{ex.message}",
      duration: Time.monotonic - start,
    )
  end
end

def eval_assistant_learnings(fixtures_path : Path) : EvalResult
  start = Time.monotonic
  begin
    content = File.read(fixtures_path / "assistant_responses" / "02_decision_with_rationale.txt")
    result = GalaxyLedger::Extraction.extract_assistant_learnings("Implement the feature", content)

    if result.extractions.size < 1
      return EvalResult.new(
        name: "assistant_learnings",
        passed: false,
        message: "Expected at least 1 extraction, got #{result.extractions.size}",
        duration: Time.monotonic - start,
      )
    end

    if result.summary.nil?
      return EvalResult.new(
        name: "assistant_learnings",
        passed: false,
        message: "Expected a summary, got nil",
        duration: Time.monotonic - start,
      )
    end

    STDERR.puts "\n  [assistant:decision_with_rationale]"
    if summary = result.summary
      STDERR.puts "    Summary: #{summary.assistant_response[0, 80]}..."
    end
    result.extractions.each do |e|
      STDERR.puts "    - #{e.entry_type} (#{e.importance}): #{e.content[0, 60]}..."
    end

    EvalResult.new(
      name: "assistant_learnings",
      passed: true,
      message: "#{result.extractions.size} extractions + summary",
      duration: Time.monotonic - start,
    )
  rescue ex
    EvalResult.new(
      name: "assistant_learnings",
      passed: false,
      message: "Exception: #{ex.message}",
      duration: Time.monotonic - start,
    )
  end
end

def eval_guidelines(fixtures_path : Path) : EvalResult
  start = Time.monotonic
  begin
    md_file = (fixtures_path / "guidelines" / "01_ruby_style.md").to_s
    content = File.read(md_file)

    result = GalaxyLedger::Extraction.extract_guidelines(md_file, content)

    if result.extractions.size < 4
      return EvalResult.new(
        name: "guidelines",
        passed: false,
        message: "Expected at least 4 extractions, got #{result.extractions.size}",
        duration: Time.monotonic - start,
      )
    end

    bad_types = result.extractions.reject { |e| e.entry_type == "guideline" }
    if bad_types.any?
      return EvalResult.new(
        name: "guidelines",
        passed: false,
        message: "Expected all guideline types, got: #{bad_types.map(&.entry_type).uniq.join(", ")}",
        duration: Time.monotonic - start,
      )
    end

    STDERR.puts "\n  [guideline:ruby_style] Guidelines:"
    result.extractions.each do |e|
      STDERR.puts "    - (#{e.importance}): #{e.content[0, 70]}..."
    end

    EvalResult.new(
      name: "guidelines",
      passed: true,
      message: "#{result.extractions.size} guidelines",
      duration: Time.monotonic - start,
    )
  rescue ex
    EvalResult.new(
      name: "guidelines",
      passed: false,
      message: "Exception: #{ex.message}",
      duration: Time.monotonic - start,
    )
  end
end

def eval_implementation_plan(fixtures_path : Path) : EvalResult
  start = Time.monotonic
  begin
    md_file = (fixtures_path / "implementation_plans" / "01_phased_plan.md").to_s
    content = File.read(md_file)

    result = GalaxyLedger::Extraction.extract_implementation_plan(md_file, content)

    if result.extractions.size < 2
      return EvalResult.new(
        name: "implementation_plan",
        passed: false,
        message: "Expected at least 2 extractions, got #{result.extractions.size}",
        duration: Time.monotonic - start,
      )
    end

    bad_types = result.extractions.reject { |e| e.entry_type == "implementation_plan" }
    if bad_types.any?
      return EvalResult.new(
        name: "implementation_plan",
        passed: false,
        message: "Expected all implementation_plan types, got: #{bad_types.map(&.entry_type).uniq.join(", ")}",
        duration: Time.monotonic - start,
      )
    end

    STDERR.puts "\n  [impl_plan:phased_plan] Context:"
    result.extractions.each do |e|
      STDERR.puts "    - (#{e.importance}): #{e.content[0, 70]}..."
    end

    EvalResult.new(
      name: "implementation_plan",
      passed: true,
      message: "#{result.extractions.size} plan entries",
      duration: Time.monotonic - start,
    )
  rescue ex
    EvalResult.new(
      name: "implementation_plan",
      passed: false,
      message: "Exception: #{ex.message}",
      duration: Time.monotonic - start,
    )
  end
end

# --- CLI evals (subprocess run_binary calls) ---

def eval_extract_assistant_input_file : EvalResult
  start = Time.monotonic
  begin
    session_id = "eval-input-file-#{Random.rand(100000)}"
    GalaxyLedger::Database.create_session(session_id)

    input_file = File.tempfile("extract-input", ".json")
    input_json = {
      "user_message"      => "Help me add dark mode to the settings page",
      "assistant_content" => "I've added a dark mode toggle to the settings page. The implementation uses CSS custom properties for theming and persists the user's preference in localStorage. Files modified: settings.tsx, theme.css.",
    }.to_json
    File.write(input_file.path, input_json)

    result = run_binary([
      "extract-assistant",
      "--session", session_id,
      "--input-file", input_file.path,
    ])

    File.delete(input_file.path) if File.exists?(input_file.path)

    if result[:status] != 0
      return EvalResult.new(
        name: "cli_extract_input_file",
        passed: false,
        message: "Binary exited #{result[:status]}: #{result[:error]}",
        duration: Time.monotonic - start,
      )
    end

    session = GalaxyLedger::Database.get_session(session_id)
    if s = session
      if s.title.nil?
        return EvalResult.new(
          name: "cli_extract_input_file",
          passed: false,
          message: "Session title was nil after extraction",
          duration: Time.monotonic - start,
        )
      end
      STDERR.puts "\n  [extract-assistant --input-file] Session title: #{s.title}"
    else
      return EvalResult.new(
        name: "cli_extract_input_file",
        passed: false,
        message: "Session not found in DB",
        duration: Time.monotonic - start,
      )
    end

    EvalResult.new(
      name: "cli_extract_input_file",
      passed: true,
      message: "title: #{session.try(&.title)}",
      duration: Time.monotonic - start,
    )
  rescue ex
    EvalResult.new(
      name: "cli_extract_input_file",
      passed: false,
      message: "Exception: #{ex.message}",
      duration: Time.monotonic - start,
    )
  end
end

def eval_extract_assistant_transcript_path : EvalResult
  start = Time.monotonic
  begin
    session_id = "eval-transcript-#{Random.rand(100000)}"
    GalaxyLedger::Database.create_session(session_id)

    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Help me add dark mode to the settings page"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "I've added a dark mode toggle to the settings page. The implementation uses CSS custom properties for theming and persists the user's preference in localStorage. Files modified: settings.tsx, theme.css."}}\n|)
    transcript_file.close

    result = run_binary([
      "extract-assistant",
      "--session", session_id,
      "--transcript-path", transcript_file.path,
    ])

    File.delete(transcript_file.path) if File.exists?(transcript_file.path)

    if result[:status] != 0
      return EvalResult.new(
        name: "cli_extract_transcript",
        passed: false,
        message: "Binary exited #{result[:status]}: #{result[:error]}",
        duration: Time.monotonic - start,
      )
    end

    session = GalaxyLedger::Database.get_session(session_id)
    if s = session
      if s.title.nil?
        return EvalResult.new(
          name: "cli_extract_transcript",
          passed: false,
          message: "Session title was nil after extraction",
          duration: Time.monotonic - start,
        )
      end
      STDERR.puts "\n  [extract-assistant --transcript-path] Session title: #{s.title}"
    else
      return EvalResult.new(
        name: "cli_extract_transcript",
        passed: false,
        message: "Session not found in DB",
        duration: Time.monotonic - start,
      )
    end

    EvalResult.new(
      name: "cli_extract_transcript",
      passed: true,
      message: "title: #{session.try(&.title)}",
      duration: Time.monotonic - start,
    )
  rescue ex
    EvalResult.new(
      name: "cli_extract_transcript",
      passed: false,
      message: "Exception: #{ex.message}",
      duration: Time.monotonic - start,
    )
  end
end

# --- Concurrent runner ---

describe "Extraction Evals", tags: "eval" do
  fixtures_path = SPEC_FIXTURES / "extraction_evals"

  it "runs all extraction evals concurrently" do
    channel = Channel(EvalResult).new
    eval_count = 6

    # Spawn all 6 evals concurrently as fibers.
    # The 4 extraction evals call ClaudeCLI.run() which spawns `claude -p`.
    # The 2 CLI evals call run_binary() which spawns `galaxy-ledger`.
    # All subprocesses run as parallel OS processes; fibers yield while
    # waiting on Process#wait (SIGCHLD-based, event-loop integrated).
    spawn { channel.send(eval_user_directions(fixtures_path)) }
    spawn { channel.send(eval_assistant_learnings(fixtures_path)) }
    spawn { channel.send(eval_guidelines(fixtures_path)) }
    spawn { channel.send(eval_implementation_plan(fixtures_path)) }
    spawn { channel.send(eval_extract_assistant_input_file) }
    spawn { channel.send(eval_extract_assistant_transcript_path) }

    # Collect all results
    results = [] of EvalResult
    eval_count.times { results << channel.receive }

    # Report results table
    STDERR.puts "\n\n  #{"=" * 56}"
    STDERR.puts "  Eval Results:"
    STDERR.puts "  #{"=" * 56}"
    results.sort_by(&.name).each do |r|
      status = r.passed ? "PASS" : "FAIL"
      STDERR.puts "  [#{status}] #{r.name} (#{r.duration.total_seconds.round(1)}s)"
      STDERR.puts "         #{r.message}" unless r.passed
    end
    wall_clock = results.max_of(&.duration)
    STDERR.puts "  #{"=" * 56}"
    STDERR.puts "  Wall clock: #{wall_clock.total_seconds.round(1)}s " \
                "(was ~#{eval_count * 30}s sequential)"
    STDERR.puts ""

    # Assert — fail the spec if any eval failed
    failures = results.reject(&.passed)
    if failures.any?
      fail_messages = failures.map { |f| "#{f.name}: #{f.message}" }
      fail("#{failures.size}/#{eval_count} evals failed:\n" +
           fail_messages.join("\n"))
    end
  end
end
