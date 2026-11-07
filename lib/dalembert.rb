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

=begin
================================================================================
Feature: Frontend-Driven Cloud Tool Masking & 3-Stage SWE-bench Workflow Loading
Task ID: dynamic_tool_masking_and_swe_bench_workflow_003

1. Problem / Feature Implemented:
   - Registers `Dalembert::Workflows::SweBenchWorkflow` in the top-level module
     load flow so callers can instantiate the 3-stage SWE-bench state machine
     (`:locate` -> `:reproduce` -> `:patch_and_verify`) directly after requiring `dalembert`.

2. Method / Logic Used:
   - Ensures all cloud tool classes and `Dalembert::Agent` are required before
     requiring `dalembert/workflows/swe_bench_workflow`.

3. Caveats & Future Development Considerations:
   - `dalembert/agent` must be loaded before `dalembert/workflows/swe_bench_workflow`
     because the workflow delegates cloud tool resolution and stage execution to `Dalembert::Agent`.
================================================================================
=end

require_relative "dalembert/version"
require_relative "dalembert/profile_resolver"
require_relative "dalembert/knowledge_store"
require_relative "dalembert/tools/github_repo_survey"
require_relative "dalembert/tools/github_code_search"
require_relative "dalembert/tools/doc_fetcher"
require_relative "dalembert/tools/spec_inspector"
require_relative "dalembert/tools/knowledge_store_tool"
require_relative "dalembert/agent"
require_relative "dalembert/workflows/swe_bench_workflow"

module Dalembert
end
