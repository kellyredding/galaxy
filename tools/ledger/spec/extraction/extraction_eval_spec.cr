require "../spec_helper"

# Smoke tests that call the actual Claude CLI to verify extraction prompts
# produce parseable, reasonable output. One test per extraction type.
#
# Tagged "eval" — excluded from default `crystal spec` runs.
# Run explicitly:  crystal spec --tag eval
#                  make test-eval
#
# Parsing correctness is covered by extraction_pipeline_spec.cr (fast, stubbed).
# These only validate that Claude + our prompts return sensible results.

describe "Extraction Evals", tags: "eval" do
  fixtures_path = SPEC_FIXTURES / "extraction_evals"

  it "user prompt extraction: direction_explicit" do
    content = File.read(fixtures_path / "user_prompts" / "02_direction_explicit.txt")

    result = GalaxyLedger::Extraction.extract_user_directions(content)
    result.extractions.size.should eq(2),
      "Expected 2 direction extractions, got #{result.extractions.size}"

    # Log results
    STDERR.puts "\n  [user:direction_explicit] Extractions:"
    result.extractions.each do |e|
      STDERR.puts "    - #{e.entry_type} (#{e.importance}): #{e.content[0, 60]}..."
    end
  end

  it "assistant response extraction: decision_with_rationale" do
    content = File.read(fixtures_path / "assistant_responses" / "02_decision_with_rationale.txt")

    result = GalaxyLedger::Extraction.extract_assistant_learnings("Implement the feature", content)
    result.extractions.size.should be >= 1,
      "Expected at least 1 extraction, got #{result.extractions.size}"
    result.summary.should_not be_nil, "Expected a summary"

    # Log results
    STDERR.puts "\n  [assistant:decision_with_rationale]"
    if summary = result.summary
      STDERR.puts "    Summary: #{summary.assistant_response[0, 80]}..."
    end
    result.extractions.each do |e|
      STDERR.puts "    - #{e.entry_type} (#{e.importance}): #{e.content[0, 60]}..."
    end
  end

  it "guideline extraction: ruby_style" do
    md_file = (fixtures_path / "guidelines" / "01_ruby_style.md").to_s
    content = File.read(md_file)

    result = GalaxyLedger::Extraction.extract_guidelines(md_file, content)
    result.extractions.size.should be >= 4,
      "Expected at least 4 guideline extractions, got #{result.extractions.size}"

    result.extractions.each do |e|
      e.entry_type.should eq("guideline"),
        "Expected guideline type, got #{e.entry_type}"
    end

    # Log results
    STDERR.puts "\n  [guideline:ruby_style] Guidelines:"
    result.extractions.each do |e|
      STDERR.puts "    - (#{e.importance}): #{e.content[0, 70]}..."
    end
  end

  it "implementation plan extraction: phased_plan" do
    md_file = (fixtures_path / "implementation_plans" / "01_phased_plan.md").to_s
    content = File.read(md_file)

    result = GalaxyLedger::Extraction.extract_implementation_plan(md_file, content)
    result.extractions.size.should be >= 2,
      "Expected at least 2 implementation_plan extractions, got #{result.extractions.size}"

    result.extractions.each do |e|
      e.entry_type.should eq("implementation_plan"),
        "Expected implementation_plan type, got #{e.entry_type}"
    end

    # Log results
    STDERR.puts "\n  [impl_plan:phased_plan] Context:"
    result.extractions.each do |e|
      STDERR.puts "    - (#{e.importance}): #{e.content[0, 70]}..."
    end
  end
end
