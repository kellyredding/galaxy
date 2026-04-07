require "../spec_helper"

# Helper to save an artifact for annotation integration tests.
# Returns artifact DB ID.
def save_artifact_for_ann_integration : Int64
  source = create_test_file("ann-test.csv", "name,value\nfoo,42")
  run_binary([
    "save", "--ledger-session-id", "1",
    "--source-path", source, "--title", "Ann test",
    "--artifact-type", "csv", "--mime-type", "text/csv",
  ])
  flush_wal
  artifact = GalaxyArtifacts::Database.get_artifact_by_number(1_i64, 1)
  artifact.not_nil!.id
end

describe "CLI annotation commands", tags: "integration" do
  describe "annotation create" do
    it "creates an annotation from stdin JSON" do
      artifact_id = save_artifact_for_ann_integration
      input = %({"anchor_data":{"type":"line_range","start_line":1,"end_line":2},"content":"Needs error handling"})

      result = run_binary(
        ["annotation", "create", "--artifact-id", artifact_id.to_s],
        stdin: input,
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      ann = parsed["annotation"]
      ann["number"].as_i.should eq(1)
      ann["content"].as_s.should eq("Needs error handling")
      ann["stale"].as_bool.should be_false
      ann["anchor_data"]["type"].as_s.should eq("line_range")
    end

    it "assigns sequential numbers" do
      artifact_id = save_artifact_for_ann_integration

      input1 = %({"anchor_data":{"type":"whole_file"},"content":"First"})
      input2 = %({"anchor_data":{"type":"whole_file"},"content":"Second"})

      r1 = run_binary(
        ["annotation", "create", "--artifact-id", artifact_id.to_s],
        stdin: input1,
      )
      r2 = run_binary(
        ["annotation", "create", "--artifact-id", artifact_id.to_s],
        stdin: input2,
      )

      JSON.parse(r1[:output])["annotation"]["number"].as_i.should eq(1)
      JSON.parse(r2[:output])["annotation"]["number"].as_i.should eq(2)
    end

    it "errors with no stdin" do
      artifact_id = save_artifact_for_ann_integration

      result = run_binary(
        ["annotation", "create", "--artifact-id", artifact_id.to_s],
        stdin: "",
      )

      result[:status].should_not eq(0)
      result[:error].should contain("no input provided on stdin")
    end

    it "errors with invalid JSON" do
      artifact_id = save_artifact_for_ann_integration

      result = run_binary(
        ["annotation", "create", "--artifact-id", artifact_id.to_s],
        stdin: "not json",
      )

      result[:status].should_not eq(0)
      result[:error].should contain("invalid JSON")
    end

    it "errors when anchor_data is missing" do
      artifact_id = save_artifact_for_ann_integration

      result = run_binary(
        ["annotation", "create", "--artifact-id", artifact_id.to_s],
        stdin: %({"content":"no anchor"}),
      )

      result[:status].should_not eq(0)
      result[:error].should contain("anchor_data")
    end

    it "errors when content is missing" do
      artifact_id = save_artifact_for_ann_integration

      result = run_binary(
        ["annotation", "create", "--artifact-id", artifact_id.to_s],
        stdin: %({"anchor_data":{"type":"whole_file"}}),
      )

      result[:status].should_not eq(0)
      result[:error].should contain("content")
    end

    it "errors when no identifier provided" do
      result = run_binary(
        ["annotation", "create"],
        stdin: %({"anchor_data":{"type":"whole_file"},"content":"test"}),
      )

      result[:status].should_not eq(0)
      result[:error].should contain("--artifact-id")
    end
  end

  describe "annotation list" do
    it "lists annotations in human-readable format" do
      artifact_id = save_artifact_for_ann_integration

      run_binary(
        ["annotation", "create", "--artifact-id", artifact_id.to_s],
        stdin: %({"anchor_data":{"type":"whole_file"},"content":"First note"}),
      )
      run_binary(
        ["annotation", "create", "--artifact-id", artifact_id.to_s],
        stdin: %({"anchor_data":{"type":"whole_file"},"content":"Second note"}),
      )

      result = run_binary(
        ["annotation", "list", "--artifact-id", artifact_id.to_s],
      )

      result[:status].should eq(0)
      result[:output].should contain("2 total")
      result[:output].should contain("#1")
      result[:output].should contain("First note")
      result[:output].should contain("#2")
      result[:output].should contain("Second note")
    end

    it "lists annotations in JSON format" do
      artifact_id = save_artifact_for_ann_integration

      run_binary(
        ["annotation", "create", "--artifact-id", artifact_id.to_s],
        stdin: %({"anchor_data":{"type":"whole_file"},"content":"JSON test"}),
      )

      result = run_binary(
        ["annotation", "list", "--artifact-id", artifact_id.to_s, "--json"],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      anns = parsed["annotations"].as_a
      anns.size.should eq(1)
      anns[0]["number"].as_i.should eq(1)
      anns[0]["content"].as_s.should eq("JSON test")
    end

    it "shows empty message when no annotations" do
      artifact_id = save_artifact_for_ann_integration

      result = run_binary(
        ["annotation", "list", "--artifact-id", artifact_id.to_s],
      )

      result[:status].should eq(0)
      result[:output].should contain("No annotations")
    end
  end

  describe "annotation view" do
    it "returns annotation as JSON" do
      artifact_id = save_artifact_for_ann_integration

      run_binary(
        ["annotation", "create", "--artifact-id", artifact_id.to_s],
        stdin: %({"anchor_data":{"type":"line_range","start_line":1,"end_line":3},"content":"View me"}),
      )

      result = run_binary(
        ["annotation", "view", "--artifact-id", artifact_id.to_s, "1"],
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      ann = parsed["annotation"]
      ann["number"].as_i.should eq(1)
      ann["content"].as_s.should eq("View me")
      ann["anchor_data"]["type"].as_s.should eq("line_range")
    end

    it "errors when annotation not found" do
      artifact_id = save_artifact_for_ann_integration

      result = run_binary(
        ["annotation", "view", "--artifact-id", artifact_id.to_s, "99"],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end

    it "errors when number not provided" do
      artifact_id = save_artifact_for_ann_integration

      result = run_binary(
        ["annotation", "view", "--artifact-id", artifact_id.to_s],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("annotation number is required")
    end
  end

  describe "annotation update" do
    it "updates content from stdin" do
      artifact_id = save_artifact_for_ann_integration

      run_binary(
        ["annotation", "create", "--artifact-id", artifact_id.to_s],
        stdin: %({"anchor_data":{"type":"whole_file"},"content":"Original"}),
      )

      result = run_binary(
        ["annotation", "update", "--artifact-id", artifact_id.to_s, "1"],
        stdin: "Updated content",
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["annotation"]["content"].as_s.should eq("Updated content")
    end

    it "preserves anchor_data on update" do
      artifact_id = save_artifact_for_ann_integration
      anchor = %({"type":"line_range","start_line":5,"end_line":10})

      run_binary(
        ["annotation", "create", "--artifact-id", artifact_id.to_s],
        stdin: %({"anchor_data":#{anchor},"content":"Original"}),
      )

      result = run_binary(
        ["annotation", "update", "--artifact-id", artifact_id.to_s, "1"],
        stdin: "New content",
      )

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["annotation"]["anchor_data"]["type"].as_s.should eq("line_range")
      parsed["annotation"]["anchor_data"]["start_line"].as_i.should eq(5)
    end

    it "errors with no stdin" do
      artifact_id = save_artifact_for_ann_integration

      run_binary(
        ["annotation", "create", "--artifact-id", artifact_id.to_s],
        stdin: %({"anchor_data":{"type":"whole_file"},"content":"Original"}),
      )

      result = run_binary(
        ["annotation", "update", "--artifact-id", artifact_id.to_s, "1"],
        stdin: "",
      )

      result[:status].should_not eq(0)
      result[:error].should contain("no content provided on stdin")
    end

    it "errors when annotation not found" do
      artifact_id = save_artifact_for_ann_integration

      result = run_binary(
        ["annotation", "update", "--artifact-id", artifact_id.to_s, "99"],
        stdin: "content",
      )

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end
  end

  describe "annotation delete" do
    it "deletes an annotation" do
      artifact_id = save_artifact_for_ann_integration

      run_binary(
        ["annotation", "create", "--artifact-id", artifact_id.to_s],
        stdin: %({"anchor_data":{"type":"whole_file"},"content":"Delete me"}),
      )

      result = run_binary(
        ["annotation", "delete", "--artifact-id", artifact_id.to_s, "1"],
      )

      result[:status].should eq(0)
      result[:output].should contain("Annotation #1 deleted")

      # Verify it's gone
      list_result = run_binary(
        ["annotation", "list", "--artifact-id", artifact_id.to_s],
      )
      list_result[:output].should contain("No annotations")
    end

    it "errors when annotation not found" do
      artifact_id = save_artifact_for_ann_integration

      result = run_binary(
        ["annotation", "delete", "--artifact-id", artifact_id.to_s, "99"],
      )

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end
  end

  describe "annotation help" do
    it "shows annotation help" do
      result = run_binary(["annotation", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("annotation")
      result[:output].should contain("create")
      result[:output].should contain("list")
      result[:output].should contain("view")
      result[:output].should contain("update")
      result[:output].should contain("delete")
    end

    it "shows annotation create help" do
      result = run_binary(["annotation", "create", "--help"])

      result[:status].should eq(0)
      result[:output].should contain("anchor_data")
      result[:output].should contain("content")
    end
  end
end
