require "../spec_helper"

describe GalaxyLedger::Extraction::ClaudeCLI do
  describe ".build_args" do
    describe "base invocation" do
      it "runs in print mode with JSON output" do
        args = GalaxyLedger::Extraction::ClaudeCLI.build_args(
          content: "some content",
          prompt: "some prompt",
        )

        args[0].should eq("-p")
        args[1].should eq("--output-format")
        args[2].should eq("json")
      end

      it "passes the prompt and content as the final argument" do
        args = GalaxyLedger::Extraction::ClaudeCLI.build_args(
          content: "some content",
          prompt: "some prompt",
        )

        args.last.should eq("some prompt\n\nContent to analyze:\nsome content")
      end

      it "omits the model flag when no model is given" do
        args = GalaxyLedger::Extraction::ClaudeCLI.build_args(
          content: "some content",
          prompt: "some prompt",
        )

        args.should_not contain("--model")
      end
    end

    describe "model override" do
      it "passes the model as a flag and value pair" do
        args = GalaxyLedger::Extraction::ClaudeCLI.build_args(
          content: "some content",
          prompt: "some prompt",
          model: "sonnet",
        )

        idx = args.index("--model").not_nil!
        args[idx + 1].should eq("sonnet")
      end

      it "keeps the prompt last so the model flag cannot consume it" do
        args = GalaxyLedger::Extraction::ClaudeCLI.build_args(
          content: "some content",
          prompt: "some prompt",
          model: "sonnet",
        )

        args.last.should contain("some prompt")
      end
    end

    describe "flags the CLI is not given" do
      # A flag the CLI accepts and silently ignores looks exactly like one
      # that works. --prefill was passed for months, did nothing, and the
      # malformed responses it was meant to prevent kept happening.
      it "does not pass a prefill flag" do
        args = GalaxyLedger::Extraction::ClaudeCLI.build_args(
          content: "some content",
          prompt: "some prompt",
          model: "sonnet",
        )

        args.should_not contain("--prefill")
      end
    end
  end
end
