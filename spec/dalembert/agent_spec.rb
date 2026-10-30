require "rspec"

# Stub RubyLLM::LLMService before requiring agent since Descartes uses it.
module RubyLLM
  class LLMService
    def initialize(**args); end
  end
end

require "dalembert/agent"

RSpec.describe Dalembert::Agent do
  describe "#initialize" do
    it "initializes with tools and custom prompt" do
      agent = described_class.new(name: :test_agent)
      expect(agent.instance_variable_get(:@name)).to eq(:test_agent)

      system_prompt = agent.instance_variable_get(:@system_prompt)
      expect(system_prompt).to include("Dalembert")
      expect(system_prompt).to include("Consult docs and compare real-world implementations first")

      tools = agent.instance_variable_get(:@tools)
      expect(tools.any? { |t| t.tool_name == "github_repo_survey" }).to be true
      expect(tools.any? { |t| t.tool_name == "doc_fetcher" }).to be true
    end
  end
end
