require "./spec_helper"

describe GalaxyLedger::ArtifactClassifier do
  describe ".classify" do
    # High confidence — always artifacts
    it "classifies .csv as csv artifact" do
      result = GalaxyLedger::ArtifactClassifier.classify("/tmp/data.csv")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("csv")
      result.not_nil!.mime_type.should eq("text/csv")
    end

    it "classifies .tsv as csv artifact" do
      result = GalaxyLedger::ArtifactClassifier.classify("/tmp/data.tsv")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("csv")
    end

    it "classifies .pdf as pdf artifact" do
      result = GalaxyLedger::ArtifactClassifier.classify("/tmp/report.pdf")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("pdf")
      result.not_nil!.mime_type.should eq("application/pdf")
    end

    it "classifies .mmd as mermaid artifact" do
      result = GalaxyLedger::ArtifactClassifier.classify("/tmp/flow.mmd")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("mermaid")
    end

    it "classifies .mermaid as mermaid artifact" do
      result = GalaxyLedger::ArtifactClassifier.classify("/tmp/flow.mermaid")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("mermaid")
    end

    it "classifies .png as image artifact" do
      result = GalaxyLedger::ArtifactClassifier.classify("/tmp/chart.png")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("image")
      result.not_nil!.mime_type.should eq("image/png")
    end

    it "classifies .jpg as image artifact" do
      result = GalaxyLedger::ArtifactClassifier.classify("/tmp/photo.jpg")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("image")
    end

    it "classifies .svg as image artifact" do
      result = GalaxyLedger::ArtifactClassifier.classify("/tmp/icon.svg")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("image")
      result.not_nil!.mime_type.should eq("image/svg+xml")
    end

    it "classifies .html as html artifact" do
      result = GalaxyLedger::ArtifactClassifier.classify("/tmp/dashboard.html")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("html")
    end

    it "classifies .htm as html artifact" do
      result = GalaxyLedger::ArtifactClassifier.classify("/tmp/legacy.htm")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("html")
      result.not_nil!.mime_type.should eq("text/html")
    end

    it "classifies .htm even in source code paths" do
      result = GalaxyLedger::ArtifactClassifier.classify("/app/views/index.htm")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("html")
    end

    it "classifies .xlsx as spreadsheet artifact" do
      result = GalaxyLedger::ArtifactClassifier.classify("/tmp/data.xlsx")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("spreadsheet")
    end

    # High confidence — location doesn't matter
    it "classifies .csv even in source code paths" do
      result = GalaxyLedger::ArtifactClassifier.classify("/app/src/data.csv")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("csv")
    end

    # Source code — never artifacts
    it "rejects .rb files" do
      GalaxyLedger::ArtifactClassifier.classify("/app/models/user.rb").should be_nil
    end

    it "rejects .py files" do
      GalaxyLedger::ArtifactClassifier.classify("/tmp/script.py").should be_nil
    end

    it "rejects .cr files" do
      GalaxyLedger::ArtifactClassifier.classify("/src/main.cr").should be_nil
    end

    it "rejects .js files" do
      GalaxyLedger::ArtifactClassifier.classify("/app/index.js").should be_nil
    end

    it "rejects .ts files" do
      GalaxyLedger::ArtifactClassifier.classify("/app/main.ts").should be_nil
    end

    it "rejects .swift files" do
      GalaxyLedger::ArtifactClassifier.classify("/src/App.swift").should be_nil
    end

    it "rejects .sh files" do
      GalaxyLedger::ArtifactClassifier.classify("/tmp/deploy.sh").should be_nil
    end

    it "rejects .css files" do
      GalaxyLedger::ArtifactClassifier.classify("/app/styles.css").should be_nil
    end

    # Medium confidence — path heuristics (artifact paths)
    it "classifies .md in /tmp/ as artifact" do
      result = GalaxyLedger::ArtifactClassifier.classify("/tmp/analysis-report.md")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("markdown")
    end

    it "classifies .markdown in /tmp/ as artifact" do
      result = GalaxyLedger::ArtifactClassifier.classify("/tmp/analysis-report.markdown")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("markdown")
      result.not_nil!.mime_type.should eq("text/markdown")
    end

    it "classifies .md in ~/Desktop/ as artifact" do
      result = GalaxyLedger::ArtifactClassifier.classify("/Users/user/Desktop/summary.md")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("markdown")
    end

    it "classifies .json in /output/ as data artifact" do
      result = GalaxyLedger::ArtifactClassifier.classify("/home/user/output/results.json")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("data")
    end

    it "classifies .txt in /reports/ as text artifact" do
      result = GalaxyLedger::ArtifactClassifier.classify("/home/user/reports/log.txt")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("text")
    end

    # Medium confidence — source code path rejection
    it "rejects .md in /app/ (source code path)" do
      GalaxyLedger::ArtifactClassifier.classify("/app/views/readme.md").should be_nil
    end

    it "rejects .md in /src/" do
      GalaxyLedger::ArtifactClassifier.classify("/src/docs/guide.md").should be_nil
    end

    it "rejects .md in /spec/" do
      GalaxyLedger::ArtifactClassifier.classify("/spec/fixtures/sample.md").should be_nil
    end

    it "rejects .json in /config/" do
      GalaxyLedger::ArtifactClassifier.classify("/app/config/settings.json").should be_nil
    end

    it "rejects .md in /agent-guidelines/" do
      GalaxyLedger::ArtifactClassifier.classify("/proj/agent-guidelines/rules.md").should be_nil
    end

    it "rejects .md in /implementation-plans/" do
      GalaxyLedger::ArtifactClassifier.classify("/proj/implementation-plans/plan.md").should be_nil
    end

    it "rejects .markdown in /implementation-plans/" do
      GalaxyLedger::ArtifactClassifier.classify("/proj/implementation-plans/plan.markdown").should be_nil
    end

    it "rejects .markdown in /agent-guidelines/" do
      GalaxyLedger::ArtifactClassifier.classify("/proj/agent-guidelines/rules.markdown").should be_nil
    end

    # Non-artifact filenames — rejected regardless of path
    it "rejects README.md anywhere" do
      GalaxyLedger::ArtifactClassifier.classify("/tmp/README.md").should be_nil
    end

    it "rejects CHANGELOG.md" do
      GalaxyLedger::ArtifactClassifier.classify("/tmp/CHANGELOG.md").should be_nil
    end

    it "rejects package.json regardless of path" do
      GalaxyLedger::ArtifactClassifier.classify("/tmp/package.json").should be_nil
    end

    it "rejects config.json" do
      GalaxyLedger::ArtifactClassifier.classify("/tmp/config.json").should be_nil
    end

    # Filename-based heuristics for medium confidence
    it "classifies report-*.md via filename pattern" do
      result = GalaxyLedger::ArtifactClassifier.classify("/home/user/report-q4.md")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("markdown")
    end

    it "classifies analysis-*.txt via filename pattern" do
      result = GalaxyLedger::ArtifactClassifier.classify("/home/user/analysis-summary.txt")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("text")
    end

    it "classifies export-*.json via filename pattern" do
      result = GalaxyLedger::ArtifactClassifier.classify("/home/user/export-data.json")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("data")
    end

    it "classifies dashboard-*.md via filename pattern" do
      result = GalaxyLedger::ArtifactClassifier.classify("/home/user/dashboard-metrics.md")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("markdown")
    end

    # Unknown extensions — not classified
    it "returns nil for unknown extensions" do
      GalaxyLedger::ArtifactClassifier.classify("/tmp/data.parquet").should be_nil
    end

    it "returns nil for no extension" do
      GalaxyLedger::ArtifactClassifier.classify("/tmp/Makefile").should be_nil
    end

    # Medium confidence — no matching heuristics
    it "rejects .md with no artifact path or filename signals" do
      GalaxyLedger::ArtifactClassifier.classify("/home/user/notes.md").should be_nil
    end

    it "rejects .markdown with no artifact path or filename signals" do
      GalaxyLedger::ArtifactClassifier.classify("/home/user/notes.markdown").should be_nil
    end

    it "rejects .txt with no artifact path or filename signals" do
      GalaxyLedger::ArtifactClassifier.classify("/home/user/scratch.txt").should be_nil
    end

    # Case insensitivity
    it "handles uppercase extensions" do
      result = GalaxyLedger::ArtifactClassifier.classify("/tmp/DATA.CSV")
      result.should_not be_nil
      result.not_nil!.artifact_type.should eq("csv")
    end

    it "handles mixed case filenames for non-artifact detection" do
      GalaxyLedger::ArtifactClassifier.classify("/tmp/README.MD").should be_nil
    end
  end
end
