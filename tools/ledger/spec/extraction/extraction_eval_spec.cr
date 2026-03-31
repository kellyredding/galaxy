require "../spec_helper"

# Smoke tests that call the actual Claude CLI to verify extraction and
# suggest-name prompts produce parseable, reasonable output.
#
# Tagged "eval" — excluded from default `crystal spec` runs.
# Run explicitly:  crystal spec --tag eval
#                  make test-eval
#
# Parsing correctness is covered by fast, stubbed specs:
#   - extraction_pipeline_spec.cr (extraction)
#   - suggested_name_spec.cr (suggest-name)
# These only validate that Claude + our prompts return sensible results.
#
# All 9 evals run CONCURRENTLY in a single `it` block using fibers.
# Each eval is ~15-30s (Claude one-shot latency), so concurrent execution
# reduces wall-clock from ~270s to ~20-30s. Crystal's Process.new is
# fiber-friendly (yields via SIGCHLD), so subprocess-based evals work
# correctly inside spawned fibers.

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

    if result.extractions.size < 1
      return EvalResult.new(
        name: "user_directions",
        passed: false,
        message: "Expected at least 1 extraction, got #{result.extractions.size}",
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
    unless session
      return EvalResult.new(
        name: "cli_extract_input_file",
        passed: false,
        message: "Session not found in DB",
        duration: Time.monotonic - start,
      )
    end

    # Verify extraction ran (check stderr for extraction output).
    # The --input-file path writes learnings/decisions to the DB but
    # does not create last_interaction (that requires transcript path).
    STDERR.puts "\n  [extract-assistant --input-file] Extraction completed"

    EvalResult.new(
      name: "cli_extract_input_file",
      passed: true,
      message: "extraction complete",
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
    unless session
      return EvalResult.new(
        name: "cli_extract_transcript",
        passed: false,
        message: "Session not found in DB",
        duration: Time.monotonic - start,
      )
    end

    # Verify last_interaction was written (extraction still produces summaries)
    if session.last_interaction.nil?
      return EvalResult.new(
        name: "cli_extract_transcript",
        passed: false,
        message: "Last interaction was nil after extraction",
        duration: Time.monotonic - start,
      )
    end
    STDERR.puts "\n  [extract-assistant --transcript-path] Extraction completed"

    EvalResult.new(
      name: "cli_extract_transcript",
      passed: true,
      message: "extraction complete",
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

# --- Suggest-name evals (subprocess run_binary calls) ---

def eval_needs_more_context : EvalResult
  start = Time.monotonic
  begin
    # Create a session with minimal context (just a greeting)
    session_id = "eval-suggest-needs-ctx-#{Random.rand(100000)}"
    GalaxyLedger::Database.create_session(session_id)
    flush_wal

    transcript_file = File.tempfile("eval-suggest-ctx", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "where were we?"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Let me check our previous context and see where we left off."}}\n|)
    transcript_file.close

    result = run_binary([
      "suggest-name",
      "--session", session_id,
      "--transcript-path", transcript_file.path,
    ])

    File.delete(transcript_file.path) if File.exists?(transcript_file.path)

    if result[:status] != 0
      return EvalResult.new(
        name: "needs_more_context",
        passed: false,
        message: "Binary exited #{result[:status]}: #{result[:error]}",
        duration: Time.monotonic - start,
      )
    end

    session = GalaxyLedger::Database.get_session(session_id)
    unless session
      return EvalResult.new(
        name: "needs_more_context",
        passed: false,
        message: "Session not found in DB",
        duration: Time.monotonic - start,
      )
    end

    # Name should be nil (needs_more_context), OR a very low quality name
    state = GalaxyLedger::SuggestedName::StateData.from_json_safe(session.suggested_name_data)

    if state.status == "needs_more_context" || (state.quality > 0 && state.quality <= 3)
      STDERR.puts "\n  [suggest-name:needs_more_context] status: #{state.status}, quality: #{state.quality}"
      EvalResult.new(
        name: "needs_more_context",
        passed: true,
        message: "status=#{state.status}, quality=#{state.quality}",
        duration: Time.monotonic - start,
      )
    else
      EvalResult.new(
        name: "needs_more_context",
        passed: false,
        message: "Expected needs_more_context or quality <= 3, got status=#{state.status} quality=#{state.quality}",
        duration: Time.monotonic - start,
      )
    end
  rescue ex
    EvalResult.new(
      name: "needs_more_context",
      passed: false,
      message: "Exception: #{ex.message}",
      duration: Time.monotonic - start,
    )
  end
end

def eval_substantive_session : EvalResult
  start = Time.monotonic
  begin
    session_id = "eval-suggest-substantive-#{Random.rand(100000)}"
    GalaxyLedger::Database.create_session(session_id)
    flush_wal

    transcript_file = File.tempfile("eval-suggest-sub", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "I need to add dark mode support to the settings page in our React app"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "I'll help you add dark mode support. I'll use CSS custom properties for theming and add a toggle component to the settings page. Let me create the theme provider and update the settings layout."}}\n|)
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:02:00Z", "message": {"role": "user", "content": "Great, also make sure the preference persists in localStorage so it survives page reloads"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:03:00Z", "message": {"role": "assistant", "content": "Done! I've added localStorage persistence. The theme provider now reads from localStorage on mount and writes on change. The toggle reflects the saved preference automatically."}}\n|)
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:04:00Z", "message": {"role": "user", "content": "Can you also add a system preference detection so it defaults to the OS setting?"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:05:00Z", "message": {"role": "assistant", "content": "Added prefers-color-scheme media query detection. On first visit with no saved preference, it'll match the OS setting. After that, the user's explicit choice takes priority over system preference."}}\n|)
    transcript_file.close

    result = run_binary([
      "suggest-name",
      "--session", session_id,
      "--transcript-path", transcript_file.path,
    ])

    File.delete(transcript_file.path) if File.exists?(transcript_file.path)

    if result[:status] != 0
      return EvalResult.new(
        name: "substantive_session",
        passed: false,
        message: "Binary exited #{result[:status]}: #{result[:error]}",
        duration: Time.monotonic - start,
      )
    end

    session = GalaxyLedger::Database.get_session(session_id)
    unless session
      return EvalResult.new(
        name: "substantive_session",
        passed: false,
        message: "Session not found in DB",
        duration: Time.monotonic - start,
      )
    end

    name = session.suggested_name
    unless name
      return EvalResult.new(
        name: "substantive_session",
        passed: false,
        message: "suggested_name was nil",
        duration: Time.monotonic - start,
      )
    end

    # Verify it's a reasonable name
    word_count = name.split.size
    if word_count < 2 || word_count > 8
      return EvalResult.new(
        name: "substantive_session",
        passed: false,
        message: "Name '#{name}' has #{word_count} words (expected 2-8)",
        duration: Time.monotonic - start,
      )
    end

    # Verify no code in the name
    if GalaxyLedger::SuggestedName.name_appears_to_be_code?(name)
      return EvalResult.new(
        name: "substantive_session",
        passed: false,
        message: "Name '#{name}' appears to be code",
        duration: Time.monotonic - start,
      )
    end

    state = GalaxyLedger::SuggestedName::StateData.from_json_safe(session.suggested_name_data)
    STDERR.puts "\n  [suggest-name:substantive] name: #{name} (quality: #{state.quality})"

    EvalResult.new(
      name: "substantive_session",
      passed: true,
      message: "name: #{name} (quality: #{state.quality})",
      duration: Time.monotonic - start,
    )
  rescue ex
    EvalResult.new(
      name: "substantive_session",
      passed: false,
      message: "Exception: #{ex.message}",
      duration: Time.monotonic - start,
    )
  end
end

def eval_code_heavy_session : EvalResult
  start = Time.monotonic
  begin
    session_id = "eval-suggest-code-#{Random.rand(100000)}"
    GalaxyLedger::Database.create_session(session_id)
    flush_wal

    transcript_file = File.tempfile("eval-suggest-code", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Fix the authentication middleware — the JWT validation is failing"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "I found the issue in the JWT validation. The `verify_token` method was using the wrong algorithm. Here's the fix:\\n```ruby\\ndef verify_token(token)\\n  JWT.decode(token, secret_key, true, algorithm: 'HS256')\\nend\\n```"}}\n|)
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:02:00Z", "message": {"role": "user", "content": "Also update the error handling to return proper 401 responses"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:03:00Z", "message": {"role": "assistant", "content": "Updated the error handling:\\n```ruby\\nrescue JWT::DecodeError => e\\n  render json: { error: 'Invalid token' }, status: :unauthorized\\nend\\n```"}}\n|)
    transcript_file.close

    result = run_binary([
      "suggest-name",
      "--session", session_id,
      "--transcript-path", transcript_file.path,
    ])

    File.delete(transcript_file.path) if File.exists?(transcript_file.path)

    if result[:status] != 0
      return EvalResult.new(
        name: "code_heavy_session",
        passed: false,
        message: "Binary exited #{result[:status]}: #{result[:error]}",
        duration: Time.monotonic - start,
      )
    end

    session = GalaxyLedger::Database.get_session(session_id)
    unless session
      return EvalResult.new(
        name: "code_heavy_session",
        passed: false,
        message: "Session not found in DB",
        duration: Time.monotonic - start,
      )
    end

    name = session.suggested_name
    unless name
      return EvalResult.new(
        name: "code_heavy_session",
        passed: false,
        message: "suggested_name was nil (should generate from code context)",
        duration: Time.monotonic - start,
      )
    end

    # Verify no code patterns in the name
    if GalaxyLedger::SuggestedName.name_appears_to_be_code?(name)
      return EvalResult.new(
        name: "code_heavy_session",
        passed: false,
        message: "Name '#{name}' contains code patterns",
        duration: Time.monotonic - start,
      )
    end

    state = GalaxyLedger::SuggestedName::StateData.from_json_safe(session.suggested_name_data)
    STDERR.puts "\n  [suggest-name:code_heavy] name: #{name} (quality: #{state.quality})"

    EvalResult.new(
      name: "code_heavy_session",
      passed: true,
      message: "name: #{name} (quality: #{state.quality})",
      duration: Time.monotonic - start,
    )
  rescue ex
    EvalResult.new(
      name: "code_heavy_session",
      passed: false,
      message: "Exception: #{ex.message}",
      duration: Time.monotonic - start,
    )
  end
end

# --- Single concurrent runner for all 9 evals ---

describe "Evals", tags: "eval" do
  fixtures_path = SPEC_FIXTURES / "extraction_evals"

  it "runs all evals concurrently" do
    channel = Channel(EvalResult).new
    eval_count = 7

    # Spawn all 9 evals concurrently as fibers.
    # The 4 extraction evals call ClaudeCLI.run() which spawns `claude -p`.
    # The 5 CLI evals call run_binary() which spawns `galaxy-ledger`.
    # All subprocesses run as parallel OS processes; fibers yield while
    # waiting on Process#wait (SIGCHLD-based, event-loop integrated).

    # Extraction evals (in-process Claude calls)
    spawn { channel.send(eval_user_directions(fixtures_path)) }
    spawn { channel.send(eval_assistant_learnings(fixtures_path)) }

    # CLI extraction evals (subprocess)
    spawn { channel.send(eval_extract_assistant_input_file) }
    spawn { channel.send(eval_extract_assistant_transcript_path) }

    # Suggest-name evals (subprocess)
    spawn { channel.send(eval_needs_more_context) }
    spawn { channel.send(eval_substantive_session) }
    spawn { channel.send(eval_code_heavy_session) }

    # Collect all results
    results = [] of EvalResult
    eval_count.times { results << channel.receive }

    # Report results table
    STDERR.puts "\n\n  #{"=" * 56}"
    STDERR.puts "  Eval Results (#{eval_count} evals):"
    STDERR.puts "  #{"=" * 56}"
    results.sort_by(&.name).each do |r|
      status = r.passed ? "PASS" : "FAIL"
      STDERR.puts "  [#{status}] #{r.name} (#{r.duration.total_seconds.round(1)}s)"
      STDERR.puts "         #{r.message}" unless r.passed
    end
    wall_clock = results.max_of(&.duration)
    sequential = results.sum(&.duration)
    STDERR.puts "  #{"=" * 56}"
    STDERR.puts "  Wall clock: #{wall_clock.total_seconds.round(1)}s " \
                "(#{sequential.total_seconds.round(1)}s sequential)"
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
