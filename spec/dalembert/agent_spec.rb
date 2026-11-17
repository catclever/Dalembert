# frozen_string_literal: true

require "rspec"
require "net/http"

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

=begin
================================================================================
Test Suite: Transient LLM Error Exponential Backoff Retry Specifications
Task ID: harden_swe_bench_retry_prompts_and_sandbox_isolation_011

1. Problem / Feature Tested:
   - Validates transient HTTP `429`, `503`, and `Net::ReadTimeout` retries succeeding
     after transient failures with deterministic injectable `llm_sleep_fn` (0s sleep).
   - Validates exhaustion after `llm_max_retries` re-raises the original error.
   - Validates non-transient errors (`401 Unauthorized`, `400`, `ArgumentError`)
     re-raise immediately on attempt 1 with zero retries.
   - Validates the `@_dalembert_in_retry_loop` re-entrancy guard when
     `call_with_system` delegates internally to `call_with_messages`.
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

    it "masks all cloud tools when cloud_tools: [] is passed while keeping external and survival tools" do
      agent = described_class.new(
        tools: [mock_read_tool],
        cloud_tools: []
      )

      expect(agent.enabled_tools).to eq([mock_read_tool])
      runtime_tools = agent.instance_variable_get(:@tools)
      expect(runtime_tools).to include(mock_read_tool)
      expect(runtime_tools.map(&:tool_name)).to include("send_message")
      expect(runtime_tools).not_to include(*Dalembert::Agent::ALL_CLOUD_TOOLS)
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

  describe "transient LLM error exponential backoff retry" do
    let(:mock_llm_subclass) do
      Class.new(RubyLLM::LLMService) do
        attr_reader :model
        attr_accessor :system_handler, :messages_handler

        def initialize(**args)
          @model = args[:model]
        end

        def call_with_system(system_prompt, messages, **opts, &block)
          if @system_handler
            @system_handler.call(system_prompt, messages, **opts, &block)
          else
            call_with_messages([{ role: "system", content: system_prompt }] + Array(messages), **opts, &block)
          end
        end

        def call_with_messages(messages, **opts, &block)
          raise "No messages_handler configured" unless @messages_handler

          @messages_handler.call(messages, **opts, &block)
        end
      end
    end

    it "retries transient HTTP 429, 503, and Net::ReadTimeout errors with exponential backoff and succeeds" do
      sleeps = []
      warnings = []
      fake_logger = double("Logger")
      allow(fake_logger).to receive(:warn) { |msg| warnings << msg }

      fake_llm = mock_llm_subclass.new(model: "hy4")
      attempts = 0
      fake_llm.system_handler = lambda do |_sys, _msgs, **_opts|
        attempts += 1
        case attempts
        when 1
          raise RuntimeError, "HTTP 429 Too Many Requests: rate_limit_exceeded"
        when 2
          raise RuntimeError, "503 Service Unavailable"
        else
          "recovered_from_429_and_503"
        end
      end
      allow(RubyLLM::LLMService).to receive(:new).and_return(fake_llm)

      agent = described_class.new(
        cloud_tools: [],
        logger: fake_logger,
        llm_max_retries: 4,
        llm_retry_delays: [2.0, 5.0, 12.0, 25.0],
        llm_sleep_fn: ->(d) { sleeps << d }
      )

      expect(agent.llm).to be_a(RubyLLM::LLMService)
      expect(agent.llm.call_with_system("sys", ["hello"], tools: [])).to eq("recovered_from_429_and_503")
      expect(attempts).to eq(3)
      expect(sleeps).to eq([2.0, 5.0])
      expect(warnings.size).to eq(2)
      expect(warnings.first).to include("429")

      # Verify Net::ReadTimeout (Timeout::Error subclass) also retries cleanly
      timeout_sleeps = []
      timeout_llm = mock_llm_subclass.allocate.tap { |o| o.send(:initialize, model: "hy4") }
      timeout_attempts = 0
      timeout_llm.system_handler = lambda do |_sys, _msgs, **_opts|
        timeout_attempts += 1
        raise Net::ReadTimeout if timeout_attempts <= 2

        "recovered_from_read_timeout"
      end
      allow(RubyLLM::LLMService).to receive(:new).and_return(timeout_llm)

      timeout_agent = described_class.new(
        cloud_tools: [],
        llm_max_retries: 3,
        llm_retry_delays: [2.0, 5.0, 12.0],
        llm_sleep_fn: ->(d) { timeout_sleeps << d }
      )

      expect(timeout_agent.llm.call_with_system("sys", ["ping"])).to eq("recovered_from_read_timeout")
      expect(timeout_attempts).to eq(3)
      expect(timeout_sleeps).to eq([2.0, 5.0])
    end

    it "re-raises the original transient error once llm_max_retries is exhausted" do
      sleeps = []
      fake_llm = mock_llm_subclass.new(model: "hy4")
      attempts = 0
      fake_llm.system_handler = lambda do |_sys, _msgs, **_opts|
        attempts += 1
        raise RuntimeError, "502 Bad Gateway (upstream overloaded)"
      end
      allow(RubyLLM::LLMService).to receive(:new).and_return(fake_llm)

      agent = described_class.new(
        cloud_tools: [],
        llm_max_retries: 2,
        llm_retry_delays: [2.0, 5.0],
        llm_sleep_fn: ->(d) { sleeps << d }
      )

      expect do
        agent.llm.call_with_system("sys", ["msg"])
      end.to raise_error(RuntimeError, /502 Bad Gateway/)

      expect(attempts).to eq(3)
      expect(sleeps).to eq([2.0, 5.0])
    end

    it "re-raises non-transient errors (401 Unauthorized, ArgumentError) immediately with 0 retries" do
      [
        [RuntimeError.new("HTTP 401 Unauthorized: invalid API key"), RuntimeError, /401 Unauthorized/],
        [RuntimeError.new("HTTP 400 Invalid Parameter: max_tokens"), RuntimeError, /400 Invalid Parameter/],
        [ArgumentError.new("missing keyword: :messages"), ArgumentError, /missing keyword/]
      ].each do |err_instance, expected_cls, expected_msg|
        sleeps = []
        fake_llm = mock_llm_subclass.new(model: "hy4")
        attempts = 0
        fake_llm.system_handler = lambda do |_sys, _msgs, **_opts|
          attempts += 1
          raise err_instance
        end
        allow(RubyLLM::LLMService).to receive(:new).and_return(fake_llm)

        agent = described_class.new(
          cloud_tools: [],
          llm_max_retries: 5,
          llm_sleep_fn: ->(d) { sleeps << d }
        )

        expect do
          agent.llm.call_with_system("sys", ["msg"])
        end.to raise_error(expected_cls, expected_msg)

        expect(attempts).to eq(1)
        expect(sleeps).to be_empty
      end
    end

    it "prevents nested retry multiplication when call_with_system delegates internally to call_with_messages" do
      sleeps = []
      fake_llm = mock_llm_subclass.new(model: "hy4")
      underlying_calls = 0
      # Leave system_handler nil so call_with_system delegates to wrapped call_with_messages!
      fake_llm.messages_handler = lambda do |_msgs, **_opts|
        underlying_calls += 1
        raise RuntimeError, "429 Too Many Requests"
      end
      allow(RubyLLM::LLMService).to receive(:new).and_return(fake_llm)

      agent = described_class.new(
        cloud_tools: [],
        llm_max_retries: 3,
        llm_retry_delays: [2.0, 5.0, 12.0],
        llm_sleep_fn: ->(d) { sleeps << d }
      )

      expect do
        agent.llm.call_with_system("sys", [{ role: "user", content: "hi" }])
      end.to raise_error(RuntimeError, /429 Too Many Requests/)

      # Strictly 1 initial + 3 retries = 4 total calls (NOT 4 * 4 = 16!)
      expect(underlying_calls).to eq(4)
      expect(sleeps).to eq([2.0, 5.0, 12.0])
    end
  end
end
