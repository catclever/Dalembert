# frozen_string_literal: true

require "timeout"
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

=begin
================================================================================
Feature: Frontend-Driven Cloud Tool Resolution & Temporal Leakage Masking
Task ID: dynamic_tool_masking_and_swe_bench_workflow_003

1. Problem / Feature Implemented:
   - Previously, `Dalembert::Agent` unconditionally mounted all 5 cloud OSINT tools
     (`GithubRepoSurvey`, `GithubCodeSearch`, `DocFetcher`, `SpecInspector`,
     `KnowledgeStoreTool`) into every session.
   - In SWE-bench or bug-hunting benchmarks, mounting `GithubRepoSurvey` and
     `GithubCodeSearch` risks temporal leakage (searching upstream GitHub commits/PRs
     for the exact fix), and edge clients (`EnginEdge`) could not whitelist or
     blacklist specific cloud tools via the `init` payload.

2. Method / Logic Used:
   - Added `CLOUD_TOOL_MAP` mapping canonical tool names and aliases (`survey_architecture`,
     `search_code_examples`, `fetch_doc`, `inspect_spec`, etc.) to their tool classes.
   - Implemented `Dalembert::Agent.resolve_cloud_tools(cloud_tools: nil, disabled_tools: nil, mode: nil)`:
     - When `cloud_tools` is explicitly provided (not `nil`), resolves only the
       specified tool classes (passing `[]` disables all cloud tools).
     - When `cloud_tools` is `nil` and `mode` is `"swe_bench"` or `"bug_hunter"`,
       defaults to `[DocFetcher, SpecInspector, KnowledgeStoreTool]`, masking out
       GitHub search tools.
     - Otherwise defaults to all 5 cloud tools.
     - Subtracts any tool matching `disabled_tools` (by canonical name, alias, or class).
   - Updated `Dalembert::Agent#initialize` to accept `tools:`, `cloud_tools:`,
     `disabled_tools:`, and `mode:`, filtering external `tools` against `disabled_tools`
     and merging with `resolved_cloud_tools`.

3. Caveats & Future Development Considerations:
   - Passing `cloud_tools: []` explicitly disables all cloud OSINT tools, whereas
     passing `cloud_tools: nil` uses the mode-dependent default whitelist.
================================================================================
=end

=begin
================================================================================
Feature: Transient LLM Error Exponential Backoff Retry Wrapper
Task ID: harden_swe_bench_retry_prompts_and_sandbox_isolation_011

1. Problem / Feature Implemented:
   - Upstream LLM endpoints (e.g. Hy4 / DeepSeek / OpenAI-compatible gateways)
     periodically emit transient HTTP `429` rate-limit errors, `5xx` gateway errors,
     or network read timeouts during multi-turn SWE-bench runs, previously causing
     immediate stage failure on the first transient blip.

2. Method / Logic Used:
   - Keeps `@llm = RubyLLM::LLMService.new(**llm_init_opts)` so `agent.llm` remains
     a true `RubyLLM::LLMService` instance.
   - Installs `install_llm_retry_wrapper!(@llm)` on whichever invocation methods
     (`call_with_system`, `call_with_messages`, `call`, `chat`) exist on `@llm`,
     protected by a re-entrancy guard (`@_dalembert_in_retry_loop`) so internal
     method delegation never multiplies retries.
   - Retries transient errors matching `transient_llm_error?` up to `llm_max_retries`
     with exponential backoff + jitter (or deterministic `llm_sleep_fn` in specs),
     while re-raising non-transient errors (`401`, `400`, `ArgumentError`, etc.)
     immediately on the first failure.
================================================================================
=end

module Dalembert
  class Agent < Descartes::Agent::Base
    ALL_CLOUD_TOOLS = [
      Dalembert::Tools::GithubRepoSurvey,
      Dalembert::Tools::GithubCodeSearch,
      Dalembert::Tools::DocFetcher,
      Dalembert::Tools::SpecInspector,
      Dalembert::Tools::KnowledgeStoreTool
    ].freeze

    SWE_BENCH_DEFAULT_CLOUD_TOOLS = [
      Dalembert::Tools::DocFetcher,
      Dalembert::Tools::SpecInspector,
      Dalembert::Tools::KnowledgeStoreTool
    ].freeze

    CLOUD_TOOL_MAP = {
      "github_repo_survey"   => Dalembert::Tools::GithubRepoSurvey,
      "survey_architecture"  => Dalembert::Tools::GithubRepoSurvey,
      "github_code_search"   => Dalembert::Tools::GithubCodeSearch,
      "search_code_examples" => Dalembert::Tools::GithubCodeSearch,
      "doc_fetcher"          => Dalembert::Tools::DocFetcher,
      "fetch_doc"            => Dalembert::Tools::DocFetcher,
      "spec_inspector"       => Dalembert::Tools::SpecInspector,
      "inspect_spec"         => Dalembert::Tools::SpecInspector,
      "knowledge_store"      => Dalembert::Tools::KnowledgeStoreTool
    }.freeze

    SWE_BENCH_MODES = %w[swe_bench bug_hunter].freeze

    DEFAULT_LLM_MAX_RETRIES = 5
    DEFAULT_LLM_RETRY_DELAYS = [2.0, 5.0, 12.0, 25.0, 45.0].freeze
    LLM_RETRYABLE_METHODS = %i[call_with_system call_with_messages call chat].freeze
    TRANSIENT_LLM_HTTP_STATUSES = [429, 500, 502, 503, 504, 520, 522, 524, 529].freeze
    TRANSIENT_LLM_ERROR_PATTERN = /\b(429|500|502|503|504|520|522|524|529)\b|rate[\s_-]*limit|too many requests|timed?\s*out|timeout|connection reset|unexpected eof|temporarily unavailable|overloaded|bad gateway|service unavailable|gateway timeout/i

    attr_reader :profile_name, :model, :resolved_profile, :llm, :mode, :enabled_tools,
                :llm_max_retries, :llm_retry_delays

    class << self
      # Resolves the list of Dalembert cloud OSINT tools based on explicit whitelist,
      # execution mode, and disabled tool blacklist.
      #
      # @param cloud_tools [Array<String, Symbol, Class>, nil] Explicit whitelist of cloud tools
      # @param disabled_tools [Array<String, Symbol, Class>, nil] Explicit blacklist of tools/aliases
      # @param mode [String, Symbol, nil] Execution mode ("default", "architect", "swe_bench", "bug_hunter")
      # @return [Array<Class>] Resolved tool classes
      def resolve_cloud_tools(cloud_tools: nil, disabled_tools: nil, mode: nil)
        normalized_mode = mode.to_s.strip.downcase

        base_tools = if !cloud_tools.nil?
                       Array(cloud_tools).filter_map do |entry|
                         resolve_tool_entry(entry)
                       end.uniq
                     elsif SWE_BENCH_MODES.include?(normalized_mode)
                       SWE_BENCH_DEFAULT_CLOUD_TOOLS.dup
                     else
                       ALL_CLOUD_TOOLS.dup
                     end

        return base_tools if disabled_tools.nil?

        disabled_list = Array(disabled_tools)
        return base_tools if disabled_list.empty?

        disabled_classes = disabled_list.filter_map { |entry| resolve_tool_entry(entry) }
        disabled_names   = disabled_list.map { |entry| entry.to_s.strip.downcase }

        base_tools.reject do |tool_class|
          t_name = tool_class.respond_to?(:tool_name) ? tool_class.tool_name.to_s.strip.downcase : ""
          disabled_classes.include?(tool_class) || disabled_names.include?(t_name)
        end
      end

      private

      def resolve_tool_entry(entry)
        return nil if entry.nil?
        return entry if entry.is_a?(Class)

        CLOUD_TOOL_MAP[entry.to_s.strip.downcase]
      end
    end

    def initialize(
      name: :dalembert_agent,
      profile_name: "default",
      model: nil,
      tools: nil,
      cloud_tools: nil,
      disabled_tools: nil,
      mode: nil,
      llm_max_retries: DEFAULT_LLM_MAX_RETRIES,
      llm_retry_delays: DEFAULT_LLM_RETRY_DELAYS,
      llm_sleep_fn: nil,
      **kwargs
    )
      normalized_mode = mode.nil? || mode.to_s.strip.empty? ? "default" : mode.to_s.strip.downcase

      resolved_cloud_tools = self.class.resolve_cloud_tools(
        cloud_tools: cloud_tools,
        disabled_tools: disabled_tools,
        mode: normalized_mode
      )

      disabled_list = Array(disabled_tools)
      disabled_names = disabled_list.map { |t| t.to_s.strip.downcase }
      disabled_classes = disabled_list.filter_map { |t| t.is_a?(Class) ? t : CLOUD_TOOL_MAP[t.to_s.strip.downcase] }

      external_tools = Array(tools).reject do |tool|
        t_name = tool.respond_to?(:tool_name) ? tool.tool_name.to_s.strip.downcase : tool.to_s.strip.downcase
        disabled_names.include?(t_name) || disabled_classes.include?(tool)
      end

      combined_tools = (external_tools + resolved_cloud_tools).uniq
      custom_system_prompt = kwargs.delete(:system_prompt) || default_system_prompt

      # Resolve decoupled provider and model settings
      resolved_config = ProfileResolver.resolve(
        profile_name: profile_name,
        model: model
      )

      # Pass a safe YAML profile name to Descartes base when resolved_config already carries base_url,
      # avoiding premature RubyLLM::Profile.load errors on custom/env-driven profiles before @llm is replaced.
      super_profile_name = if resolved_config[:base_url] && !resolved_config[:base_url].to_s.strip.empty?
                             "default"
                           else
                             resolved_config[:profile_name] || profile_name
                           end

      # Pass the resolved provider channel name to Descartes base
      super(
        name: name,
        profile_name: super_profile_name,
        system_prompt: custom_system_prompt,
        tools: combined_tools,
        **kwargs
      )

      @profile_name = (resolved_config[:profile_name] || profile_name).to_s
      @resolved_profile = resolved_config
      @model = resolved_config[:model]
      @mode = normalized_mode
      @enabled_tools = combined_tools
      @llm_max_retries = llm_max_retries.nil? ? DEFAULT_LLM_MAX_RETRIES : [llm_max_retries.to_i, 0].max
      @llm_retry_delays = Array(llm_retry_delays || DEFAULT_LLM_RETRY_DELAYS).map(&:to_f).freeze
      @llm_sleep_fn = llm_sleep_fn
      @logger = kwargs[:logger] if kwargs.key?(:logger) && (!defined?(@logger) || @logger.nil?)

      # Preserve Descartes default survival tools (e.g., send_message, write_working_note)
      # added by super while still respecting explicit disabled_tools exclusions.
      if defined?(@tools) && @tools.is_a?(Array)
        @tools = @tools.reject do |t|
          t_name = t.respond_to?(:tool_name) ? t.tool_name.to_s.strip.downcase : t.to_s.strip.downcase
          disabled_names.include?(t_name) || disabled_classes.include?(t)
        end
      else
        @tools = combined_tools
      end

      # Explicitly initialize or override @llm with resolved decoupled configuration.
      # Omit :profile_name when base_url and api_key are already resolved so RubyLLM::LLMService
      # does not require a matching entry in llm.yml for custom env-backed profiles.
      llm_init_opts = resolved_config.dup
      if llm_init_opts[:base_url] && !llm_init_opts[:base_url].to_s.strip.empty? &&
         llm_init_opts[:api_key] && !llm_init_opts[:api_key].to_s.strip.empty?
        llm_init_opts.delete(:profile_name)
      end
      @llm = RubyLLM::LLMService.new(**llm_init_opts)
      install_llm_retry_wrapper!(@llm) unless @llm.nil? || @llm.frozen?
    end

    private

    def install_llm_retry_wrapper!(llm)
      return llm if llm.nil? || llm.frozen? || llm.instance_variable_defined?(:@_dalembert_retry_wrapped)

      llm.instance_variable_set(:@_dalembert_retry_wrapped, true)
      llm.instance_variable_set(:@_dalembert_in_retry_loop, false)

      agent_ref = self
      max_retries = @llm_max_retries
      retry_delays = @llm_retry_delays
      sleep_fn = @llm_sleep_fn

      LLM_RETRYABLE_METHODS.each do |method_name|
        next unless llm.respond_to?(method_name)

        orig_method = begin
          llm.method(method_name)
        rescue NameError
          nil
        end
        next unless orig_method

        llm.define_singleton_method(method_name) do |*args, **kwargs, &block|
          invoke_orig = lambda do
            if kwargs.empty?
              orig_method.call(*args, &block)
            else
              orig_method.call(*args, **kwargs, &block)
            end
          end

          return invoke_orig.call if instance_variable_get(:@_dalembert_in_retry_loop)

          instance_variable_set(:@_dalembert_in_retry_loop, true)
          begin
            attempts = 0
            begin
              invoke_orig.call
            rescue StandardError, Timeout::Error => e
              raise e unless agent_ref.send(:transient_llm_error?, e) && attempts < max_retries

              attempts += 1
              base_delay = if retry_delays.empty?
                             2.0
                           else
                             retry_delays[[attempts - 1, retry_delays.length - 1].min].to_f
                           end

              logger_obj = agent_ref.instance_variable_defined?(:@logger) ? agent_ref.instance_variable_get(:@logger) : nil
              logger_obj&.warn(
                "[Dalembert::Agent] Transient LLM error in #{method_name} " \
                "(retry #{attempts}/#{max_retries}, delay=#{base_delay}s): #{e.class}: #{e.message}"
              )

              if sleep_fn
                sleep_fn.call(base_delay)
              else
                Kernel.sleep(base_delay + (Kernel.rand * 1.0))
              end
              retry
            end
          ensure
            instance_variable_set(:@_dalembert_in_retry_loop, false)
          end
        end
      end

      llm
    end

    def transient_llm_error?(error, depth = 0)
      return false if error.nil? || depth > 3
      return true if error.is_a?(Timeout::Error) || error.is_a?(EOFError)
      return true if defined?(Errno::ECONNRESET) && error.is_a?(Errno::ECONNRESET)
      return true if defined?(Errno::ETIMEDOUT) && error.is_a?(Errno::ETIMEDOUT)
      return true if defined?(Errno::ECONNREFUSED) && error.is_a?(Errno::ECONNREFUSED)

      %i[status status_code http_status].each do |status_attr|
        next unless error.respond_to?(status_attr)

        code_val = error.public_send(status_attr)
        return true if code_val && TRANSIENT_LLM_HTTP_STATUSES.include?(code_val.to_i)
      end

      combined_msg = "#{error.class}: #{error.message}"
      return true if TRANSIENT_LLM_ERROR_PATTERN.match?(combined_msg)

      if error.respond_to?(:cause) && error.cause && !error.cause.equal?(error)
        return transient_llm_error?(error.cause, depth + 1)
      end

      false
    end

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
