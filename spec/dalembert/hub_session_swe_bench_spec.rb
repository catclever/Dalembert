# frozen_string_literal: true

require "json"
require "logger"
require "rspec"

=begin
================================================================================
Test Suite: Descartes::Hub::Session SWE-bench Routing & Tool Masking Specs
Task ID: hub_session_swe_bench_routing_and_budget_005

1. Problem / Feature Tested:
   - End-to-end verification of `Dalembert::HubExtension::SessionPatch` prepended
     onto `Descartes::Hub::Session` for realistic `EnginEdge` WebSocket `init` and
     `execute_tool` frames.
   - Verifies routing of `"swe_bench"` / `"bug_hunter"` sessions to
     `Dalembert::Workflows::SweBenchWorkflow` with `model`, `max_turns`,
     `disabled_tools`, and `cloud_tools` enforcement.
   - Verifies 6 -> 7 -> 11 stage tool progression across the 13 `EnginEdge` tool
     schemas, complete removal of `ping`/`echo` and all 5 `Dalembert::Tools::*`,
     and streaming `phase_change` + `finished` frames.
   - Verifies `handle_execute_tool` blocks disabled/excluded cloud tools (including
     aliases) and preserves non-`swe_bench` default cloud tool mounting when
     `cloud_tools` is omitted.
================================================================================
=end

module RubyLLM
  class LLMService
    attr_reader :model unless method_defined?(:model)

    def initialize(**args)
      @model = args[:model]
    end unless method_defined?(:initialize)
  end
end

require "dalembert"

RSpec.describe Dalembert::HubExtension do
  let(:engine_edge_tool_schemas) do
    [
      { "name" => "list_files",       "description" => "List files",       "parameters" => { "type" => "object", "properties" => {} } },
      { "name" => "read_file",        "description" => "Read file",        "parameters" => { "type" => "object", "properties" => {} } },
      { "name" => "grep_search",      "description" => "Grep search",      "parameters" => { "type" => "object", "properties" => {} } },
      { "name" => "get_outline",      "description" => "Get outline",      "parameters" => { "type" => "object", "properties" => {} } },
      { "name" => "read_symbol",      "description" => "Read symbol",      "parameters" => { "type" => "object", "properties" => {} } },
      { "name" => "replace_symbol",   "description" => "Replace symbol",   "parameters" => { "type" => "object", "properties" => {} } },
      { "name" => "manage_imports",   "description" => "Manage imports",   "parameters" => { "type" => "object", "properties" => {} } },
      { "name" => "write_file",       "description" => "Write file",       "parameters" => { "type" => "object", "properties" => {} } },
      { "name" => "append_file",      "description" => "Append file",      "parameters" => { "type" => "object", "properties" => {} } },
      { "name" => "run_verification", "description" => "Run verification", "parameters" => { "type" => "object", "properties" => {} } },
      { "name" => "get_status",       "description" => "Get status",       "parameters" => { "type" => "object", "properties" => {} } },
      { "name" => "ping",             "description" => "Ping edge",        "parameters" => { "type" => "object", "properties" => {} } },
      { "name" => "echo",             "description" => "Echo edge",        "parameters" => { "type" => "object", "properties" => {} } }
    ]
  end

  let(:swe_bench_init_json) do
    JSON.generate(
      type: "init",
      task_name: "swe_django__django-11099",
      mode: "swe_bench",
      cloud_tools: [],
      disabled_tools: %w[ping echo],
      llm_profile: "default",
      model: "hy4",
      max_turns: 45,
      prompt: "Fix ASCIIUsernameValidator trailing newline handling in Django.",
      system_prompt: "You are an automated SWE-bench solver.",
      tools: engine_edge_tool_schemas
    )
  end

  let(:sent_frames) { [] }

  def build_test_session(frames_sink)
    raise "Descartes::Hub::Session is required for HubExtension specs" unless defined?(Descartes::Hub::Session)

    channel_class = Class.new do
      def initialize(sink)
        @sink = sink
      end

      def send(*args, &block)
        if args.length == 1 && !args[0].is_a?(Symbol)
          @sink << args[0]
        else
          super
        end
      end
    end

    Descartes::Hub::Session.new(
      channel: channel_class.new(frames_sink),
      logger: Logger.new(File::NULL)
    )
  end

  let(:session) { build_test_session(sent_frames) }

  def decode_frame(frame)
    parsed = frame.is_a?(String) ? JSON.parse(frame, symbolize_names: true) : frame
    parsed.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
  end

  it "prepends SessionPatch onto Descartes::Hub::Session" do
    expect(described_class.install!).to be true
    expect(Descartes::Hub::Session.ancestors).to include(Dalembert::HubExtension::SessionPatch)
  end

  describe "SWE-bench init routing, tool masking (6 -> 7 -> 11), and phase streaming" do
    it "routes mode: 'swe_bench' to SweBenchWorkflow, strips cloud/disabled tools, enforces 6->7->11 progression, and emits phase_change + finished frames" do
      stage_tools = {}
      stage_runtime_tools = {}
      stage_budgets = {}

      allow(Dalembert::Agent).to receive(:new).and_wrap_original do |orig, **kwargs|
        agent = orig.call(**kwargs)
        stage_tools[kwargs[:name]] = agent.enabled_tools
        stage_runtime_tools[kwargs[:name]] = agent.instance_variable_get(:@tools)
        stage_budgets[kwargs[:name]] = kwargs[:max_turns]

        allow(agent).to receive(:execute) do |_ctx, _stage_prompt|
          "Stage #{kwargs[:name]} completed"
        end
        agent
      end

      session.handle_message(swe_bench_init_json)
      session.thread.join

      workflow = session.agent
      expect(workflow).to be_a(Dalembert::Workflows::SweBenchWorkflow)
      expect(workflow.model).to eq("hy4")
      expect(workflow.max_turns).to eq(45)
      expect(session.mode).to eq("swe_bench")
      expect(session.resolved_cloud_tools).to eq([])

      locate_names = workflow.phase_tools_for(:locate).map(&:tool_name)
      reproduce_names = workflow.phase_tools_for(:reproduce).map(&:tool_name)
      patch_names = workflow.phase_tools_for(:patch_and_verify).map(&:tool_name)

      expect(locate_names.size).to eq(6)
      expect(locate_names).to contain_exactly(
        "list_files", "read_file", "grep_search", "get_outline", "read_symbol", "get_status"
      )

      expect(reproduce_names.size).to eq(7)
      expect(reproduce_names).to contain_exactly(
        "list_files", "read_file", "grep_search", "get_outline", "read_symbol", "get_status", "run_verification"
      )

      expect(patch_names.size).to eq(11)
      expect(patch_names).to contain_exactly(
        "list_files", "read_file", "grep_search", "get_outline", "read_symbol", "get_status",
        "run_verification", "replace_symbol", "manage_imports", "write_file", "append_file"
      )

      # Verify cloud tools and ping/echo are absent across all 3 stages
      cloud_tool_names = Dalembert::Agent::ALL_CLOUD_TOOLS.map(&:tool_name)
      [locate_names, reproduce_names, patch_names].each do |names|
        expect(names).not_to include("ping", "echo", *cloud_tool_names)
      end

      # Verify stage agents mounted during execution had exact 6 -> 7 -> 11 tool counts
      expect(stage_tools[:swe_bench_locate].map(&:tool_name)).to match_array(locate_names)
      expect(stage_tools[:swe_bench_reproduce].map(&:tool_name)).to match_array(reproduce_names)
      expect(stage_tools[:swe_bench_patch_and_verify].map(&:tool_name)).to match_array(patch_names)
      %i[swe_bench_locate swe_bench_reproduce swe_bench_patch_and_verify].each do |stage_key|
        expect(stage_runtime_tools[stage_key].map(&:tool_name)).to include("send_message")
      end
      expect(stage_budgets[:swe_bench_locate]).to eq(14)
      expect(stage_budgets[:swe_bench_reproduce]).to eq(12)

      decoded = sent_frames.map { |f| decode_frame(f) }
      phase_events = decoded.select { |f| f[:type].to_s == "stream_event" && f[:event].to_s == "phase_change" }
      expect(phase_events.map { |f| f[:data].to_s }).to eq(%w[locate reproduce patch_and_verify])

      final_frame = decoded.last
      expect(final_frame[:type].to_s).to eq("finished")
      expect(final_frame[:status].to_s).to eq("ok")
      expect(final_frame[:result]).to eq("Stage swe_bench_patch_and_verify completed")
    end

    it "supports String-keyed init hashes and defaults cloud_tools to [] when omitted in swe_bench mode" do
      allow(Dalembert::Agent).to receive(:new).and_wrap_original do |orig, **kwargs|
        agent = orig.call(**kwargs)
        allow(agent).to receive(:execute) { "Done #{kwargs[:name]}" }
        agent
      end

      string_payload = {
        "type" => "init",
        "mode" => "swe_bench",
        "model" => "hy4",
        "prompt" => "Fix bug",
        "disabled_tools" => %w[ping echo],
        "tools" => engine_edge_tool_schemas
      }

      session.send(:handle_init, string_payload)
      session.thread.join

      expect(session.agent).to be_a(Dalembert::Workflows::SweBenchWorkflow)
      expect(session.agent.max_turns).to eq(45)
      expect(session.resolved_cloud_tools).to eq([])
      expect(session.agent.phase_tools_for(:patch_and_verify).size).to eq(11)
    end
  end

  describe "#handle_execute_tool authorization" do
    before do
      allow(Dalembert::Agent).to receive(:new).and_wrap_original do |orig, **kwargs|
        agent = orig.call(**kwargs)
        allow(agent).to receive(:execute) { "ok" }
        agent
      end

      session.handle_message(swe_bench_init_json)
      session.thread.join
      sent_frames.clear
    end

    it "rejects disabled tools (ping, echo)" do
      session.send(:handle_execute_tool, { call_id: "c1", tool_name: "ping", args: {} })
      session.send(:handle_execute_tool, { "call_id" => "c2", "tool_name" => "echo", "args" => {} })

      frames = sent_frames.map { |f| decode_frame(f) }
      expect(frames.size).to eq(2)
      expect(frames[0][:call_id]).to eq("c1")
      expect(frames[0][:output]).to eq("Error: Tool 'ping' is disabled for this session")
      expect(frames[1][:call_id]).to eq("c2")
      expect(frames[1][:output]).to eq("Error: Tool 'echo' is disabled for this session")
    end

    it "rejects excluded cloud tools including aliases when cloud_tools: []" do
      session.send(:handle_execute_tool, { call_id: "c3", tool_name: "search_code_examples", args: { query: "User" } })
      session.send(:handle_execute_tool, { call_id: "c4", tool_name: "doc_fetcher", args: { url: "https://example.com" } })
      session.send(:handle_execute_tool, { call_id: "c5", tool_name: "knowledge_store_tool", args: { action: "list_topics" } })

      frames = sent_frames.map { |f| decode_frame(f) }
      expect(frames.size).to eq(3)
      expect(frames[0][:output]).to eq("Error: Tool 'search_code_examples' is disabled for this session")
      expect(frames[1][:output]).to eq("Error: Tool 'doc_fetcher' is disabled for this session")
      expect(frames[2][:output]).to eq("Error: Tool 'knowledge_store_tool' is disabled for this session")
    end

    it "returns unknown tool error for unrecognized tool names" do
      session.send(:handle_execute_tool, { call_id: "c6", tool_name: "nonexistent_tool", args: {} })

      frame = decode_frame(sent_frames.last)
      expect(frame[:type].to_s).to eq("tool_result")
      expect(frame[:call_id]).to eq("c6")
      expect(frame[:output]).to eq("Error: Unknown tool 'nonexistent_tool'")
    end

    it "executes permitted cloud tools when allowed in cloud_tools using Descartes::Tool::Base context arity" do
      allowed_frames = []
      allowed_session = build_test_session(allowed_frames)

      allow(Dalembert::Agent).to receive(:new).and_wrap_original do |orig, **kwargs|
        agent = orig.call(**kwargs)
        allow(agent).to receive(:execute) { "ok" }
        agent
      end

      allowed_session.send(:handle_init, {
        type: "init",
        task_name: "doc_lookup_task",
        mode: "default",
        cloud_tools: ["doc_fetcher"],
        prompt: "hi"
      })
      allowed_session.thread.join
      allowed_frames.clear

      expect_any_instance_of(Dalembert::Tools::DocFetcher).to receive(:execute)
        .with({ "url" => "https://example.com/guide.md" })
        .and_return("Guide content")

      t = allowed_session.send(:handle_execute_tool, {
        call_id: "c7",
        tool_name: "doc_fetcher",
        args: { url: "https://example.com/guide.md" }
      })
      t.join if t.is_a?(Thread)

      frame = decode_frame(allowed_frames.last)
      expect(frame[:type].to_s).to eq("tool_result")
      expect(frame[:call_id]).to eq("c7")
      expect(frame[:output]).to eq("Guide content")
    end
  end

  describe "non-swe_bench mode routing" do
    it "instantiates Dalembert::Agent with ProfileResolver model selection and all 5 cloud tools when cloud_tools is omitted" do
      allow(Dalembert::Agent).to receive(:new).and_wrap_original do |orig, **kwargs|
        agent = orig.call(**kwargs)
        allow(agent).to receive(:execute) { "Agent answer" }
        agent
      end

      default_init_json = JSON.generate(
        type: "init",
        mode: "default",
        llm_profile: "default",
        model: "hy4",
        prompt: "Explain Descartes"
      )

      session.handle_message(default_init_json)
      session.thread.join

      expect(session.agent).to be_a(Dalembert::Agent)
      expect(session.agent.model).to eq("hy4")
      expect(session.resolved_cloud_tools).to eq(Dalembert::Agent::ALL_CLOUD_TOOLS)
      expect(session.agent.enabled_tools).to include(*Dalembert::Agent::ALL_CLOUD_TOOLS)

      final_frame = decode_frame(sent_frames.last)
      expect(final_frame[:type].to_s).to eq("finished")
      expect(final_frame[:result]).to eq("Agent answer")
    end
  end
end
