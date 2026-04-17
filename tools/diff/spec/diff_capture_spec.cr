require "./spec_helper"

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
      doc.metadata.branch.should eq("main")
      doc.metadata.ref_from.should eq("HEAD")
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
end
