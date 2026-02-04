require "../spec_helper"

# These specs call the actual Claude CLI and test extraction quality
# They are tagged with "eval" so they can be run separately:
#   crystal spec spec/extraction/extraction_eval_spec.cr
#
# These tests verify the extraction prompts work correctly with real Claude

describe "Extraction Evals", tags: "eval" do
  fixtures_path = SPEC_FIXTURES / "extraction_evals"

  describe "User Prompt Extraction" do
    fixture_dir = fixtures_path / "user_prompts"

    Dir.glob("#{fixture_dir}/*.txt").sort.each do |txt_file|
      expected_file = txt_file.gsub(".txt", ".expected.json")
      next unless File.exists?(expected_file)

      test_name = File.basename(txt_file, ".txt")

      it "extracts correctly: #{test_name}" do
        content = File.read(txt_file)
        expected = JSON.parse(File.read(expected_file))

        result = GalaxyLedger::Extraction.extract_user_directions(content)

        description = expected["description"]?.try(&.as_s?) || test_name

        if expected_count = expected["expected_count"]?.try(&.as_i?)
          result.extractions.size.should eq(expected_count),
            "#{description}: expected #{expected_count} extractions, got #{result.extractions.size}"
        end

        if min_count = expected["expected_count_min"]?.try(&.as_i?)
          result.extractions.size.should be >= min_count,
            "#{description}: expected at least #{min_count} extractions, got #{result.extractions.size}"
        end

        if max_count = expected["expected_count_max"]?.try(&.as_i?)
          result.extractions.size.should be <= max_count,
            "#{description}: expected at most #{max_count} extractions, got #{result.extractions.size}"
        end

        # Log results for debugging
        if result.extractions.any?
          STDERR.puts "\n  [#{test_name}] Extractions:"
          result.extractions.each do |e|
            STDERR.puts "    - #{e.entry_type} (#{e.importance}): #{e.content[0, 60]}..."
          end
        end
      end
    end
  end

  describe "Assistant Response Extraction" do
    fixture_dir = fixtures_path / "assistant_responses"

    Dir.glob("#{fixture_dir}/*.txt").sort.each do |txt_file|
      expected_file = txt_file.gsub(".txt", ".expected.json")
      next unless File.exists?(expected_file)

      test_name = File.basename(txt_file, ".txt")

      it "extracts correctly: #{test_name}" do
        content = File.read(txt_file)
        expected = JSON.parse(File.read(expected_file))

        # Use a simple user message for context
        user_message = "Implement the feature"

        result = GalaxyLedger::Extraction.extract_assistant_learnings(user_message, content)

        description = expected["description"]?.try(&.as_s?) || test_name

        if min_count = expected["expected_count_min"]?.try(&.as_i?)
          result.extractions.size.should be >= min_count,
            "#{description}: expected at least #{min_count} extractions, got #{result.extractions.size}"
        end

        if max_count = expected["expected_count_max"]?.try(&.as_i?)
          result.extractions.size.should be <= max_count,
            "#{description}: expected at most #{max_count} extractions, got #{result.extractions.size}"
        end

        if expected["should_have_summary"]?.try(&.as_bool?)
          result.summary.should_not be_nil, "#{description}: expected a summary"
        end

        # Log results for debugging
        STDERR.puts "\n  [#{test_name}]"
        if summary = result.summary
          STDERR.puts "    Summary: #{summary.assistant_response[0, 80]}..."
        end
        if result.extractions.any?
          STDERR.puts "    Extractions:"
          result.extractions.each do |e|
            STDERR.puts "      - #{e.entry_type} (#{e.importance}): #{e.content[0, 60]}..."
          end
        end
      end
    end
  end

  describe "Guideline Extraction" do
    fixture_dir = fixtures_path / "guidelines"

    Dir.glob("#{fixture_dir}/*.md").sort.each do |md_file|
      expected_file = md_file.gsub(".md", ".expected.json")
      next unless File.exists?(expected_file)

      test_name = File.basename(md_file, ".md")

      it "extracts correctly: #{test_name}" do
        content = File.read(md_file)
        expected = JSON.parse(File.read(expected_file))

        result = GalaxyLedger::Extraction.extract_guidelines(md_file, content)

        description = expected["description"]?.try(&.as_s?) || test_name

        if min_count = expected["expected_count_min"]?.try(&.as_i?)
          result.extractions.size.should be >= min_count,
            "#{description}: expected at least #{min_count} extractions, got #{result.extractions.size}"
        end

        # All extractions should be type "guideline"
        result.extractions.each do |e|
          e.entry_type.should eq("guideline"),
            "#{description}: expected guideline type, got #{e.entry_type}"
        end

        # Log results for debugging
        STDERR.puts "\n  [#{test_name}] Guidelines:"
        result.extractions.each do |e|
          STDERR.puts "    - (#{e.importance}): #{e.content[0, 70]}..."
        end
      end
    end
  end

  describe "Implementation Plan Extraction" do
    fixture_dir = fixtures_path / "implementation_plans"

    Dir.glob("#{fixture_dir}/*.md").sort.each do |md_file|
      expected_file = md_file.gsub(".md", ".expected.json")
      next unless File.exists?(expected_file)

      test_name = File.basename(md_file, ".md")

      it "extracts correctly: #{test_name}" do
        content = File.read(md_file)
        expected = JSON.parse(File.read(expected_file))

        result = GalaxyLedger::Extraction.extract_implementation_plan(md_file, content)

        description = expected["description"]?.try(&.as_s?) || test_name

        if min_count = expected["expected_count_min"]?.try(&.as_i?)
          result.extractions.size.should be >= min_count,
            "#{description}: expected at least #{min_count} extractions, got #{result.extractions.size}"
        end

        # All extractions should be type "implementation_plan"
        result.extractions.each do |e|
          e.entry_type.should eq("implementation_plan"),
            "#{description}: expected implementation_plan type, got #{e.entry_type}"
        end

        # Log results for debugging
        STDERR.puts "\n  [#{test_name}] Implementation Plan Context:"
        result.extractions.each do |e|
          STDERR.puts "    - (#{e.importance}): #{e.content[0, 70]}..."
        end
      end
    end
  end
end
