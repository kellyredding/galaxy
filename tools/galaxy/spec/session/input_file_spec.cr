require "../spec_helper"

private def problems(source : String) : Array(String)
  result = Galaxy::InputFile.parse(source)
  result.should be_a(Array(String))
  result.as(Array(String))
end

private def parsed(source : String) : Galaxy::InputFile::Parsed
  result = Galaxy::InputFile.parse(source)
  result.should be_a(Galaxy::InputFile::Parsed)
  result.as(Galaxy::InputFile::Parsed)
end

describe Galaxy::InputFile do
  describe "valid files" do
    it "accepts a plain message" do
      input = parsed(%({"message": "Fix the flaky spec.\\n\\nThen report."}))
      input.message.should eq("Fix the flaky spec.\n\nThen report.")
      input.notes.should be_empty
      input.to_detail.should eq({"message" => JSON::Any.new("Fix the flaky spec.\n\nThen report.")})
    end

    it "accepts notes with a summary" do
      input = parsed(<<-JSON)
        {"summary": "Two things.",
         "notes": [
           {"quote": "I renamed the method", "note": "Keep the old name as an alias"},
           {"quote": "Tests pass", "note": "Which suite?"}
         ]}
        JSON
      input.summary.should eq("Two things.")
      input.note_count.should eq(2)
      input.notes[1].quote.should eq("Tests pass")
      detail = input.to_detail
      detail["summary"].as_s.should eq("Two things.")
      detail["notes"].as_a[0]["note"].as_s.should eq("Keep the old name as an alias")
      detail.has_key?("message").should be_false
    end

    it "accepts notes without a summary" do
      input = parsed(%({"notes": [{"quote": "a", "note": "b"}]}))
      input.summary.should be_nil
      input.to_detail.has_key?("summary").should be_false
    end
  end

  describe "invalid files" do
    it "rejects text that is not JSON" do
      problems("not json").first.should start_with("file: not valid JSON")
    end

    it "rejects a top level that is not an object" do
      problems(%(["message"])).should eq(["file: must be a JSON object"])
    end

    it "needs message or notes" do
      problems(%({"summary": "x"})).should contain("file: needs message or notes")
    end

    it "refuses message and notes together" do
      problems(%({"message": "a", "notes": [{"quote": "q", "note": "n"}]}))
        .should contain("file: give either message or notes, not both")
    end

    it "refuses a summary beside a message" do
      problems(%({"message": "a", "summary": "b"})).should eq(["summary: only allowed with notes"])
    end

    it "rejects unknown keys at the top and inside notes" do
      found = problems(%({"mesage": "typo", "notes": [{"quote": "q", "note": "n", "extra": 1}]}))
      found.should contain("mesage: unknown key")
      found.should contain("notes[0].extra: unknown key")
    end

    it "rejects empty and non-string values" do
      problems(%({"message": "   "})).should eq(["message: must not be empty"])
      problems(%({"message": 3})).should eq(["message: must be a string"])
    end

    it "rejects an empty or non-array notes" do
      problems(%({"notes": []})).should eq(["notes: must not be empty"])
      problems(%({"notes": {"quote": "q"}})).should eq(["notes: must be an array"])
    end

    it "reports every note problem with its path, all at once" do
      found = problems(<<-JSON)
        {"notes": [
          {"quote": "fine", "note": "fine"},
          "a string",
          {"note": "no quote"},
          {"quote": "", "note": 5}
        ]}
        JSON
      found.should eq([
        "notes[1]: must be an object",
        "notes[2].quote: missing",
        "notes[3].quote: must not be empty",
        "notes[3].note: must be a string",
      ])
    end
  end
end
