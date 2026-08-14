require "./spec_helper"

SHA40_RE = /\A[0-9a-f]{40}\z/

describe GalaxyDiff::DiffCapture do
  it "captures a modified file with before/after content" do
    with_temp_repo do |repo|
      File.write(File.join(repo, "app.rb"), "one\ntwo\n")
      git_commit(repo, "init")
      File.write(
        File.join(repo, "app.rb"), "one\ntwo\nthree\n",
      )

      doc = GalaxyDiff::DiffCapture.capture(
        from_ref: "HEAD", to_ref: nil, repo_path: repo,
      )

      doc.version.should eq(1)
      # ref_from "HEAD" resolves to the commit's SHA
      # (durable snapshot over the mutable HEAD ref).
      doc.metadata.ref_from.should match(SHA40_RE)
      doc.metadata.ref_to.should eq("working-tree")
      doc.files.size.should eq(1)

      f = doc.files[0]
      f.path.should eq("app.rb")
      f.status.should eq("modified")
      f.language.should eq("ruby")
      f.before.should eq("one\ntwo\n")
      f.after.should eq("one\ntwo\nthree\n")
      f.hunks.size.should eq(1)
    end
  end

  it "captures an added file (no before content)" do
    with_temp_repo do |repo|
      File.write(File.join(repo, "seed.rb"), "seed\n")
      git_commit(repo, "init")

      File.write(
        File.join(repo, "new.rb"), "new file\n",
      )
      # Staged so the untracked file appears in the diff.
      Process.run("git", ["add", "new.rb"], chdir: repo)

      doc = GalaxyDiff::DiffCapture.capture(
        from_ref: "HEAD", to_ref: "staged",
        repo_path: repo,
      )

      added = doc.files.find { |f| f.path == "new.rb" }
      added.should_not be_nil
      added = added.not_nil!
      added.status.should eq("added")
      added.before.should be_nil
      added.after.should eq("new file\n")
    end
  end

  it "captures a deleted file (no after content)" do
    with_temp_repo do |repo|
      File.write(File.join(repo, "gone.rb"), "bye\n")
      git_commit(repo, "init")
      File.delete(File.join(repo, "gone.rb"))

      doc = GalaxyDiff::DiffCapture.capture(
        from_ref: "HEAD", to_ref: nil, repo_path: repo,
      )

      f = doc.files.find { |ff| ff.path == "gone.rb" }
      # When a file is deleted, git's +++ line is
      # /dev/null and --- is a/gone.rb. The parser stores
      # old_path_raw but leaves path empty, so we search
      # via hunks/status.
      f = doc.files[0] if f.nil?
      f.should_not be_nil
      f = f.not_nil!
      f.status.should eq("deleted")
      f.after.should be_nil
      f.before.should eq("bye\n")
    end
  end

  it "captures a renamed file with old_path populated" do
    with_temp_repo do |repo|
      File.write(File.join(repo, "old.rb"), "hello\n")
      git_commit(repo, "init")

      File.rename(
        File.join(repo, "old.rb"),
        File.join(repo, "new.rb"),
      )
      Process.run(
        "git", ["add", "-A"], chdir: repo)

      doc = GalaxyDiff::DiffCapture.capture(
        from_ref: "HEAD", to_ref: "staged",
        repo_path: repo,
      )

      f = doc.files.find { |ff| ff.status == "renamed" }
      f.should_not be_nil
      f = f.not_nil!
      f.path.should eq("new.rb")
      f.old_path.should eq("old.rb")
      # Before content reads from old_path at HEAD.
      f.before.should eq("hello\n")
    end
  end

  it "captures an untracked file as added when diffing working tree" do
    with_temp_repo do |repo|
      File.write(File.join(repo, "seed.rb"), "seed\n")
      git_commit(repo, "init")

      File.write(
        File.join(repo, "fresh.rb"),
        "line one\nline two\n",
      )
      # Intentionally NOT staged — git diff would miss
      # this, but capture should synthesize an added
      # entry for it.

      doc = GalaxyDiff::DiffCapture.capture(
        from_ref: "HEAD", to_ref: nil, repo_path: repo,
      )

      f = doc.files.find { |ff| ff.path == "fresh.rb" }
      f.should_not be_nil
      f = f.not_nil!
      f.status.should eq("added")
      f.before.should be_nil
      f.after.should eq("line one\nline two\n")
      f.language.should eq("ruby")
      f.hunks.size.should eq(1)
      f.hunks[0].lines.size.should eq(2)
      f.hunks[0].lines.all?(&.type.add?).should be_true
    end
  end

  it "skips untracked files when diffing against an explicit ref" do
    with_temp_repo do |repo|
      File.write(File.join(repo, "seed.rb"), "seed\n")
      git_commit(repo, "init")

      File.write(File.join(repo, "fresh.rb"), "x\n")

      doc = GalaxyDiff::DiffCapture.capture(
        from_ref: "HEAD", to_ref: "HEAD", repo_path: repo,
      )

      doc.files.find { |ff| ff.path == "fresh.rb" }
        .should be_nil
    end
  end

  it "honors .gitignore when listing untracked files" do
    with_temp_repo do |repo|
      File.write(File.join(repo, ".gitignore"), "*.log\n")
      File.write(File.join(repo, "seed.rb"), "seed\n")
      Process.run(
        "git", ["add", "-A"], chdir: repo)
      git_commit(repo, "init")

      File.write(File.join(repo, "noisy.log"), "ignored\n")
      File.write(File.join(repo, "real.rb"), "kept\n")

      doc = GalaxyDiff::DiffCapture.capture(
        from_ref: "HEAD", to_ref: nil, repo_path: repo,
      )

      doc.files.find { |f| f.path == "noisy.log" }
        .should be_nil
      doc.files.find { |f| f.path == "real.rb" }
        .should_not be_nil
    end
  end

  it "captures between two commits" do
    with_temp_repo do |repo|
      File.write(File.join(repo, "f.rb"), "v1\n")
      git_commit(repo, "c1")
      File.write(File.join(repo, "f.rb"), "v2\n")
      git_commit(repo, "c2")

      doc = GalaxyDiff::DiffCapture.capture(
        from_ref: "HEAD~1", to_ref: "HEAD",
        repo_path: repo,
      )

      doc.files.size.should eq(1)
      f = doc.files[0]
      f.before.should eq("v1\n")
      f.after.should eq("v2\n")
    end
  end

  it "builds a summary reflecting line counts" do
    with_temp_repo do |repo|
      File.write(File.join(repo, "x.rb"), "a\nb\nc\n")
      git_commit(repo, "init")
      File.write(File.join(repo, "x.rb"), "a\nB\nc\nd\n")

      doc = GalaxyDiff::DiffCapture.capture(
        from_ref: "HEAD", to_ref: nil, repo_path: repo,
      )

      doc.metadata.summary.should eq(
        "1 file changed, 2 insertions, 1 deletion",
      )
    end
  end

  it "produces an empty files array when there are no changes" do
    with_temp_repo do |repo|
      File.write(File.join(repo, "f.rb"), "stable\n")
      git_commit(repo, "init")

      doc = GalaxyDiff::DiffCapture.capture(
        from_ref: "HEAD", to_ref: nil, repo_path: repo,
      )

      doc.files.should be_empty
      doc.metadata.summary.should eq(
        "0 files changed, 0 insertions, 0 deletions",
      )
    end
  end

  describe "ref resolution" do
    it "resolves both refs to SHAs for a commit-to-commit diff" do
      with_temp_repo do |repo|
        File.write(File.join(repo, "f.rb"), "v1\n")
        git_commit(repo, "c1")
        File.write(File.join(repo, "f.rb"), "v2\n")
        git_commit(repo, "c2")

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD~1", to_ref: "HEAD",
          repo_path: repo,
        )

        doc.metadata.ref_from.should match(SHA40_RE)
        doc.metadata.ref_to.should match(SHA40_RE)
        # Distinct commits → distinct SHAs.
        doc.metadata.ref_from.should_not eq(
          doc.metadata.ref_to,
        )
      end
    end

    it "resolves branch names to their tip commit SHA" do
      with_temp_repo do |repo|
        File.write(File.join(repo, "f.rb"), "v1\n")
        git_commit(repo, "init")

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "main", to_ref: nil, repo_path: repo,
        )

        doc.metadata.ref_from.should match(SHA40_RE)
      end
    end

    it "stores 'working-tree' for nil to_ref even if from_ref resolves" do
      with_temp_repo do |repo|
        File.write(File.join(repo, "f.rb"), "v1\n")
        git_commit(repo, "init")
        File.write(File.join(repo, "f.rb"), "v2\n")

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: nil, repo_path: repo,
        )

        doc.metadata.ref_from.should match(SHA40_RE)
        doc.metadata.ref_to.should eq("working-tree")
      end
    end

    it "stores 'staged' as-is for the index pseudo-ref (not SHA-shape)" do
      with_temp_repo do |repo|
        File.write(File.join(repo, "f.rb"), "v1\n")
        git_commit(repo, "init")
        File.write(File.join(repo, "f.rb"), "v2\n")
        Process.run("git", ["add", "-A"], chdir: repo)

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: "staged",
          repo_path: repo,
        )

        # "staged" isn't resolvable to a single commit;
        # falls back to the input string. The reader's
        # SHA-shape check will correctly suppress the
        # remote-link affordance for this capture.
        doc.metadata.ref_to.should eq("staged")
      end
    end

    it "falls back to the input string when a ref doesn't resolve" do
      with_temp_repo do |repo|
        File.write(File.join(repo, "f.rb"), "v1\n")
        git_commit(repo, "init")

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "NONEXISTENT_REF",
          to_ref: nil, repo_path: repo,
        )

        doc.metadata.ref_from.should eq("NONEXISTENT_REF")
      end
    end
  end

  describe "repo origin parsing" do
    it "parses an SSH GitHub remote into owner/repo" do
      with_temp_repo do |repo|
        File.write(File.join(repo, "f.rb"), "v1\n")
        git_commit(repo, "init")
        Process.run(
          "git",
          ["remote", "add", "origin",
           "git@github.com:kellyredding/galaxy.git"],
          chdir: repo,
        )

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: nil, repo_path: repo,
        )

        doc.metadata.repo.should eq(
          "kellyredding/galaxy",
        )
      end
    end

    it "parses an HTTPS GitHub remote into owner/repo" do
      with_temp_repo do |repo|
        File.write(File.join(repo, "f.rb"), "v1\n")
        git_commit(repo, "init")
        Process.run(
          "git",
          ["remote", "add", "origin",
           "https://github.com/kellyredding/galaxy.git"],
          chdir: repo,
        )

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: nil, repo_path: repo,
        )

        doc.metadata.repo.should eq(
          "kellyredding/galaxy",
        )
      end
    end

    it "handles HTTPS GitHub remotes without a .git suffix" do
      with_temp_repo do |repo|
        File.write(File.join(repo, "f.rb"), "v1\n")
        git_commit(repo, "init")
        Process.run(
          "git",
          ["remote", "add", "origin",
           "https://github.com/kellyredding/galaxy"],
          chdir: repo,
        )

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: nil, repo_path: repo,
        )

        doc.metadata.repo.should eq(
          "kellyredding/galaxy",
        )
      end
    end

    it "returns '' when origin is a non-GitHub remote" do
      with_temp_repo do |repo|
        File.write(File.join(repo, "f.rb"), "v1\n")
        git_commit(repo, "init")
        Process.run(
          "git",
          ["remote", "add", "origin",
           "git@gitlab.com:kellyredding/galaxy.git"],
          chdir: repo,
        )

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: nil, repo_path: repo,
        )

        doc.metadata.repo.should eq("")
      end
    end

    it "returns '' when no origin remote is configured" do
      with_temp_repo do |repo|
        File.write(File.join(repo, "f.rb"), "v1\n")
        git_commit(repo, "init")

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: nil, repo_path: repo,
        )

        doc.metadata.repo.should eq("")
      end
    end
  end

  # Every other spec in this file asserts through
  # `GdiffDocument.from_json`, which is exactly why this bug
  # survived a green suite: a round-trip cannot see that the
  # serialized form is unreadable. These assert on the emitted
  # bytes.
  describe "binary content" do
    # Guards the fixture, not the code. These specs only
    # exercise the parser's own binary detection while git
    # agrees the file is binary, and git decides that on a
    # NUL in the first 8000 bytes. A fixture that drifted to
    # NUL-free bytes would still pass everything below while
    # silently testing only the encoding guard — which is
    # exactly what happened on the first draft of this file.
    it "uses a fixture git itself calls binary" do
      with_temp_repo do |repo|
        File.write(File.join(repo, "seed.txt"), "x\n")
        git_commit(repo, "base")
        write_binary_fixture(File.join(repo, "img.png"))
        Process.run("git", ["add", "-A"], chdir: repo)

        numstat = IO::Memory.new
        Process.run(
          "git", ["diff", "--cached", "--numstat"],
          chdir: repo, output: numstat,
        )
        row = numstat.to_s.lines
          .find { |l| l.includes?("img.png") }.not_nil!
        row.starts_with?("-\t-\t").should be_true
      end
    end

    # The complement: no NUL, so git reports text and only
    # the encoding guard can catch it.
    it "catches high-byte content git calls text" do
      with_temp_repo do |repo|
        File.write(File.join(repo, "seed.txt"), "x\n")
        git_commit(repo, "base")
        write_invalid_utf8_fixture(File.join(repo, "odd.dat"))

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: nil, repo_path: repo,
        )
        entry = doc.files.find { |f| f.path == "odd.dat" }
          .not_nil!
        entry.binary.should be_true
        entry.after.should be_nil
        doc.to_json.valid_encoding?.should be_true
      end
    end

    it "keeps an added binary's bytes out of the document" do
      with_temp_repo do |repo|
        File.write(File.join(repo, "keep.txt"), "hello\n")
        git_commit(repo, "base")
        write_binary_fixture(File.join(repo, "img.png"))
        Process.run("git", ["add", "-A"], chdir: repo)

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: "staged", repo_path: repo,
        )
        entry = doc.files.find { |f| f.path == "img.png" }
          .not_nil!
        entry.binary.should be_true
        entry.status.should eq("added")
        entry.after.should be_nil
        entry.before.should be_nil
        entry.hunks.should be_empty
        entry.before_bytes.should eq(0)
        entry.after_bytes.should eq(256)
        doc.to_json.valid_encoding?.should be_true
      end
    end

    it "keeps a deleted binary's bytes out of the document" do
      with_temp_repo do |repo|
        write_binary_fixture(File.join(repo, "img.png"))
        File.write(File.join(repo, "keep.txt"), "hello\n")
        git_commit(repo, "base")
        Process.run(
          "git", ["rm", "-q", "img.png"], chdir: repo)

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: "staged", repo_path: repo,
        )
        entry = doc.files.find { |f| f.path == "img.png" }
          .not_nil!
        entry.binary.should be_true
        entry.status.should eq("deleted")
        entry.before.should be_nil
        entry.before_bytes.should eq(256)
        entry.after_bytes.should eq(0)
        doc.to_json.valid_encoding?.should be_true
      end
    end

    it "keeps a modified binary's bytes out of the document" do
      with_temp_repo do |repo|
        write_binary_fixture(File.join(repo, "img.png"), 128)
        git_commit(repo, "base")
        write_binary_fixture(File.join(repo, "img.png"), 256)

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: nil, repo_path: repo,
        )
        entry = doc.files.find { |f| f.path == "img.png" }
          .not_nil!
        entry.binary.should be_true
        entry.status.should eq("modified")
        entry.before_bytes.should eq(128)
        entry.after_bytes.should eq(256)
        doc.to_json.valid_encoding?.should be_true
      end
    end

    # The default invocation's hole. Bytes used to land in
    # `after` AND, split on 0x0A, in every synthesized line.
    it "keeps an untracked binary's bytes out of the document" do
      with_temp_repo do |repo|
        File.write(File.join(repo, "keep.txt"), "hello\n")
        git_commit(repo, "base")
        write_binary_fixture(File.join(repo, "new.png"))

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: nil, repo_path: repo,
        )
        entry = doc.files.find { |f| f.path == "new.png" }
          .not_nil!
        entry.binary.should be_true
        entry.after.should be_nil
        entry.hunks.should be_empty
        entry.after_bytes.should eq(256)
        doc.to_json.valid_encoding?.should be_true
      end
    end

    # Git calls this text. Only the encoding check catches it.
    it "refuses to embed a text file holding invalid UTF-8" do
      with_temp_repo do |repo|
        File.write(File.join(repo, "data.txt"), "clean\n")
        git_commit(repo, "base")
        File.open(File.join(repo, "data.txt"), "wb") do |f|
          f.print("caf")
          f.write_byte(0xE9_u8) # latin-1 é
          f.print("\n")
        end

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: nil, repo_path: repo,
        )
        entry = doc.files.find { |f| f.path == "data.txt" }
          .not_nil!
        entry.binary.should be_true
        entry.after.should be_nil
        entry.hunks.should be_empty
        doc.to_json.valid_encoding?.should be_true
      end
    end

    # `valid_encoding?` accepts NUL — it is a legal codepoint
    # — and git only sniffs the first 8000 bytes, so this is
    # text to git and valid to Crystal.
    it "refuses to embed content holding a NUL byte" do
      with_temp_repo do |repo|
        File.write(File.join(repo, "late.txt"), "clean\n")
        git_commit(repo, "base")
        write_late_nul_fixture(File.join(repo, "late.txt"))

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: nil, repo_path: repo,
        )
        entry = doc.files.find { |f| f.path == "late.txt" }
          .not_nil!
        entry.binary.should be_true
        doc.to_json.includes?("\\u0000").should be_false
      end
    end

    # The reader's nil-nil test cannot tell "" from content.
    # An empty string renders a blank card with no notice.
    it "leaves both sides nil rather than empty" do
      with_temp_repo do |repo|
        File.write(File.join(repo, "seed.txt"), "x\n")
        git_commit(repo, "base")
        write_binary_fixture(File.join(repo, "img.png"))

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: nil, repo_path: repo,
        )
        entry = doc.files.find { |f| f.path == "img.png" }
          .not_nil!
        entry.before.should be_nil
        entry.after.should be_nil
      end
    end

    it "leaves text files unflagged and still embedded" do
      with_temp_repo do |repo|
        File.write(File.join(repo, "f.txt"), "one\n")
        git_commit(repo, "base")
        File.write(File.join(repo, "f.txt"), "two\n")

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: nil, repo_path: repo,
        )
        entry = doc.files.find { |f| f.path == "f.txt" }
          .not_nil!
        entry.binary.should be_false
        entry.after.should eq("two\n")
        entry.before_bytes.should be_nil
        entry.hunks.should_not be_empty
      end
    end
  end

  describe "pathspec filtering" do
    it "captures only files under the given path" do
      with_temp_repo do |repo|
        Dir.mkdir_p(File.join(repo, "keep"))
        Dir.mkdir_p(File.join(repo, "skip"))
        File.write(File.join(repo, "keep/a.txt"), "one\n")
        File.write(File.join(repo, "skip/b.txt"), "two\n")
        git_commit(repo, "base")
        File.write(
          File.join(repo, "keep/a.txt"), "one changed\n",
        )
        File.write(
          File.join(repo, "skip/b.txt"), "two changed\n",
        )

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: nil, repo_path: repo,
          pathspecs: ["keep"],
        )
        doc.files.map(&.path).should eq(["keep/a.txt"])
      end
    end

    it "excludes untracked files outside the pathspec" do
      with_temp_repo do |repo|
        Dir.mkdir_p(File.join(repo, "keep"))
        File.write(File.join(repo, "keep/a.txt"), "one\n")
        git_commit(repo, "base")
        File.write(File.join(repo, "elsewhere.txt"), "new\n")
        File.write(File.join(repo, "keep/new.txt"), "new\n")

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: nil, repo_path: repo,
          pathspecs: ["keep"],
        )
        paths = doc.files.map(&.path)
        paths.should contain("keep/new.txt")
        paths.should_not contain("elsewhere.txt")
      end
    end

    it "captures everything when no pathspec is given" do
      with_temp_repo do |repo|
        Dir.mkdir_p(File.join(repo, "keep"))
        File.write(File.join(repo, "keep/a.txt"), "one\n")
        File.write(File.join(repo, "other.txt"), "two\n")
        git_commit(repo, "base")
        File.write(
          File.join(repo, "keep/a.txt"), "one changed\n",
        )
        File.write(
          File.join(repo, "other.txt"), "two changed\n",
        )

        doc = GalaxyDiff::DiffCapture.capture(
          from_ref: "HEAD", to_ref: nil, repo_path: repo,
        )
        doc.files.map(&.path).sort.should eq(
          ["keep/a.txt", "other.txt"],
        )
      end
    end
  end
end
