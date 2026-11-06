# frozen_string_literal: true

=begin
================================================================================
Feature: Dalembert Module Loading with ProfileResolver
Task ID: multi_provider_model_selection_001

1. Problem / Feature Implemented:
   - Registers Dalembert::ProfileResolver within the top-level module load flow
     so that all components (CLI, Agent, Server, and external gems) can resolve
     LLM provider/model configurations without requiring manual sub-requires.

2. Method / Logic Used:
   - Added `require_relative "dalembert/profile_resolver"` before requiring
     `dalembert/agent` to ensure ProfileResolver is defined prior to Agent initialization.

3. Caveats & Future Development Considerations:
   - ProfileResolver must remain loaded prior to Agent.
================================================================================
=end

require_relative "dalembert/version"
require_relative "dalembert/profile_resolver"
require_relative "dalembert/knowledge_store"
require_relative "dalembert/tools/github_repo_survey"
require_relative "dalembert/tools/github_code_search"
require_relative "dalembert/tools/doc_fetcher"
require_relative "dalembert/tools/spec_inspector"
require_relative "dalembert/agent"

module Dalembert
end
require_relative "dalembert/tools/knowledge_store_tool"
