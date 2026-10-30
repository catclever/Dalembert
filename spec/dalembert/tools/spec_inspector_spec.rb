require "rspec"
require "dalembert/tools/spec_inspector"

RSpec.describe Dalembert::Tools::SpecInspector do
  let(:context) { double("Context") }
  let(:tool) { described_class.new(context) }

  describe "#execute" do
    it "requires spec_url" do
      expect(tool.execute({})).to include("Error: Missing spec_url")
    end

    it "extracts assertions correctly" do
      code = <<~RUBY
        it "does something" do
          expect(1).to eq(1)
        end
      RUBY
      mock_response = double("Net::HTTPSuccess", is_a?: true, code: "200", message: "OK")
      allow(mock_response).to receive(:body).and_return(code)
      allow(Net::HTTP).to receive(:start).and_yield(double("HTTP", request: mock_response))

      result = tool.execute({"spec_url" => "http://example.com/spec.rb"})
      expect(result).to include("Test Block: it \"does something\" do")
      expect(result).to include("Assertion: expect(1).to eq(1)")
    end
  end
end
