require "./spec_helper"

describe GalaxyDiff::GdiffLineType do
  it "serializes as lowercase strings" do
    GalaxyDiff::GdiffLineType::Context.to_json.should eq(
      %("context"),
    )
    GalaxyDiff::GdiffLineType::Add.to_json.should eq(
      %("add"),
    )
    GalaxyDiff::GdiffLineType::Delete.to_json.should eq(
      %("delete"),
    )
  end

  it "parses lowercase strings back (case-insensitive)" do
    t = GalaxyDiff::GdiffLineType.from_json(%("context"))
    t.should eq(GalaxyDiff::GdiffLineType::Context)

    GalaxyDiff::GdiffLineType.from_json(%("add"))
      .should eq(GalaxyDiff::GdiffLineType::Add)
    GalaxyDiff::GdiffLineType.from_json(%("delete"))
      .should eq(GalaxyDiff::GdiffLineType::Delete)
  end
end

describe GalaxyDiff::GdiffLine do
  it "round-trips through JSON" do
    line = GalaxyDiff::GdiffLine.new(
      type: GalaxyDiff::GdiffLineType::Add,
      old_no: nil,
      new_no: 42,
      content: "puts \"hi\"",
    )

    json = line.to_json
    parsed = GalaxyDiff::GdiffLine.from_json(json)

    parsed.type.should eq(GalaxyDiff::GdiffLineType::Add)
    parsed.old_no.should be_nil
    parsed.new_no.should eq(42)
    parsed.content.should eq(%(puts "hi"))
  end
end

describe GalaxyDiff::GdiffDocument do
  it "round-trips a complete document through JSON" do
    hunk = GalaxyDiff::GdiffHunk.new(
      old_start: 1, old_count: 2,
      new_start: 1, new_count: 3,
    )
    hunk.lines << GalaxyDiff::GdiffLine.new(
      type: GalaxyDiff::GdiffLineType::Context,
      old_no: 1, new_no: 1, content: "a",
    )
    hunk.lines << GalaxyDiff::GdiffLine.new(
      type: GalaxyDiff::GdiffLineType::Add,
      old_no: nil, new_no: 2, content: "b",
    )
    hunk.lines << GalaxyDiff::GdiffLine.new(
      type: GalaxyDiff::GdiffLineType::Delete,
      old_no: 2, new_no: nil, content: "c",
    )

    file = GalaxyDiff::GdiffFile.new(
      path: "src/foo.cr",
      old_path: nil,
      status: "modified",
      language: "crystal",
      before: "a\nc\n",
      after: "a\nb\n",
      hunks: [hunk],
    )

    metadata = GalaxyDiff::GdiffMetadata.new(
      ref_from: "a" * 40,
      ref_to: "working-tree",
      repo: "kellyredding/galaxy",
      created_at: "2026-04-17T00:00:00Z",
      summary: "1 file changed, 1 insertion, 1 deletion",
    )

    doc = GalaxyDiff::GdiffDocument.new(
      version: 1,
      metadata: metadata,
      files: [file],
    )

    json = doc.to_json
    parsed = GalaxyDiff::GdiffDocument.from_json(json)

    parsed.version.should eq(1)
    parsed.metadata.ref_from.should eq("a" * 40)
    parsed.metadata.ref_to.should eq("working-tree")
    parsed.metadata.repo.should eq("kellyredding/galaxy")
    parsed.metadata.summary.should eq(
      "1 file changed, 1 insertion, 1 deletion",
    )
    parsed.files.size.should eq(1)
    parsed.files[0].path.should eq("src/foo.cr")
    parsed.files[0].status.should eq("modified")
    parsed.files[0].language.should eq("crystal")
    parsed.files[0].hunks.size.should eq(1)
    parsed.files[0].hunks[0].lines.size.should eq(3)
    parsed.files[0].hunks[0].lines[1].type
      .should eq(GalaxyDiff::GdiffLineType::Add)
  end

  it "supports files with every status" do
    %w[modified added deleted renamed binary].each do |status|
      file = GalaxyDiff::GdiffFile.new(
        path: "f", old_path: nil, status: status,
        language: nil, before: nil, after: nil,
        hunks: [] of GalaxyDiff::GdiffHunk,
      )
      json = file.to_json
      parsed = GalaxyDiff::GdiffFile.from_json(json)
      parsed.status.should eq(status)
    end
  end
end
