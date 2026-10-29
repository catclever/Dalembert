require "rspec"
require "dalembert/tools/doc_fetcher"

RSpec.describe Dalembert::Tools::DocFetcher do
  let(:context) { double("Context") }
  let(:tool) { described_class.new(context) }

  describe "#execute" do
    it "requires url" do
      expect(tool.execute({})).to include("Error: Missing URL")
    end

    it "truncates large content" do
      mock_response = double("Net::HTTPSuccess", is_a?: true, code: "200", message: "OK")
      allow(mock_response).to receive(:body).and_return("a" * 6000)
      allow(Net::HTTP).to receive(:start).and_yield(double("HTTP", request: mock_response))

      result = tool.execute({"url" => "http://example.com/doc.md"})
      expect(result.length).to be < 6000
      expect(result).to include("... (truncated for length)")
    end
  end
end
