# frozen_string_literal: true

require "descartes"
require_relative "tools/github_repo_survey"
require_relative "tools/github_code_search"
require_relative "tools/doc_fetcher"
require_relative "tools/spec_inspector"
require_relative "tools/knowledge_store_tool"

module Dalembert
  class Agent < Descartes::Agent::Base
    def initialize(name: :dalembert_agent, profile_name: "default", **kwargs)
      tools = [
        Dalembert::Tools::GithubRepoSurvey,
        Dalembert::Tools::GithubCodeSearch,
        Dalembert::Tools::DocFetcher,
        Dalembert::Tools::SpecInspector,
        Dalembert::Tools::KnowledgeStoreTool
      ]

      super(
        name: name,
        profile_name: profile_name,
        system_prompt: default_system_prompt,
        tools: tools,
        **kwargs
      )
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
