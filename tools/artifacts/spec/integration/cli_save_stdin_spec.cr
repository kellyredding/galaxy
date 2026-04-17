require "../spec_helper"
require "digest/sha256"

describe "CLI save (stdin mode)", tags: "integration" do
  it "saves an artifact from stdin with explicit filename" do
    content = %({"hello": "world"})

    result = run_binary(
      [
        "save",
        "--ledger-session-id", "1",
        "--filename", "payload.json",
        "--title", "Stdin JSON",
        "--artifact-type", "json",
        "--mime-type", "application/json",
      ],
      stdin: content,
    )

    result[:status].should eq(0)
    result[:output].should contain("Artifact #1 saved")
    result[:output].should contain("Stdin JSON")

    # Verify DB state: stored_path set, source_path nil.
    flush_wal
    artifact = GalaxyArtifacts::Database.get_artifact_by_number(
      1_i64, 1,
    )
    artifact.should_not be_nil
    art = artifact.not_nil!
    art.source_path.should be_nil
    art.stored_path.should_not be_empty
    art.original_filename.should eq("payload.json")

    # Verify stream hash and size match what was piped in.
    expected_hash = Digest::SHA256.hexdigest(content)
    art.content_hash.should eq(expected_hash)
    art.file_size.should eq(content.bytesize.to_i64)

    # Verify the file on disk has exactly the piped bytes.
    File.exists?(art.stored_path).should be_true
    File.read(art.stored_path).should eq(content)
  end

  it "derives title from filename when not provided" do
    result = run_binary(
      [
        "save",
        "--ledger-session-id", "1",
        "--filename", "quarterly-report.gdiff",
      ],
      stdin: "diff content",
    )

    result[:status].should eq(0)
    result[:output].should contain("quarterly report")
  end

  it "errors when --filename is missing and stdin piped" do
    # source_path absent + filename absent + stdin piped —
    # should error on the --filename requirement, not crash.
    result = run_binary(
      ["save", "--ledger-session-id", "1"],
      stdin: "some content",
    )

    result[:status].should_not eq(0)
    result[:error].should contain(
      "--filename is required when --source-path is not provided",
    )
  end

  it "errors when stdin is empty" do
    result = run_binary(
      [
        "save",
        "--ledger-session-id", "1",
        "--filename", "empty.txt",
      ],
      stdin: "",
    )

    result[:status].should_not eq(0)
    result[:error].should contain("failed to stream content to storage")
  end

  it "assigns sequential numbers across multiple stdin saves" do
    3.times do |i|
      result = run_binary(
        [
          "save",
          "--ledger-session-id", "1",
          "--filename", "note-#{i}.txt",
          "--title", "Note #{i}",
        ],
        stdin: "content #{i}",
      )
      result[:status].should eq(0)
      result[:output].should contain("Artifact ##{i + 1} saved")
    end

    flush_wal
    list = GalaxyArtifacts::Database.list_artifacts(1_i64)
    list.size.should eq(3)
    list.map(&.number).should eq([1, 2, 3])
    list.all?(&.source_path.nil?).should be_true
  end

  it "does not trigger dedup between identical stdin saves" do
    # Unlike --source-path, stdin saves with the same content
    # should always insert new artifacts (no Enrichment, no
    # VersionUpdate).
    2.times do
      result = run_binary(
        [
          "save",
          "--ledger-session-id", "1",
          "--filename", "same.txt",
          "--title", "Same payload",
        ],
        stdin: "identical bytes",
      )
      result[:status].should eq(0)
      result[:output].should contain("saved")
      result[:output].should_not contain("updated")
    end

    flush_wal
    list = GalaxyArtifacts::Database.list_artifacts(1_i64)
    list.size.should eq(2)
  end

  it "streams large stdin without buffering in memory" do
    # 1 MB of content — verifies we don't choke on content
    # bigger than a single 64 KB read buffer and that the
    # streamed hash/size still match.
    content = "A" * 1_048_576

    result = run_binary(
      [
        "save",
        "--ledger-session-id", "1",
        "--filename", "big.bin",
        "--artifact-type", "binary",
      ],
      stdin: content,
    )

    result[:status].should eq(0)

    flush_wal
    art = GalaxyArtifacts::Database.get_artifact_by_number(
      1_i64, 1,
    ).not_nil!
    art.file_size.should eq(1_048_576_i64)
    art.content_hash.should eq(Digest::SHA256.hexdigest(content))
    File.size(art.stored_path).should eq(1_048_576)
  end
end
