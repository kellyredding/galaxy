require "../spec_helper"

# Every path through the envelope parser that yields a nil result. A caller
# turns nil into zero extractions, which is indistinguishable from the model
# legitimately finding nothing — so these paths are the ones worth pinning.
describe GalaxyLedger::Extraction::ClaudeCLI do
  describe ".extract_run_result_from_cli_output" do
    describe "a successful call" do
      it "returns the result text" do
        output = {
          "result"         => %({"extractions":[]}),
          "total_cost_usd" => 0.25,
        }.to_json

        result = GalaxyLedger::Extraction::ClaudeCLI
          .extract_run_result_from_cli_output(output)

        result[:result].should eq(%({"extractions":[]}))
      end

      it "carries the usage figures out of the envelope" do
        output = {
          "result"         => "{}",
          "total_cost_usd" => 0.25,
          "usage"          => {
            "input_tokens"                => 10,
            "output_tokens"               => 20,
            "cache_creation_input_tokens" => 30,
            "cache_read_input_tokens"     => 40,
          },
        }.to_json

        result = GalaxyLedger::Extraction::ClaudeCLI
          .extract_run_result_from_cli_output(output)

        result[:cost_usd].should eq(0.25)
        result[:input_tokens].should eq(10)
        result[:output_tokens].should eq(20)
        result[:cache_creation_tokens].should eq(30)
        result[:cache_read_tokens].should eq(40)
      end

      it "unwraps a fenced code block" do
        output = {
          "result" => "```json\n{\"extractions\":[]}\n```",
        }.to_json

        result = GalaxyLedger::Extraction::ClaudeCLI
          .extract_run_result_from_cli_output(output)

        result[:result].should eq(%({"extractions":[]}))
      end
    end

    # A failed call exits zero and fills the result field with the error
    # text. Passed through, that reaches a JSON parser as content.
    describe "a call the CLI reports as failed" do
      it "refuses the error text as a result" do
        output = {
          "is_error" => true,
          "result"   => "API Error: 400 input_schema does not support oneOf",
        }.to_json

        result = GalaxyLedger::Extraction::ClaudeCLI
          .extract_run_result_from_cli_output(output)

        result[:result].should be_nil
      end

      it "still reports the usage the failed call consumed" do
        output = {
          "is_error"       => true,
          "result"         => "API Error: 400",
          "total_cost_usd" => 0.02,
        }.to_json

        result = GalaxyLedger::Extraction::ClaudeCLI
          .extract_run_result_from_cli_output(output)

        result[:cost_usd].should eq(0.02)
      end

      it "passes a result through when is_error is false" do
        output = {"is_error" => false, "result" => "{}"}.to_json

        result = GalaxyLedger::Extraction::ClaudeCLI
          .extract_run_result_from_cli_output(output)

        result[:result].should eq("{}")
      end
    end

    describe "an empty result" do
      it "returns nil when the result field is absent" do
        output = {"total_cost_usd" => 0.1}.to_json

        result = GalaxyLedger::Extraction::ClaudeCLI
          .extract_run_result_from_cli_output(output)

        result[:result].should be_nil
      end

      it "returns nil when the result field is an empty string" do
        output = {"result" => ""}.to_json

        result = GalaxyLedger::Extraction::ClaudeCLI
          .extract_run_result_from_cli_output(output)

        result[:result].should be_nil
      end

      it "returns nil when nothing came back at all" do
        result = GalaxyLedger::Extraction::ClaudeCLI
          .extract_run_result_from_cli_output("")

        result[:result].should be_nil
        result[:cost_usd].should eq(0.0)
      end
    end

    describe "an unparseable envelope" do
      it "falls back to treating the raw output as content" do
        result = GalaxyLedger::Extraction::ClaudeCLI
          .extract_run_result_from_cli_output("plain text, no envelope")

        result[:result].should eq("plain text, no envelope")
      end

      it "loses the usage figures on that path" do
        result = GalaxyLedger::Extraction::ClaudeCLI
          .extract_run_result_from_cli_output("not an envelope")

        result[:cost_usd].should eq(0.0)
        result[:input_tokens].should eq(0)
      end

      # The fallback exists for output that is not an envelope at all. Bare
      # extraction JSON does not reach it: being valid JSON, it parses as an
      # envelope, and an envelope without a result field yields nil. So the
      # fallback only ever rescues content that is not JSON — which is
      # content no downstream parser can use either.
      it "does not rescue bare JSON that lacks a result field" do
        result = GalaxyLedger::Extraction::ClaudeCLI
          .extract_run_result_from_cli_output(%({"extractions":[]}))

        result[:result].should be_nil
      end
    end
  end
end
