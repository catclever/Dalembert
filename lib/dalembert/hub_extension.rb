# frozen_string_literal: true

require "json"

begin
  require "descartes/hub"
rescue LoadError
  # Allow standalone testing with stubbed Descartes::Hub classes
end

require_relative "profile_resolver" unless defined?(Dalembert::ProfileResolver)
require_relative "agent" unless defined?(Dalembert::Agent)
require_relative "workflows/swe_bench_workflow" unless defined?(Dalembert::Workflows::SweBenchWorkflow)

=begin
================================================================================
Feature: Descartes::Hub::Session Extension for SWE-bench Routing & Tool Masking
Task ID: hub_session_swe_bench_routing_and_budget_005

1. Problem / Feature Implemented:
   - `Descartes::Hub::Session` previously instantiated raw `Descartes::Agent::Base`
     without Dalembert's orthogonal `ProfileResolver` (`model:`), frontend tool
     manifest (`cloud_tools`, `disabled_tools`), or 3-stage `SweBenchWorkflow`
     routing (`mode: "swe_bench"` / `"bug_hunter"`).
   - Incoming `init` and `execute_tool` frames from `EnginEdge` via
     `Descartes::Hub::Protocol.parse` contain Symbol keys (and callers/specs may
     pass String keys).

2. Method / Logic Used:
   - `Dalembert::HubExtension.install!` prepends `SessionPatch` onto
     `Descartes::Hub::Session` idempotently.
   - `SessionPatch#handle_init(payload)` normalizes Symbol/String keys, filters
     edge `tools` against `disabled_tools`, converts `cloud_tools` cleanly (defaulting
     to `[]` in `"swe_bench"` mode when omitted, and passing `nil` when omitted in
     non-`swe_bench` mode), routes `"swe_bench"` / `"bug_hunter"` to
     `Dalembert::Workflows::SweBenchWorkflow`, routes other modes to `Dalembert::Agent`,
     wires 1-argument event stream subscriptions (`:thought`, `:tool_call_start`,
     `:tool_call_end`, `:phase_change`), and executes inside `@thread`.
   - `SessionPatch#handle_execute_tool(payload)` blocks any tool in
     `@disabled_tools` / `extra_disabled` (by canonical name or alias) or any cloud
     tool excluded from `@resolved_cloud_tools`, and executes permitted Dalembert
     cloud tools asynchronously in a background thread.

3. Caveats & Future Development Considerations:
   - `Descartes::Hub::Session` uses `build_remote_tool_class(schema)` (private) and
     `send_message(payload)` (public). Do NOT call nonexistent `Descartes::Hub::RemoteTool`
     or `send_frame`.
   - Always pass `nil` (never `:all`) for `cloud_tools` when omitted in non-`swe_bench`
     mode so `Dalembert::Agent.resolve_cloud_tools` falls back to default cloud tools.
================================================================================
=end

module Dalembert
  module HubExtension
    CLOUD_TOOL_LOOKUP = Dalembert::Agent::CLOUD_TOOL_MAP.merge(
      "knowledge_store_tool" => Dalembert::Tools::KnowledgeStoreTool
    ).freeze

    def self.install!
      return false unless defined?(Descartes::Hub::Session)

      unless Descartes::Hub::Session.ancestors.include?(SessionPatch)
        Descartes::Hub::Session.prepend(SessionPatch)
      end
      true
    end

    module SessionPatch
      attr_reader :agent, :mode, :disabled_tools, :cloud_tools, :resolved_cloud_tools, :thread

      def handle_init(payload)
        payload = {} unless payload.is_a?(Hash)

        @mutex ||= Mutex.new
        @state ||= :created
        @session_id ||= object_id

        @mutex.synchronize do
          raise "Session already initialized" unless @state == :created

          @state = :running
        end

        task_name = first_present_value(payload, :task_name, "task_name")
        task_name = task_name.to_s if task_name

        raw_prompt = payload_fetch(payload, :prompt, "prompt")
        raw_prompt = payload_fetch(payload, :job, "job") if raw_prompt.nil?
        prompt = raw_prompt.to_s

        raw_system_prompt = first_present_value(payload, :system_prompt, "system_prompt")
        system_prompt = raw_system_prompt ? raw_system_prompt.to_s : nil

        raw_mode = first_present_value(payload, :mode, "mode", :workflow, "workflow") || ENV["DALEMBERT_MODE"]
        mode = raw_mode ? raw_mode.to_s.strip.downcase : nil
        mode = nil if mode && mode.empty?
        @mode = mode

        raw_profile = first_present_value(payload, :llm_profile, "llm_profile", :profile, "profile") ||
                      ENV["LLM_PROFILE"] || ENV["DEFAULT_LLM_PROFILE"] || "default"
        profile_name = raw_profile.to_s.strip
        profile_name = "default" if profile_name.empty?

        raw_model = first_present_value(payload, :model, "model", :llm_model, "llm_model")
        model = raw_model ? raw_model.to_s.strip : nil
        model = nil if model && model.empty?

        has_cloud_tools = payload_key?(payload, :cloud_tools, "cloud_tools")
        raw_cloud_tools = if payload.key?(:cloud_tools)
                            payload[:cloud_tools]
                          elsif payload.key?("cloud_tools")
                            payload["cloud_tools"]
                          end

        raw_disabled = payload_fetch(payload, :disabled_tools, "disabled_tools")
        @disabled_tools = Array(raw_disabled).map { |t| t.to_s.strip }.reject(&:empty?)

        raw_max_turns = first_present_value(payload, :max_turns, "max_turns") || ENV["MAX_TURNS"]
        default_turns = if %w[swe_bench bug_hunter].include?(mode)
                          Dalembert::Workflows::SweBenchWorkflow::DEFAULT_MAX_TURNS
                        else
                          30
                        end
        max_turns = raw_max_turns.to_i > 0 ? raw_max_turns.to_i : default_turns

        disabled_downcased = @disabled_tools.map(&:downcase)
        remote_tools = build_filtered_remote_tools(
          payload_fetch(payload, :tools, "tools"),
          disabled_downcased
        )

        effective_cloud_tools = if mode == "swe_bench" && !has_cloud_tools
                                  []
                                else
                                  raw_cloud_tools
                                end
        @cloud_tools = effective_cloud_tools

        @resolved_cloud_tools = Dalembert::Agent.resolve_cloud_tools(
          cloud_tools: effective_cloud_tools,
          disabled_tools: @disabled_tools,
          mode: mode
        )

        @agent = if %w[swe_bench bug_hunter].include?(mode)
                   Dalembert::Workflows::SweBenchWorkflow.new(
                     profile_name: profile_name,
                     model: model,
                     tools: remote_tools,
                     cloud_tools: effective_cloud_tools,
                     disabled_tools: @disabled_tools,
                     system_prompt: system_prompt,
                     max_turns: max_turns,
                     logger: @logger
                   )
                 else
                   agent_kwargs = {
                     name: :"hub_agent_#{@session_id}",
                     profile_name: profile_name,
                     model: model,
                     tools: remote_tools,
                     cloud_tools: raw_cloud_tools,
                     disabled_tools: @disabled_tools,
                     mode: mode,
                     max_turns: max_turns,
                     logger: @logger
                   }
                   agent_kwargs[:system_prompt] = system_prompt if system_prompt
                   Dalembert::Agent.new(**agent_kwargs)
                 end

        wire_agent_event_streams(@agent)

        @context = build_session_context(task_name)

        @thread = Thread.new do
          run_session_loop(@context, prompt)
        end
      rescue StandardError
        @mutex.synchronize { @state = :aborted }
        raise
      end

      def handle_execute_tool(payload)
        payload = {} unless payload.is_a?(Hash)

        call_id = payload_fetch(payload, :call_id, "call_id")
        tool_name = payload_fetch(payload, :tool_name, "tool_name", :tool, "tool").to_s.strip
        raw_args = payload_fetch(payload, :args, "args", :arguments, "arguments") || {}
        extra_disabled = Array(payload_fetch(payload, :disabled_tools, "disabled_tools"))
                         .map { |t| t.to_s.strip }
                         .reject(&:empty?)

        normalized_tool = tool_name.downcase
        tool_class = CLOUD_TOOL_LOOKUP[normalized_tool]

        combined_disabled = (Array(@disabled_tools) + extra_disabled).map { |t| t.to_s.strip.downcase }.reject(&:empty?)
        disabled_classes = combined_disabled.filter_map { |t| CLOUD_TOOL_LOOKUP[t] }

        is_disabled = combined_disabled.include?(normalized_tool) ||
                      (tool_class && disabled_classes.include?(tool_class))

        is_excluded_cloud_tool = !@resolved_cloud_tools.nil? &&
                                 tool_class &&
                                 !@resolved_cloud_tools.include?(tool_class)

        if is_disabled || is_excluded_cloud_tool
          send_message(
            Descartes::Hub::Protocol.build(
              :tool_result,
              call_id: call_id,
              output: "Error: Tool '#{tool_name}' is disabled for this session"
            )
          )
          return
        end

        if tool_class.nil?
          send_message(
            Descartes::Hub::Protocol.build(
              :tool_result,
              call_id: call_id,
              output: "Error: Unknown tool '#{tool_name}'"
            )
          )
          return
        end

        normalized_args = normalize_tool_args(raw_args)
        Thread.new do
          begin
            tool_instance = if tool_class.instance_method(:initialize).arity.zero?
                              tool_class.new
                            else
                              tool_class.new(@context)
                            end
            output = tool_instance.execute(normalized_args)
            send_message(
              Descartes::Hub::Protocol.build(
                :tool_result,
                call_id: call_id,
                output: output.to_s
              )
            )
          rescue StandardError => e
            send_message(
              Descartes::Hub::Protocol.build(
                :tool_result,
                call_id: call_id,
                output: "Error executing tool '#{tool_name}': #{e.message}"
              )
            )
          end
        end
      end

      private

      def build_session_context(task_name)
        return nil unless defined?(Descartes::Context)

        ctx = begin
          Descartes::Context.new(task_name ? { task_name: task_name } : {})
        rescue ArgumentError
          Descartes::Context.new
        end
        if task_name && ctx.respond_to?(:set) && (!ctx.respond_to?(:get) || ctx.get(:task_name).nil?)
          ctx.set(:task_name, task_name)
        end
        ctx
      end

      def run_session_loop(context, prompt)
        result = @agent.execute(context, prompt)
        if result.is_a?(String) && result.start_with?("Error:")
          @mutex.synchronize { @state = :aborted }
          send_message(Descartes::Hub::Protocol.build(:error, message: result))
        else
          @mutex.synchronize { @state = :finished }
          send_message(Descartes::Hub::Protocol.build(:finished, result: result, status: "ok"))
        end
      rescue StandardError => e
        @logger.error("[Dalembert::HubExtension] Session execution error: #{e.class}: #{e.message}") if @logger.respond_to?(:error)
        @mutex.synchronize { @state = :aborted }
        send_message(Descartes::Hub::Protocol.build(:error, message: "Error: #{e.message}"))
      end

      def wire_agent_event_streams(agent)
        return unless agent.respond_to?(:on)

        agent.on(:thought) do |data|
          send_message(Descartes::Hub::Protocol.build(:stream_event, event: "thought", data: data))
        end
        agent.on(:tool_call_start) do |data|
          send_message(Descartes::Hub::Protocol.build(:stream_event, event: "tool_call_start", data: data))
        end
        agent.on(:tool_call_end) do |data|
          send_message(Descartes::Hub::Protocol.build(:stream_event, event: "tool_call_end", data: data))
        end
        agent.on(:phase_change) do |stage|
          send_message(Descartes::Hub::Protocol.build(:stream_event, event: "phase_change", data: stage.to_s))
        end
      end

      def build_filtered_remote_tools(raw_tools, disabled_downcased)
        Array(raw_tools).filter_map do |schema|
          if schema.is_a?(Class)
            klass_name = schema.respond_to?(:tool_name) ? schema.tool_name.to_s.strip.downcase : schema.to_s.downcase
            next if disabled_downcased.include?(klass_name)

            next schema
          end

          next unless schema.is_a?(Hash)

          t_name = (schema[:name] || schema["name"]).to_s.strip
          next if t_name.empty? || disabled_downcased.include?(t_name.downcase)

          normalized_schema = symbolize_keys_deep(schema)
          klass = if respond_to?(:build_remote_tool_class, true)
                    send(:build_remote_tool_class, normalized_schema)
                  else
                    build_dalembert_remote_tool_class(normalized_schema)
                  end
          klass_name = klass.respond_to?(:tool_name) ? klass.tool_name.to_s.strip.downcase : t_name.downcase
          next if disabled_downcased.include?(klass_name)

          klass
        end
      end

      def build_dalembert_remote_tool_class(schema)
        tool_name_str = (schema[:name] || schema["name"]).to_s
        tool_desc     = (schema[:description] || schema["description"] || "Remote tool #{tool_name_str}").to_s
        tool_params   = schema[:parameters] || schema["parameters"] || { type: "object", properties: {} }
        session_ref   = self

        Class.new(Descartes::Tool::Base) do
          name tool_name_str
          description tool_desc
          parameters tool_params

          define_method(:execute) do |args = {}|
            if session_ref.respond_to?(:invoke_remote_tool, true)
              session_ref.send(:invoke_remote_tool, tool_name_str, args)
            else
              "Error: Remote tool execution transport not available for '#{tool_name_str}'"
            end
          end
        end
      end

      def payload_key?(payload, *keys)
        return false unless payload.is_a?(Hash)

        keys.any? { |k| payload.key?(k) }
      end

      def payload_fetch(payload, *keys)
        return nil unless payload.is_a?(Hash)

        keys.each do |key|
          return payload[key] if payload.key?(key)
        end
        nil
      end

      def first_present_value(payload, *keys)
        return nil unless payload.is_a?(Hash)

        keys.each do |key|
          next unless payload.key?(key)

          val = payload[key]
          next if val.nil?
          next if val.is_a?(String) && val.strip.empty?

          return val
        end
        nil
      end

      def symbolize_keys_deep(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = symbolize_keys_deep(v) }
        when Array
          obj.map { |v| symbolize_keys_deep(v) }
        else
          obj
        end
      end

      def stringify_keys_deep(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = stringify_keys_deep(v) }
        when Array
          obj.map { |v| stringify_keys_deep(v) }
        else
          obj
        end
      end

      def normalize_tool_args(raw_args)
        parsed = if raw_args.is_a?(String)
                   begin
                     JSON.parse(raw_args)
                   rescue JSON::ParserError
                     {}
                   end
                 else
                   raw_args
                 end
        return {} unless parsed.is_a?(Hash)

        stringify_keys_deep(parsed)
      end
    end
  end
end

Dalembert::HubExtension.install!
