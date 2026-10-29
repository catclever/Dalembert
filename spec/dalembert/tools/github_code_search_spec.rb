require "rspec"
require "dalembert/tools/github_code_search"

RSpec.describe Dalembert::Tools::GithubCodeSearch do
  let(:context) { double("Context") }
  let(:tool) { described_class.new(context) }

  describe "#execute" do
    it "requires query" do
      expect(tool.execute({})).to include("Error: Missing query")
    end

    it "handles searching and format response correctly" do
      # Mock the HTTP response
      mock_response = double("Net::HTTPSuccess", is_a?: true, code: "200", message: "OK")
      mock_body = {
        "items" => [
          { "path" => "lib/agent.rb", "repository" => { "full_name" => "test/repo" }, "html_url" => "http://test.url" }
        ]
      }.to_json
      allow(mock_response).to receive(:body).and_return(mock_body)

      allow(Net::HTTP).to receive(:start).and_yield(double("HTTP", request: mock_response))

      result = tool.execute({"query" => "Descartes::Agent"})
      expect(result).to include("Found usage examples:")
      expect(result).to include("File: lib/agent.rb in test/repo")
      expect(result).to include("URL: http://test.url")
    end
  end
end
