require "./spec_helper"

describe GalaxyDiff::DiffParser do
  it "returns empty array for empty input" do
    GalaxyDiff::DiffParser.parse("").should be_empty
  end

  it "parses a single-file modification with one hunk" do
    raw = <<-DIFF
    diff --git a/src/foo.cr b/src/foo.cr
    index abc..def 100644
    --- a/src/foo.cr
    +++ b/src/foo.cr
    @@ -1,3 +1,4 @@
     first
    -second
    +SECOND
    +third
     last
    DIFF

    files = GalaxyDiff::DiffParser.parse(raw)
    files.size.should eq(1)

    f = files[0]
    f.path.should eq("src/foo.cr")
    f.status.should eq("modified")
    f.hunks.size.should eq(1)

    h = f.hunks[0]
    h.old_start.should eq(1)
    h.old_count.should eq(3)
    h.new_start.should eq(1)
    h.new_count.should eq(4)
    h.lines.size.should eq(5)
    h.lines[0].type
      .should eq(GalaxyDiff::GdiffLineType::Context)
    h.lines[0].content.should eq("first")
    h.lines[1].type
      .should eq(GalaxyDiff::GdiffLineType::Delete)
    h.lines[1].content.should eq("second")
    h.lines[2].type
      .should eq(GalaxyDiff::GdiffLineType::Add)
    h.lines[2].content.should eq("SECOND")
  end

  it "tracks line numbers across add/delete/context" do
    raw = <<-DIFF
    diff --git a/f b/f
    --- a/f
    +++ b/f
    @@ -1,3 +1,4 @@
     a
    -b
    +B
    +c
     d
    DIFF

    f = GalaxyDiff::DiffParser.parse(raw)[0]
    lines = f.hunks[0].lines

    # Context line 1 at old=1, new=1
    lines[0].old_no.should eq(1)
    lines[0].new_no.should eq(1)

    # Delete "b" at old=2, no new.
    lines[1].old_no.should eq(2)
    lines[1].new_no.should be_nil

    # Add "B" at new=2, no old.
    lines[2].old_no.should be_nil
    lines[2].new_no.should eq(2)

    # Add "c" at new=3, no old.
    lines[3].old_no.should be_nil
    lines[3].new_no.should eq(3)

    # Context "d" at old=3, new=4 — old_line advances
    # through deletes (not adds), new_line advances
    # through adds (not deletes).
    lines[4].old_no.should eq(3)
    lines[4].new_no.should eq(4)
  end

  it "parses multiple hunks within one file" do
    raw = <<-DIFF
    diff --git a/f b/f
    --- a/f
    +++ b/f
    @@ -1,2 +1,3 @@
     a
    +b
     c
    @@ -10,2 +11,3 @@
     x
    +y
     z
    DIFF

    f = GalaxyDiff::DiffParser.parse(raw)[0]
    f.hunks.size.should eq(2)
    f.hunks[0].new_start.should eq(1)
    f.hunks[1].new_start.should eq(11)
  end

  it "parses multiple files in one diff" do
    raw = <<-DIFF
    diff --git a/one b/one
    --- a/one
    +++ b/one
    @@ -1 +1 @@
    -old
    +new
    diff --git a/two b/two
    --- a/two
    +++ b/two
    @@ -1 +1 @@
    -A
    +B
    DIFF

    files = GalaxyDiff::DiffParser.parse(raw)
    files.size.should eq(2)
    files[0].path.should eq("one")
    files[1].path.should eq("two")
  end

  it "handles single-line hunk headers (no count)" do
    raw = <<-DIFF
    diff --git a/f b/f
    --- a/f
    +++ b/f
    @@ -1 +1 @@
    -old
    +new
    DIFF

    f = GalaxyDiff::DiffParser.parse(raw)[0]
    f.hunks[0].old_count.should eq(1)
    f.hunks[0].new_count.should eq(1)
  end

  it "marks added files with status 'added'" do
    raw = <<-DIFF
    diff --git a/new.txt b/new.txt
    new file mode 100644
    index 0000000..abc
    --- /dev/null
    +++ b/new.txt
    @@ -0,0 +1,2 @@
    +hello
    +world
    DIFF

    f = GalaxyDiff::DiffParser.parse(raw)[0]
    f.path.should eq("new.txt")
    f.status.should eq("added")
    f.hunks[0].lines.size.should eq(2)
    f.hunks[0].lines.all?(&.type.add?).should be_true
  end

  it "marks deleted files with status 'deleted'" do
    raw = <<-DIFF
    diff --git a/gone.txt b/gone.txt
    deleted file mode 100644
    --- a/gone.txt
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -hello
    -world
    DIFF

    f = GalaxyDiff::DiffParser.parse(raw)[0]
    # `path` is seeded from the `diff --git` header so
    # deleted files still carry their original path even
    # though the +++ line points at /dev/null.
    f.path.should eq("gone.txt")
    f.old_path_raw.should eq("gone.txt")
    f.status.should eq("deleted")
    f.hunks[0].lines.size.should eq(2)
    f.hunks[0].lines.all?(&.type.delete?).should be_true
  end

  it "captures renamed files with old_path" do
    raw = <<-DIFF
    diff --git a/old.txt b/new.txt
    similarity index 90%
    rename from old.txt
    rename to new.txt
    --- a/old.txt
    +++ b/new.txt
    @@ -1 +1 @@
    -hello
    +HELLO
    DIFF

    f = GalaxyDiff::DiffParser.parse(raw)[0]
    f.path.should eq("new.txt")
    f.old_path.should eq("old.txt")
    f.status.should eq("renamed")
  end

  it "marks binary files with status 'binary'" do
    raw = <<-DIFF
    diff --git a/img.png b/img.png
    index abc..def 100644
    Binary files a/img.png and b/img.png differ
    DIFF

    f = GalaxyDiff::DiffParser.parse(raw)[0]
    f.path.should eq("img.png")
    f.status.should eq("binary")
    f.hunks.should be_empty
  end

  it "skips the 'No newline at end of file' marker" do
    raw = <<-DIFF
    diff --git a/f b/f
    --- a/f
    +++ b/f
    @@ -1 +1 @@
    -old
    \\ No newline at end of file
    +new
    \\ No newline at end of file
    DIFF

    f = GalaxyDiff::DiffParser.parse(raw)[0]
    # Should only have the delete and add lines, not the
    # backslash markers.
    f.hunks[0].lines.size.should eq(2)
    f.hunks[0].lines[0].type.delete?.should be_true
    f.hunks[0].lines[1].type.add?.should be_true
  end
end
