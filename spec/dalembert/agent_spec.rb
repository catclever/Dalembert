# frozen_string_literal: true

require "rspec"

=begin
================================================================================
Test Suite: Dalembert Agent Specifications
Task ID: multi_provider_model_selection_001

1. Problem / Feature Tested:
   - Validates that Dalembert::Agent accepts the new `model: nil` optional keyword argument.
   - Validates that Dalembert::Agent uses ProfileResolver to resolve composite profile
     identifiers (e.g. "deepseek/deepseek-reasoner") and decouple channel config from model.
   - Validates that explicit model parameter overrides work during Agent initialization.
   - Validates fallback to the default profile and model.
   - Validates that @profile_name, @model, and @resolved_profile are set and accessible.
   - Validates that @llm is properly initialized / overridden with RubyLLM::LLMService
     and that agent.llm.model reflects the decoupled model.

2. Method / Logic Used:
   - Asserts on public accessors agent.profile_name, agent.model, and agent.llm.model.
   - Preserves all original assertions regarding default system prompt and tools.

3. Caveats & Future Development Considerations:
   - Descartes::Agent::Base superclass initialization happens before the Dalembert::Agent
     override; ensure @llm, @profile_name, and @model reflect the resolved options.
================================================================================
=end

# Stub RubyLLM::LLMService before requiring agent if not defined
module RubyLLM
  class LLMService
    attr_reader :model unless method_defined?(:model)

    def initialize(**args)
      @model = args[:model]
    end unless method_defined?(:initialize)
  end
end

require "dalembert/profile_resolver"
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

    it "initializes with default profile and model when none specified" do
      agent = described_class.new
      expect(agent.instance_variable_get(:@profile_name)).to eq("default")
      expect(agent.profile_name).to eq("default")
      expect(agent.model).to eq("deepseek-chat")
      expect(agent.resolved_profile[:profile_name]).to eq("default")
      expect(agent.resolved_profile[:model]).to eq("deepseek-chat")

      expect(agent.llm).to be_a(RubyLLM::LLMService)
      expect(agent.llm.model).to eq("deepseek-chat")
    end

    it "resolves composite profile string like 'deepseek/deepseek-reasoner'" do
      agent = described_class.new(profile_name: "deepseek/deepseek-reasoner")

      expect(agent.instance_variable_get(:@profile_name)).to eq("deepseek")
      expect(agent.profile_name).to eq("deepseek")
      expect(agent.model).to eq("deepseek-reasoner")
      expect(agent.resolved_profile[:profile_name]).to eq("deepseek")
      expect(agent.resolved_profile[:model]).to eq("deepseek-reasoner")

      expect(agent.llm.model).to eq("deepseek-reasoner")
    end

    it "supports explicit model: parameter override" do
      agent = described_class.new(profile_name: "openai", model: "gpt-4o-mini")

      expect(agent.instance_variable_get(:@profile_name)).to eq("openai")
      expect(agent.profile_name).to eq("openai")
      expect(agent.model).to eq("gpt-4o-mini")
      expect(agent.resolved_profile[:profile_name]).to eq("openai")
      expect(agent.resolved_profile[:model]).to eq("gpt-4o-mini")

      expect(agent.llm.model).to eq("gpt-4o-mini")
    end

    it "allows explicit model: to override composite profile model" do
      agent = described_class.new(profile_name: "deepseek/deepseek-chat", model: "deepseek-reasoner")

      expect(agent.profile_name).to eq("deepseek")
      expect(agent.model).to eq("deepseek-reasoner")
      expect(agent.resolved_profile[:model]).to eq("deepseek-reasoner")
      expect(agent.llm.model).to eq("deepseek-reasoner")
    end
  end
end
