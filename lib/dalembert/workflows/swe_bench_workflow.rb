# frozen_string_literal: true

require "json"
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

=begin
================================================================================
Feature: Segmented Turn Quota, Unused-Turn Rollover & Graceful Sub-Stage Handoff
Task ID: hub_session_swe_bench_routing_and_budget_005

1. Problem / Feature Implemented:
   - Passing the full `max_turns` budget identically to each of the 3 SWE-bench
     stages allowed Stage 1 (`:locate`) or Stage 2 (`:reproduce`) to exhaust up to 3x
     the intended session budget, or fail fatally when hitting the turn limit despite
     having gathered useful localization/reproduction findings.
   - Additionally, `append_file` and `manage_imports` edge tools were previously
     classified as `:read_local` rather than `:write_local`.

2. Method / Logic Used:
   - Raised `DEFAULT_MAX_TURNS` to `45` and expanded `WRITE_LOCAL_PATTERN` to include
     `append_` and `manage_imports`.
   - Implemented Option A Segmented Turn Quota + Unused-Turn Rollover:
     - Stage 1 (`:locate`): `ceil(total * 0.30)` (clamped to `1..total - 2`, 14 for 45).
     - Stage 2 (`:reproduce`): `ceil(total * 0.25)` (clamped to `1..rem_after_1 - 1`, 12 for 45).
     - Stage 3 (`:patch_and_verify`): receives 100% of remaining unused turns (`[rem_after_1 - reproduce_used, 1].max`).
   - Tracks consumed turns by wrapping `agent.llm.call_with_system` (falling back
     to `tool_turns` or `stage_budget` when mocked without `call_with_system`) and
     captures a bounded 25-entry `stage_trace` of thoughts and tool events.
   - When Stage 1 or Stage 2 returns `MAX_TURNS_EXCEEDED_PREFIX`, synthesizes a
     structured auto-handoff report from `stage_trace` and advances cleanly to the
     next stage; all other `"Error: ..."` responses still halt immediately.

3. Caveats & Future Development Considerations:
   - Do NOT pass keyword arguments (`run_max_turns:`) to `agent.execute(...)`; pass
     per-stage budgets via `max_turns:` in `Dalembert::Agent.new` so 2-argument
     test stubs on `agent.execute` remain compatible.
================================================================================
=end

module Dalembert
  module Workflows
    class SweBenchWorkflow
      include Descartes::EventEmitter if defined?(Descartes::EventEmitter)

      STAGES = %i[locate reproduce patch_and_verify].freeze
      DEFAULT_MAX_TURNS = 45
      MAX_TURNS_EXCEEDED_PREFIX = "Error: Agent exceeded maximum allowed reasoning turns"
      STAGE_TRACE_LIMIT = 25

      WRITE_LOCAL_PATTERN = /\A(write_|append_|edit_|replace_|manage_imports|apply_patch|patch|ast_replace|create_file|delete_file|modify_|str_replace)/i
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
        max_turns: DEFAULT_MAX_TURNS,
        logger: nil,
        **kwargs
      )
        @profile_name = profile_name
        @model = model
        @cloud_tools = cloud_tools
        @disabled_tools = disabled_tools
        @system_prompt = system_prompt
        @max_turns = max_turns.nil? ? DEFAULT_MAX_TURNS : max_turns
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

      # Executes the 3-stage SWE-bench workflow (:locate -> :reproduce -> :patch_and_verify)
      # using segmented turn quotas, unused-turn rollover, and graceful turn-cap auto-handoff.
      #
      # @param context [Descartes::Context] Execution context
      # @param prompt [String] Issue description / task prompt
      # @return [String] Final patch and verification report, or early error string
      def execute(context, prompt)
        total_budget = (@max_turns.to_i > 0 ? [@max_turns.to_i, 3].max : DEFAULT_MAX_TURNS)

        # Stage 1: :locate (Bug Localization Funnel)
        locate_budget = [[(total_budget * 0.30).ceil, 1].max, total_budget - 2].min
        emit_stage_banner(:locate, "Phase 1/3 [:locate] — Bug Localization Funnel (Read-Only Inspection)")
        res1, locate_used, trace1, submitted1 = run_stage_with_tracking(
          :locate,
          locate_budget,
          context,
          build_locate_prompt(prompt)
        )
        res1 = unwrap_stage_result(res1, context, submitted1)
        if max_turns_exceeded?(res1)
          res1 = synthesize_auto_handoff(:locate, locate_budget, trace1)
          emit(:thought, "\n[SWE-bench Workflow] Stage :locate reached #{locate_budget}-turn cap; advancing with auto-handoff.\n")
          context.set(:localization_report, res1) if context.respond_to?(:set)
        elsif error_response?(res1)
          context.set(:localization_report, res1) if context.respond_to?(:set)
          return res1
        else
          context.set(:localization_report, res1) if context.respond_to?(:set)
        end

        # Stage 2: :reproduce (Minimal Reproduction Verification — Red Light)
        rem_after_1 = [total_budget - locate_used, 2].max
        reproduce_budget = [[(total_budget * 0.25).ceil, 1].max, rem_after_1 - 1].min
        emit_stage_banner(:reproduce, "Phase 2/3 [:reproduce] — Minimal Reproduction Verification (Red Light)")
        res2, reproduce_used, trace2, submitted2 = run_stage_with_tracking(
          :reproduce,
          reproduce_budget,
          context,
          build_reproduce_prompt(prompt, res1)
        )
        res2 = unwrap_stage_result(res2, context, submitted2)
        if max_turns_exceeded?(res2)
          res2 = synthesize_auto_handoff(:reproduce, reproduce_budget, trace2)
          emit(:thought, "\n[SWE-bench Workflow] Stage :reproduce reached #{reproduce_budget}-turn cap; advancing with auto-handoff.\n")
          context.set(:reproduction_report, res2) if context.respond_to?(:set)
        elsif error_response?(res2)
          context.set(:reproduction_report, res2) if context.respond_to?(:set)
          return res2
        else
          context.set(:reproduction_report, res2) if context.respond_to?(:set)
        end

        # Stage 3: :patch_and_verify (Surgical Patch & Regression Gate — Green Light)
        patch_budget = [rem_after_1 - reproduce_used, 1].max
        emit_stage_banner(:patch_and_verify, "Phase 3/3 [:patch_and_verify] — Surgical Patch & Regression Gate (Green Light)")
        res3, _patch_used, _trace3, submitted3 = run_stage_with_tracking(
          :patch_and_verify,
          patch_budget,
          context,
          build_patch_and_verify_prompt(prompt, res1, res2)
        )
        res3 = unwrap_stage_result(res3, context, submitted3)
        context.set(:patch_report, res3) if context.respond_to?(:set)
        res3
      end

      private

      def emit_stage_banner(stage, message)
        emit(:phase_change, stage)
        emit(:thought, "\n=== [SWE-bench Workflow] #{message} ===\n")
      end

      def build_stage_agent(stage, stage_max_turns: @max_turns)
        effective_max_turns = stage_max_turns.to_i > 0 ? stage_max_turns.to_i : @max_turns
        stage_tools = phase_tools_for(stage)
        agent = Dalembert::Agent.new(
          name: :"swe_bench_#{stage}",
          profile_name: @profile_name,
          model: @model,
          tools: stage_tools,
          cloud_tools: [],
          disabled_tools: @disabled_tools,
          mode: "swe_bench",
          system_prompt: stage_system_prompt(stage, effective_max_turns),
          max_turns: effective_max_turns,
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

      def run_stage_with_tracking(stage, stage_budget, context, stage_prompt)
        agent = build_stage_agent(stage, stage_max_turns: stage_budget)

        llm_calls = 0
        tool_turns = 0
        stage_trace = []
        last_submitted_value = nil

        llm = agent.respond_to?(:llm) ? agent.llm : nil
        if llm && llm.respond_to?(:call_with_system) && !llm.frozen?
          counter_proc = -> { llm_calls += 1 }
          llm.instance_variable_set(:@_dalembert_stage_turn_hook, counter_proc)

          unless llm.instance_variable_defined?(:@_dalembert_call_wrapped)
            orig_call = begin
              llm.method(:call_with_system)
            rescue NameError
              nil
            end

            if orig_call
              llm.instance_variable_set(:@_dalembert_call_wrapped, true)
              llm.define_singleton_method(:call_with_system) do |*args, **kwargs, &block|
                hook = instance_variable_get(:@_dalembert_stage_turn_hook)
                hook&.call
                if kwargs.empty?
                  orig_call.call(*args, &block)
                else
                  orig_call.call(*args, **kwargs, &block)
                end
              end
            end
          end
        end

        if agent.respond_to?(:on)
          agent.on(:thought) do |data|
            record_stage_thought(stage_trace, data)
          end
          agent.on(:tool_call_start) do |data|
            tool_turns += 1
            captured_val = extract_send_message_value(data)
            last_submitted_value = captured_val unless captured_val.nil?
            record_stage_tool_start(stage_trace, data)
          end
          agent.on(:tool_call_end) do |data|
            record_stage_tool_end(stage_trace, data)
          end
        end

        res = agent.execute(context, stage_prompt)

        used = if llm_calls > 0
                 [llm_calls, stage_budget].min
               elsif max_turns_exceeded?(res)
                 stage_budget
               else
                 [[tool_turns, 1].max, stage_budget].min
               end

        [res, used, stage_trace, last_submitted_value]
      end

      def extract_send_message_value(data)
        return nil unless data.is_a?(Hash)

        tool = (data[:tool] || data["tool"] || data[:name] || data["name"]).to_s.strip
        return nil unless tool == "send_message"

        raw_args = data[:arguments] || data["arguments"] || data[:args] || data["args"]
        parsed = case raw_args
                 when Hash
                   raw_args
                 when String
                   begin
                     defined?(LLMJSON) ? LLMJSON.parse(raw_args) : JSON.parse(raw_args)
                   rescue StandardError
                     nil
                   end
                 end
        return nil unless parsed.is_a?(Hash)

        parsed["value"] || parsed[:value]
      end

      def unwrap_stage_result(raw_res, context, last_submitted_value = nil)
        res_str = raw_res.to_s
        match = res_str.match(/\ASuccessfully saved output to context key '(.+)'\z/m)
        return raw_res unless match

        key_name = match[1].to_s
        saved_val = context.get(key_name.to_sym) if context.respond_to?(:get)
        saved_str = saved_val.nil? ? nil : saved_val.to_s
        if saved_str && !saved_str.strip.empty? && !saved_str.start_with?("Successfully saved output to context key '")
          return saved_str
        end

        return last_submitted_value.to_s if last_submitted_value && !last_submitted_value.to_s.strip.empty?

        raw_res
      end

      def record_stage_thought(stage_trace, data)
        text = if data.is_a?(Hash)
                 data[:text] || data["text"] || data[:content] || data["content"] || data.inspect
               else
                 data.to_s
               end
        cleaned = text.to_s.strip
        return if cleaned.empty?

        push_trace_entry(stage_trace, "[thought] #{truncate_trace(cleaned, 400)}")
      end

      def record_stage_tool_start(stage_trace, data)
        entry = if data.is_a?(Hash)
                  tool = data[:tool] || data["tool"] || data[:name] || data["name"] || "unknown"
                  args = data[:args] || data["args"] || data[:arguments] || data["arguments"]
                  args_str = args ? truncate_trace(args.inspect, 200) : ""
                  args_str.empty? ? "[tool_start] #{tool}" : "[tool_start] #{tool} #{args_str}"
                else
                  "[tool_start] #{truncate_trace(data.to_s.strip, 200)}"
                end
        push_trace_entry(stage_trace, entry)
      end

      def record_stage_tool_end(stage_trace, data)
        entry = if data.is_a?(Hash)
                  tool = data[:tool] || data["tool"] || data[:name] || data["name"] || "unknown"
                  res = data[:result] || data["result"] || data[:output] || data["output"]
                  res_str = res ? truncate_trace(res.to_s.strip, 300) : ""
                  res_str.empty? ? "[tool_end] #{tool}" : "[tool_end] #{tool} => #{res_str}"
                else
                  "[tool_end] #{truncate_trace(data.to_s.strip, 300)}"
                end
        push_trace_entry(stage_trace, entry)
      end

      def push_trace_entry(stage_trace, entry)
        stage_trace << entry
        stage_trace.shift while stage_trace.length > STAGE_TRACE_LIMIT
      end

      def truncate_trace(str, limit)
        return str if str.length <= limit

        "#{str[0, limit]}..."
      end

      def synthesize_auto_handoff(stage, budget, stage_trace)
        summary = stage_trace.empty? ? "(no intermediate trace events recorded)" : stage_trace.join("\n")
        "[Stage :#{stage} auto-handoff after #{budget} turn limit]\n#{summary}"
      end

      def max_turns_exceeded?(response)
        response.to_s.strip.start_with?(MAX_TURNS_EXCEEDED_PREFIX)
      end

      def error_response?(response)
        response.to_s.strip.start_with?("Error:")
      end

      def stage_system_prompt(stage, stage_budget = nil)
        has_custom = @system_prompt && !@system_prompt.to_s.strip.empty?
        base_prefix = has_custom ? "#{@system_prompt}\n\n" : ""

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

        budget_guidance = if stage_budget && stage_budget.to_i > 0
                            "\n\nStage turn budget: up to #{stage_budget.to_i} turns. Call 'send_message' to submit your stage report before exhausting this budget."
                          else
                            ""
                          end

        "#{base_prefix}#{stage_instructions.strip}#{budget_guidance}".strip
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

          Submit your final Localization Report via send_message(key: "localization_report", value: "<report>").
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
          Submit your Reproduction Report via send_message(key: "reproduction_report", value: "<report>").
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
          Submit your final Patch & Verification Report via send_message(key: "patch_report", value: "<report>").
        PROMPT
      end
    end
  end
end
