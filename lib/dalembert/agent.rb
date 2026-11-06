# frozen_string_literal: true

require "descartes"
require_relative "profile_resolver"
require_relative "tools/github_repo_survey"
require_relative "tools/github_code_search"
require_relative "tools/doc_fetcher"
require_relative "tools/spec_inspector"
require_relative "tools/knowledge_store_tool"

=begin
================================================================================
Feature: Orthogonal Model Selection in Agent
Task ID: multi_provider_model_selection_001

1. Problem / Feature Implemented:
   - Previously, Dalembert::Agent only accepted `profile_name: "default"`, tying the
     model selection directly to whatever was statically defined under that profile
     in `llm.yml`.
   - In Descartes::Agent::Base, `profile_name` is only used locally to initialize the
     service and is never stored in `@profile_name`.
   - Users and runtime callers (CLI, WebSocket, Server) could not choose different
     models (e.g. deepseek-reasoner vs deepseek-chat) without manually defining new
     profiles in YAML.
   - This update allows `model: nil` as an optional keyword argument in Agent#initialize,
     delegates decoupling and 12-factor fallback to ProfileResolver, sets `@profile_name`
     and `@model` directly, and overrides `@llm` with a freshly initialized
     `RubyLLM::LLMService` configured with the exact resolved parameters.

2. Method / Logic Used:
   - ProfileResolver.resolve is invoked with `profile_name: profile_name, model: model`.
   - `super` (Descartes::Agent::Base) is called with the resolved provider channel name
     (`resolved_config[:profile_name] || profile_name`), tools, and prompt.
   - Explicitly assigns `@profile_name = (resolved_config[:profile_name] || profile_name).to_s`.
   - Explicitly assigns `@model = resolved_config[:model]`.
   - Explicitly assigns `@resolved_profile = resolved_config`.
   - `@llm` is explicitly initialized / overridden with `RubyLLM::LLMService.new(**resolved_config)`.
   - Exposed `attr_reader :profile_name, :model, :resolved_profile, :llm` for inspection.

3. Caveats & Future Development Considerations:
   - Descartes::Agent::Base does not set @profile_name; Dalembert::Agent manages
     both @profile_name and @model explicitly.
   - If mock or stubbing `RubyLLM::LLMService` in tests, ensure `LLMService.new` accepts
     `**args` keyword arguments and exposes `attr_reader :model`.
================================================================================
=end

module Dalembert
  class Agent < Descartes::Agent::Base
    attr_reader :profile_name, :model, :resolved_profile, :llm

    def initialize(name: :dalembert_agent, profile_name: "default", model: nil, **kwargs)
      tools = [
        Dalembert::Tools::GithubRepoSurvey,
        Dalembert::Tools::GithubCodeSearch,
        Dalembert::Tools::DocFetcher,
        Dalembert::Tools::SpecInspector,
        Dalembert::Tools::KnowledgeStoreTool
      ]

      # Resolve decoupled provider and model settings
      resolved_config = ProfileResolver.resolve(
        profile_name: profile_name,
        model: model
      )

      # Pass the resolved provider channel name to Descartes base
      super(
        name: name,
        profile_name: resolved_config[:profile_name] || profile_name,
        system_prompt: default_system_prompt,
        tools: tools,
        **kwargs
      )

      @profile_name = (resolved_config[:profile_name] || profile_name).to_s
      @resolved_profile = resolved_config
      @model = resolved_config[:model]

      # Explicitly initialize or override @llm with resolved decoupled configuration
      @llm = RubyLLM::LLMService.new(**resolved_config)
    end

    private

    def default_system_prompt
      <<~PROMPT
        You are Dalembert, the cloud knowledge, doc-reading, and open-source intelligence brain for the Descartes ecosystem.

        Consult docs and compare real-world implementations first; never guess unknown APIs.

        Use your tools to investigate GitHub repositories, search code, fetch documentation, and extract tests to build ground truth.
        Use knowledge_store tool to persist notes.
      PROMPT
    end
  end
end
