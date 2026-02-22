require "../spec_helper"

# Smoke tests that call the actual Claude CLI to verify name suggestion prompts
# produce parseable, reasonable output.
#
# Tagged "eval" — excluded from default `crystal spec` runs.
# Run explicitly:  crystal spec --tag eval
#                  make test-eval
#
# Parsing correctness is covered by suggested_name_spec.cr (fast, stubbed).
# These only validate that Claude + our prompts return sensible results.
#
# All evals run CONCURRENTLY using fibers. Each eval is ~15-20s (Haiku
# one-shot latency), so concurrent execution reduces wall-clock.

record SuggestNameEvalResult,
  name : String,
  passed : Bool,
  message : String,
  duration : Time::Span

def eval_needs_more_context : SuggestNameEvalResult
  start = Time.monotonic
  begin
    # Create a session with minimal context (just a greeting)
    session_id = "eval-suggest-needs-ctx-#{Random.rand(100000)}"
    GalaxyLedger::Database.create_session(session_id)

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
      return SuggestNameEvalResult.new(
        name: "needs_more_context",
        passed: false,
        message: "Binary exited #{result[:status]}: #{result[:error]}",
        duration: Time.monotonic - start,
      )
    end

    session = GalaxyLedger::Database.get_session(session_id)
    unless session
      return SuggestNameEvalResult.new(
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
      SuggestNameEvalResult.new(
        name: "needs_more_context",
        passed: true,
        message: "status=#{state.status}, quality=#{state.quality}",
        duration: Time.monotonic - start,
      )
    else
      SuggestNameEvalResult.new(
        name: "needs_more_context",
        passed: false,
        message: "Expected needs_more_context or quality <= 3, got status=#{state.status} quality=#{state.quality}",
        duration: Time.monotonic - start,
      )
    end
  rescue ex
    SuggestNameEvalResult.new(
      name: "needs_more_context",
      passed: false,
      message: "Exception: #{ex.message}",
      duration: Time.monotonic - start,
    )
  end
end

def eval_substantive_session : SuggestNameEvalResult
  start = Time.monotonic
  begin
    session_id = "eval-suggest-substantive-#{Random.rand(100000)}"
    GalaxyLedger::Database.create_session(session_id)

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
      return SuggestNameEvalResult.new(
        name: "substantive_session",
        passed: false,
        message: "Binary exited #{result[:status]}: #{result[:error]}",
        duration: Time.monotonic - start,
      )
    end

    session = GalaxyLedger::Database.get_session(session_id)
    unless session
      return SuggestNameEvalResult.new(
        name: "substantive_session",
        passed: false,
        message: "Session not found in DB",
        duration: Time.monotonic - start,
      )
    end

    name = session.suggested_name
    unless name
      return SuggestNameEvalResult.new(
        name: "substantive_session",
        passed: false,
        message: "suggested_name was nil",
        duration: Time.monotonic - start,
      )
    end

    # Verify it's a reasonable name
    word_count = name.split.size
    if word_count < 2 || word_count > 8
      return SuggestNameEvalResult.new(
        name: "substantive_session",
        passed: false,
        message: "Name '#{name}' has #{word_count} words (expected 2-8)",
        duration: Time.monotonic - start,
      )
    end

    # Verify no code in the name
    if GalaxyLedger::SuggestedName.name_appears_to_be_code?(name)
      return SuggestNameEvalResult.new(
        name: "substantive_session",
        passed: false,
        message: "Name '#{name}' appears to be code",
        duration: Time.monotonic - start,
      )
    end

    state = GalaxyLedger::SuggestedName::StateData.from_json_safe(session.suggested_name_data)
    STDERR.puts "\n  [suggest-name:substantive] name: #{name} (quality: #{state.quality})"

    SuggestNameEvalResult.new(
      name: "substantive_session",
      passed: true,
      message: "name: #{name} (quality: #{state.quality})",
      duration: Time.monotonic - start,
    )
  rescue ex
    SuggestNameEvalResult.new(
      name: "substantive_session",
      passed: false,
      message: "Exception: #{ex.message}",
      duration: Time.monotonic - start,
    )
  end
end

def eval_code_heavy_session : SuggestNameEvalResult
  start = Time.monotonic
  begin
    session_id = "eval-suggest-code-#{Random.rand(100000)}"
    GalaxyLedger::Database.create_session(session_id)

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
      return SuggestNameEvalResult.new(
        name: "code_heavy_session",
        passed: false,
        message: "Binary exited #{result[:status]}: #{result[:error]}",
        duration: Time.monotonic - start,
      )
    end

    session = GalaxyLedger::Database.get_session(session_id)
    unless session
      return SuggestNameEvalResult.new(
        name: "code_heavy_session",
        passed: false,
        message: "Session not found in DB",
        duration: Time.monotonic - start,
      )
    end

    name = session.suggested_name
    unless name
      return SuggestNameEvalResult.new(
        name: "code_heavy_session",
        passed: false,
        message: "suggested_name was nil (should generate from code context)",
        duration: Time.monotonic - start,
      )
    end

    # Verify no code patterns in the name
    if GalaxyLedger::SuggestedName.name_appears_to_be_code?(name)
      return SuggestNameEvalResult.new(
        name: "code_heavy_session",
        passed: false,
        message: "Name '#{name}' contains code patterns",
        duration: Time.monotonic - start,
      )
    end

    state = GalaxyLedger::SuggestedName::StateData.from_json_safe(session.suggested_name_data)
    STDERR.puts "\n  [suggest-name:code_heavy] name: #{name} (quality: #{state.quality})"

    SuggestNameEvalResult.new(
      name: "code_heavy_session",
      passed: true,
      message: "name: #{name} (quality: #{state.quality})",
      duration: Time.monotonic - start,
    )
  rescue ex
    SuggestNameEvalResult.new(
      name: "code_heavy_session",
      passed: false,
      message: "Exception: #{ex.message}",
      duration: Time.monotonic - start,
    )
  end
end

# --- Concurrent runner ---

describe "SuggestedName Evals", tags: "eval" do
  it "runs all suggest-name evals concurrently" do
    channel = Channel(SuggestNameEvalResult).new
    eval_count = 3

    spawn { channel.send(eval_needs_more_context) }
    spawn { channel.send(eval_substantive_session) }
    spawn { channel.send(eval_code_heavy_session) }

    results = [] of SuggestNameEvalResult
    eval_count.times { results << channel.receive }

    # Report results table
    STDERR.puts "\n\n  #{"=" * 56}"
    STDERR.puts "  SuggestedName Eval Results:"
    STDERR.puts "  #{"=" * 56}"
    results.sort_by(&.name).each do |r|
      status = r.passed ? "PASS" : "FAIL"
      STDERR.puts "  [#{status}] #{r.name} (#{r.duration.total_seconds.round(1)}s)"
      STDERR.puts "         #{r.message}" unless r.passed
    end
    wall_clock = results.max_of(&.duration)
    STDERR.puts "  #{"=" * 56}"
    STDERR.puts "  Wall clock: #{wall_clock.total_seconds.round(1)}s " \
                "(was ~#{eval_count * 20}s sequential)"
    STDERR.puts ""

    failures = results.reject(&.passed)
    if failures.any?
      fail_messages = failures.map { |f| "#{f.name}: #{f.message}" }
      fail("#{failures.size}/#{eval_count} evals failed:\n" +
           fail_messages.join("\n"))
    end
  end
end
