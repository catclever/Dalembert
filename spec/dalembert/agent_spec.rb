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

=begin
================================================================================
Test Suite: Frontend-Driven Cloud Tool Resolution & Masking Specifications
Task ID: dynamic_tool_masking_and_swe_bench_workflow_003

1. Problem / Feature Tested:
   - Validates `Dalembert::Agent.resolve_cloud_tools` for default mode, explicit
     `cloud_tools` whitelisting (including `[]`), canonical and alias tool name mapping,
     `swe_bench` / `bug_hunter` temporal leakage masking, and `disabled_tools` blacklisting.
   - Validates `Dalembert::Agent#initialize` integration with `tools:`, `cloud_tools:`,
     `disabled_tools:`, `mode:`, and accessors `:mode` and `:enabled_tools`.

2. Method / Logic Used:
   - Exercises all combinations of `cloud_tools`, `disabled_tools`, and `mode`.
   - Stubs external edge tools with `.tool_name` to verify merging and `disabled_tools`
     filtering on both external and cloud tools.

3. Caveats & Future Development Considerations:
   - Ensure both canonical names and aliases (`survey_architecture`, `search_code_examples`,
     `fetch_doc`, `inspect_spec`) are covered in whitelist and blacklist specs.
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

  describe ".resolve_cloud_tools" do
    it "returns all 5 cloud OSINT tools by default when cloud_tools is nil and mode is default" do
      resolved = described_class.resolve_cloud_tools
      expect(resolved).to eq([
        Dalembert::Tools::GithubRepoSurvey,
        Dalembert::Tools::GithubCodeSearch,
        Dalembert::Tools::DocFetcher,
        Dalembert::Tools::SpecInspector,
        Dalembert::Tools::KnowledgeStoreTool
      ])
    end

    it "returns empty array when cloud_tools: [] is explicitly passed" do
      resolved = described_class.resolve_cloud_tools(cloud_tools: [])
      expect(resolved).to eq([])
    end

    it "resolves canonical tool names and aliases when cloud_tools is specified" do
      resolved = described_class.resolve_cloud_tools(
        cloud_tools: %w[survey_architecture search_code_examples fetch_doc inspect_spec knowledge_store]
      )
      expect(resolved).to eq([
        Dalembert::Tools::GithubRepoSurvey,
        Dalembert::Tools::GithubCodeSearch,
        Dalembert::Tools::DocFetcher,
        Dalembert::Tools::SpecInspector,
        Dalembert::Tools::KnowledgeStoreTool
      ])
    end

    it "automatically masks out GithubRepoSurvey and GithubCodeSearch in swe_bench and bug_hunter modes" do
      swe_tools = described_class.resolve_cloud_tools(mode: "swe_bench")
      expect(swe_tools).to eq([
        Dalembert::Tools::DocFetcher,
        Dalembert::Tools::SpecInspector,
        Dalembert::Tools::KnowledgeStoreTool
      ])

      bug_hunter_tools = described_class.resolve_cloud_tools(mode: "BUG_HUNTER")
      expect(bug_hunter_tools).to eq([
        Dalembert::Tools::DocFetcher,
        Dalembert::Tools::SpecInspector,
        Dalembert::Tools::KnowledgeStoreTool
      ])
    end

    it "subtracts disabled_tools by canonical name or alias" do
      resolved = described_class.resolve_cloud_tools(
        disabled_tools: ["search_code_examples", "github_repo_survey", "fetch_doc"]
      )
      expect(resolved).to eq([
        Dalembert::Tools::SpecInspector,
        Dalembert::Tools::KnowledgeStoreTool
      ])
    end
  end

  describe "dynamic tool masking in #initialize" do
    let(:mock_read_tool) do
      Class.new(Descartes::Tool::Base) do
        name "read_file"
        description "Read local file"
      end
    end

    let(:mock_write_tool) do
      Class.new(Descartes::Tool::Base) do
        name "write_file"
        description "Write local file"
      end
    end

    it "masks all cloud tools when cloud_tools: [] is passed while keeping external tools" do
      agent = described_class.new(
        tools: [mock_read_tool],
        cloud_tools: []
      )

      expect(agent.enabled_tools).to eq([mock_read_tool])
      expect(agent.instance_variable_get(:@tools)).to eq([mock_read_tool])
    end

    it "filters out external and cloud tools matching disabled_tools" do
      agent = described_class.new(
        tools: [mock_read_tool, mock_write_tool],
        disabled_tools: ["write_file", "search_code_examples", "survey_architecture"]
      )

      expect(agent.enabled_tools).to include(mock_read_tool)
      expect(agent.enabled_tools).not_to include(mock_write_tool)
      expect(agent.enabled_tools).not_to include(Dalembert::Tools::GithubCodeSearch)
      expect(agent.enabled_tools).not_to include(Dalembert::Tools::GithubRepoSurvey)
      expect(agent.enabled_tools).to include(Dalembert::Tools::DocFetcher)
    end

    it "sets mode and excludes GitHub tools automatically when mode: 'swe_bench'" do
      agent = described_class.new(mode: "swe_bench", tools: [mock_read_tool])

      expect(agent.mode).to eq("swe_bench")
      expect(agent.enabled_tools).to include(mock_read_tool, Dalembert::Tools::DocFetcher)
      expect(agent.enabled_tools).not_to include(
        Dalembert::Tools::GithubRepoSurvey,
        Dalembert::Tools::GithubCodeSearch
      )
    end
  end
end
