# frozen_string_literal: true

require "descartes"
require_relative "../agent" unless defined?(Dalembert::Agent) && Dalembert::Agent.respond_to?(:resolve_cloud_tools)

=begin
================================================================================
Feature: 3-Stage SWE-bench State Machine Workflow (`SweBenchWorkflow`)
Task ID: dynamic_tool_masking_and_swe_bench_workflow_003

1. Problem / Feature Implemented:
   - Single-stage agent loops on complex bug-fixing tasks (such as SWE-bench)
     often suffer from premature code edits before root-cause localization, lack of
     minimal reproduction verification ("Red Light"), and temporal leakage via
     unrestricted GitHub search tools.
   - Implements `Dalembert::Workflows::SweBenchWorkflow` to enforce a strict 3-stage
     state machine (`:locate` -> `:reproduce` -> `:patch_and_verify`) with capability-based
     phase tool masking and full event streaming compatibility (`Descartes::EventEmitter`).

2. Method / Logic Used:
   - `self.classify_tool(tool_class)` categorizes any tool into one of four capability
     buckets (`:cloud_osint`, `:write_local`, `:exec_sandbox`, `:read_local`).
   - `phase_tools_for(stage)` enforces stage-level tool boundaries:
     - Stage 1 (`:locate`): `:read_local` + resolved cloud tools (no write, no exec,
       and GitHub search masked out by default in `swe_bench` mode).
     - Stage 2 (`:reproduce`): `:read_local` + `:exec_sandbox` + resolved cloud tools
       (no write tools).
     - Stage 3 (`:patch_and_verify`): `:read_local` + `:write_local` + `:exec_sandbox` +
       resolved cloud tools.
   - `execute(context, prompt)` runs all three stages sequentially, forwarding
     `:thought`, `:tool_call_start`, and `:tool_call_end` events to workflow subscribers,
     emitting `:phase_change` and `:thought` banners at each transition, persisting
     stage reports in `context` (`:localization_report`, `:reproduction_report`,
     `:patch_report`), and halting early if any stage returns `"Error: ..."`.

3. Caveats & Future Development Considerations:
   - `Descartes::Tool::Base.name(val)` overrides `Module#name` as a 1-argument DSL
     setter (`def self.name(val)`). Never call `tool_class.name` with 0 arguments on a
     `Descartes::Tool::Base` subclass; always use `tool_class.to_s` for the Ruby class
     name and `tool_class.tool_name` for the registered tool name.
   - `Descartes::EventEmitter#emit` inspects `block.arity`: when `block.arity == 1`, it
     calls `block.call(payload)`, whereas optional parameters (`|data = nil|`) have
     `arity == -1` and trigger `block.call(event, payload)`. Always use exact 1-arg
     blocks (`do |data|`) when subscribing to `Descartes::EventEmitter`.
   - When instantiating per-stage `Dalembert::Agent` instances, `cloud_tools: []` is
     passed alongside `tools: phase_tools_for(stage)` because `phase_tools_for(stage)`
     already contains `@resolved_cloud_tools`; this prevents `Dalembert::Agent` from
     re-injecting default cloud tools when `cloud_tools: []` was explicitly configured.
================================================================================
=end

module Dalembert
  module Workflows
    class SweBenchWorkflow
      include Descartes::EventEmitter if defined?(Descartes::EventEmitter)

      STAGES = %i[locate reproduce patch_and_verify].freeze

      WRITE_LOCAL_PATTERN = /\A(write_|edit_|replace_|apply_patch|patch|ast_replace|create_file|delete_file|modify_|str_replace)/i
      EXEC_SANDBOX_PATTERN = /\A(bash|sh|shell|run_|exec|execute|test|pytest|rspec|cargo)/i

      attr_reader :profile_name, :model, :tools, :cloud_tools, :disabled_tools,
                  :system_prompt, :max_turns, :logger, :resolved_cloud_tools, :extra_kwargs

      class << self
        # Classifies a tool class or object into one of four capability buckets:
        # :cloud_osint, :write_local, :exec_sandbox, or :read_local.
        #
        # @param tool_class [Class, Object]
        # @return [Symbol]
        def classify_tool(tool_class)
          return :cloud_osint if cloud_osint_tool?(tool_class)

          tool_name = extract_tool_name(tool_class)

          if tool_name.match?(WRITE_LOCAL_PATTERN)
            :write_local
          elsif tool_name.match?(EXEC_SANDBOX_PATTERN)
            :exec_sandbox
          else
            :read_local
          end
        end

        def extract_tool_name(tool_class)
          if tool_class.respond_to?(:tool_name) && tool_class.tool_name
            tool_class.tool_name.to_s
          else
            tool_class.to_s
          end
        end

        private

        def cloud_osint_tool?(tool_class)
          return true if defined?(Dalembert::Agent::ALL_CLOUD_TOOLS) && Dalembert::Agent::ALL_CLOUD_TOOLS.include?(tool_class)
          return true if tool_class.is_a?(Module) && tool_class.to_s.start_with?("Dalembert::Tools::")

          t_name = extract_tool_name(tool_class).strip.downcase
          defined?(Dalembert::Agent::CLOUD_TOOL_MAP) && Dalembert::Agent::CLOUD_TOOL_MAP.key?(t_name)
        end
      end

      def initialize(
        profile_name: "default",
        model: nil,
        tools: [],
        cloud_tools: nil,
        disabled_tools: nil,
        system_prompt: nil,
        max_turns: 30,
        logger: nil,
        **kwargs
      )
        @profile_name = profile_name
        @model = model
        @cloud_tools = cloud_tools
        @disabled_tools = disabled_tools
        @system_prompt = system_prompt
        @max_turns = max_turns
        @logger = logger
        @extra_kwargs = kwargs
        @listeners ||= Hash.new { |h, k| h[k] = [] }

        @resolved_cloud_tools = Dalembert::Agent.resolve_cloud_tools(
          cloud_tools: cloud_tools,
          disabled_tools: disabled_tools,
          mode: "swe_bench"
        )

        disabled_names = Array(disabled_tools).map { |t| t.to_s.strip.downcase }
        disabled_classes = Array(disabled_tools).filter_map do |t|
          t.is_a?(Class) ? t : Dalembert::Agent::CLOUD_TOOL_MAP[t.to_s.strip.downcase]
        end

        @tools = Array(tools).reject do |t|
          t_name = self.class.extract_tool_name(t).strip.downcase
          disabled_names.include?(t_name) || disabled_classes.include?(t)
        end
      end

      # Fallback event subscription if Descartes::EventEmitter is not present in minimal test stubs
      unless method_defined?(:on)
        def on(event, &block)
          @listeners ||= Hash.new { |h, k| h[k] = [] }
          @listeners[event.to_sym] << block if block
          self
        end
      end

      unless method_defined?(:emit)
        def emit(event, payload = nil)
          @listeners ||= Hash.new { |h, k| h[k] = [] }
          @listeners[event.to_sym].each do |block|
            if block.arity.zero?
              block.call
            elsif block.arity == 1
              block.call(payload)
            else
              block.call(event, payload)
            end
          end
        end
      end

      # Returns the allowed tools for a specific stage in the 3-stage SWE-bench state machine.
      #
      # @param stage [Symbol, String] :locate, :reproduce, or :patch_and_verify
      # @return [Array<Class>]
      def phase_tools_for(stage)
        stage_sym = stage.to_sym

        read_local_tools   = @tools.select { |t| self.class.classify_tool(t) == :read_local }
        exec_sandbox_tools = @tools.select { |t| self.class.classify_tool(t) == :exec_sandbox }
        write_local_tools  = @tools.select { |t| self.class.classify_tool(t) == :write_local }

        case stage_sym
        when :locate
          (read_local_tools + @resolved_cloud_tools).uniq
        when :reproduce
          (read_local_tools + exec_sandbox_tools + @resolved_cloud_tools).uniq
        when :patch_and_verify
          (read_local_tools + write_local_tools + exec_sandbox_tools + @resolved_cloud_tools).uniq
        else
          raise ArgumentError, "Unknown SWE-bench workflow stage: #{stage}"
        end
      end

      # Executes the 3-stage SWE-bench workflow (:locate -> :reproduce -> :patch_and_verify).
      #
      # @param context [Descartes::Context] Execution context
      # @param prompt [String] Issue description / task prompt
      # @return [String] Final patch and verification report, or early error string
      def execute(context, prompt)
        # Stage 1: :locate (Bug Localization Funnel)
        emit_stage_banner(:locate, "Phase 1/3 [:locate] — Bug Localization Funnel (Read-Only Inspection)")
        locate_agent = build_stage_agent(:locate)
        res1 = locate_agent.execute(context, build_locate_prompt(prompt))
        context.set(:localization_report, res1) if context.respond_to?(:set)
        return res1 if error_response?(res1)

        # Stage 2: :reproduce (Minimal Reproduction Verification — Red Light)
        emit_stage_banner(:reproduce, "Phase 2/3 [:reproduce] — Minimal Reproduction Verification (Red Light)")
        reproduce_agent = build_stage_agent(:reproduce)
        res2 = reproduce_agent.execute(context, build_reproduce_prompt(prompt, res1))
        context.set(:reproduction_report, res2) if context.respond_to?(:set)
        return res2 if error_response?(res2)

        # Stage 3: :patch_and_verify (Surgical Patch & Regression Gate — Green Light)
        emit_stage_banner(:patch_and_verify, "Phase 3/3 [:patch_and_verify] — Surgical Patch & Regression Gate (Green Light)")
        patch_agent = build_stage_agent(:patch_and_verify)
        res3 = patch_agent.execute(context, build_patch_and_verify_prompt(prompt, res1, res2))
        context.set(:patch_report, res3) if context.respond_to?(:set)
        res3
      end

      private

      def emit_stage_banner(stage, message)
        emit(:phase_change, stage)
        emit(:thought, "\n=== [SWE-bench Workflow] #{message} ===\n")
      end

      def build_stage_agent(stage)
        stage_tools = phase_tools_for(stage)
        agent = Dalembert::Agent.new(
          name: :"swe_bench_#{stage}",
          profile_name: @profile_name,
          model: @model,
          tools: stage_tools,
          cloud_tools: [],
          disabled_tools: @disabled_tools,
          mode: "swe_bench",
          system_prompt: stage_system_prompt(stage),
          max_turns: @max_turns,
          logger: @logger,
          **@extra_kwargs
        )

        %i[thought tool_call_start tool_call_end].each do |event_type|
          next unless agent.respond_to?(:on)

          agent.on(event_type) do |data|
            emit(event_type, data)
          end
        end

        agent
      end

      def error_response?(response)
        response.to_s.strip.start_with?("Error:")
      end

      def stage_system_prompt(stage)
        base_prefix = @system_prompt ? "#{@system_prompt}\n\n" : ""

        stage_instructions = case stage.to_sym
                             when :locate
                               <<~PROMPT
                                 You are operating in Stage 1 (:locate — Bug Localization Funnel) of the SWE-bench workflow.
                                 Strictly use read-only inspection tools to locate the exact files, classes, functions, line ranges, and root cause hypothesis.
                                 Do NOT attempt to modify files or guess fixes without reading the source code.
                               PROMPT
                             when :reproduce
                               <<~PROMPT
                                 You are operating in Stage 2 (:reproduce — Minimal Reproduction Verification) of the SWE-bench workflow.
                                 Using the localization report from Stage 1, run existing tests or execute a minimal reproduction command in the sandbox to confirm the failure (Red Light).
                                 Do NOT modify application business logic in this stage.
                               PROMPT
                             when :patch_and_verify
                               <<~PROMPT
                                 You are operating in Stage 3 (:patch_and_verify — Surgical Patch & Regression Gate) of the SWE-bench workflow.
                                 Apply a minimal, surgical patch addressing the root cause identified in Stage 1, then run the reproduction test from Stage 2 and relevant regression tests to confirm Green Light.
                               PROMPT
                             end

        "#{base_prefix}#{stage_instructions}".strip
      end

      def build_locate_prompt(prompt)
        <<~PROMPT
          [Stage 1: Bug Localization Funnel (:locate)]
          Issue Description:
          #{prompt}

          Deliver a structured Localization Report identifying:
          1. Suspect file paths and line ranges
          2. Relevant classes/methods/AST symbols
          3. Root cause hypothesis
        PROMPT
      end

      def build_reproduce_prompt(prompt, localization_report)
        <<~PROMPT
          [Stage 2: Minimal Reproduction Verification (:reproduce)]
          Original Issue:
          #{prompt}

          Stage 1 Localization Report:
          #{localization_report}

          Execute tests or reproduction commands to observe the bug failure (Red Light) and summarize the reproduction command and failure output.
        PROMPT
      end

      def build_patch_and_verify_prompt(prompt, localization_report, reproduction_report)
        <<~PROMPT
          [Stage 3: Surgical Patch & Regression Gate (:patch_and_verify)]
          Original Issue:
          #{prompt}

          Stage 1 Localization Report:
          #{localization_report}

          Stage 2 Reproduction Report (Red Light):
          #{reproduction_report}

          Apply the minimal surgical fix and run the test suite to verify Green Light and zero regressions.
        PROMPT
      end
    end
  end
end
