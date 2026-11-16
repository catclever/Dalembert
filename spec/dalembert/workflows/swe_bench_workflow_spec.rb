# frozen_string_literal: true

require "rspec"

=begin
================================================================================
Test Suite: 3-Stage SWE-bench State Machine Workflow Specifications
Task ID: dynamic_tool_masking_and_swe_bench_workflow_003

1. Problem / Feature Tested:
   - Validates `Dalembert::Workflows::SweBenchWorkflow.classify_tool` across all
     four capability buckets (`:cloud_osint`, `:write_local`, `:exec_sandbox`, `:read_local`).
   - Validates `phase_tools_for(:locate | :reproduce | :patch_and_verify)` enforcing
     strict stage-level tool boundaries and SWE-bench temporal leakage prevention.
   - Validates `execute(context, prompt)` sequential 3-stage execution, event
     forwarding (`:thought`, `:tool_call_start`, `:tool_call_end`, `:phase_change`),
     context persistence (`:localization_report`, `:reproduction_report`, `:patch_report`),
     and early halting on `"Error: ..."` responses.

2. Method / Logic Used:
   - Defines lightweight `Descartes::Tool::Base` subclasses representing read,
     exec, and write local edge tools.
   - Stubs `Dalembert::Agent` stage execution to verify stage ordering, prompt
     propagation, event emission (`emit(event, data)`), and error short-circuiting.

3. Caveats & Future Development Considerations:
   - `Descartes::EventEmitter#emit(event, data = nil)` takes 1 or 2 arguments (`event`
     and a single `data` payload hash).
================================================================================
=end

=begin
================================================================================
Test Suite: Segmented Turn Quota, Unused-Turn Rollover & Auto-Handoff Specs
Task ID: hub_session_swe_bench_routing_and_budget_005

1. Problem / Feature Tested:
   - Validates `append_file` and `manage_imports` classification as `:write_local`
     (masked in Stage 1 & 2, unlocked in Stage 3).
   - Validates `DEFAULT_MAX_TURNS == 45` and Option A segmented turn budgeting
     (`14` -> `12` -> rollover remainder) across `build_stage_agent` and `execute`.
   - Validates turn tracking via `agent.llm.call_with_system` and fallback via
     `tool_turns` / `MAX_TURNS_EXCEEDED_PREFIX`.
   - Validates graceful auto-handoff on `MAX_TURNS_EXCEEDED_PREFIX` vs immediate
     short-circuiting on all other `"Error: ..."` responses.
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

require "dalembert/profile_resolver"
require "dalembert/agent"
require "dalembert/workflows/swe_bench_workflow"

RSpec.describe Dalembert::Workflows::SweBenchWorkflow do
  def build_tool_class(tool_name_str)
    Class.new(Descartes::Tool::Base) do
      name tool_name_str
      description "Mock tool #{tool_name_str}"
    end
  end

  let(:read_file_tool)      { build_tool_class("read_file") }
  let(:grep_tool)           { build_tool_class("ripgrep") }
  let(:outline_tool)        { build_tool_class("get_outline") }
  let(:bash_tool)           { build_tool_class("bash") }
  let(:run_test_tool)       { build_tool_class("run_test") }
  let(:pytest_tool)         { build_tool_class("pytest") }
  let(:write_file_tool)     { build_tool_class("write_file") }
  let(:append_file_tool)    { build_tool_class("append_file") }
  let(:edit_file_tool)      { build_tool_class("edit_file") }
  let(:manage_imports_tool) { build_tool_class("manage_imports") }
  let(:apply_patch_tool)    { build_tool_class("apply_patch") }
  let(:ast_replace_tool)    { build_tool_class("ast_replace") }

  let(:all_local_tools) do
    [
      read_file_tool,
      grep_tool,
      outline_tool,
      bash_tool,
      run_test_tool,
      pytest_tool,
      write_file_tool,
      append_file_tool,
      edit_file_tool,
      manage_imports_tool,
      apply_patch_tool,
      ast_replace_tool
    ]
  end

  describe ".classify_tool" do
    it "classifies Dalembert::Tools::* classes as :cloud_osint" do
      expect(described_class.classify_tool(Dalembert::Tools::GithubRepoSurvey)).to eq(:cloud_osint)
      expect(described_class.classify_tool(Dalembert::Tools::GithubCodeSearch)).to eq(:cloud_osint)
      expect(described_class.classify_tool(Dalembert::Tools::DocFetcher)).to eq(:cloud_osint)
      expect(described_class.classify_tool(Dalembert::Tools::SpecInspector)).to eq(:cloud_osint)
      expect(described_class.classify_tool(Dalembert::Tools::KnowledgeStoreTool)).to eq(:cloud_osint)
    end

    it "classifies file mutation tools (including append_file and manage_imports) as :write_local" do
      expect(described_class.classify_tool(write_file_tool)).to eq(:write_local)
      expect(described_class.classify_tool(append_file_tool)).to eq(:write_local)
      expect(described_class.classify_tool(edit_file_tool)).to eq(:write_local)
      expect(described_class.classify_tool(manage_imports_tool)).to eq(:write_local)
      expect(described_class.classify_tool(apply_patch_tool)).to eq(:write_local)
      expect(described_class.classify_tool(ast_replace_tool)).to eq(:write_local)
      expect(described_class.classify_tool(build_tool_class("replace_file_content"))).to eq(:write_local)
      expect(described_class.classify_tool(build_tool_class("delete_file"))).to eq(:write_local)
      expect(described_class.classify_tool(build_tool_class("str_replace_editor"))).to eq(:write_local)
    end

    it "classifies command and test execution tools as :exec_sandbox" do
      expect(described_class.classify_tool(bash_tool)).to eq(:exec_sandbox)
      expect(described_class.classify_tool(run_test_tool)).to eq(:exec_sandbox)
      expect(described_class.classify_tool(pytest_tool)).to eq(:exec_sandbox)
      expect(described_class.classify_tool(build_tool_class("execute_command"))).to eq(:exec_sandbox)
      expect(described_class.classify_tool(build_tool_class("rspec"))).to eq(:exec_sandbox)
      expect(described_class.classify_tool(build_tool_class("cargo_test"))).to eq(:exec_sandbox)
    end

    it "classifies inspection and search tools as :read_local" do
      expect(described_class.classify_tool(read_file_tool)).to eq(:read_local)
      expect(described_class.classify_tool(grep_tool)).to eq(:read_local)
      expect(described_class.classify_tool(outline_tool)).to eq(:read_local)
      expect(described_class.classify_tool(build_tool_class("list_dir"))).to eq(:read_local)
      expect(described_class.classify_tool(build_tool_class("find_by_name"))).to eq(:read_local)
      expect(described_class.classify_tool(build_tool_class("view_file"))).to eq(:read_local)
    end
  end

  describe "#initialize" do
    it "defaults max_turns to DEFAULT_MAX_TURNS (45)" do
      workflow = described_class.new(tools: all_local_tools)
      expect(described_class::DEFAULT_MAX_TURNS).to eq(45)
      expect(workflow.max_turns).to eq(45)
    end
  end

  describe "#phase_tools_for" do
    let(:workflow) do
      described_class.new(
        profile_name: "deepseek/deepseek-reasoner",
        tools: all_local_tools
      )
    end

    it "restricts Stage 1 (:locate) strictly to :read_local tools and non-GitHub cloud tools" do
      locate_tools = workflow.phase_tools_for(:locate)

      expect(locate_tools).to include(read_file_tool, grep_tool, outline_tool)
      expect(locate_tools).to include(
        Dalembert::Tools::DocFetcher,
        Dalembert::Tools::SpecInspector,
        Dalembert::Tools::KnowledgeStoreTool
      )
      expect(locate_tools).not_to include(
        bash_tool,
        run_test_tool,
        pytest_tool,
        write_file_tool,
        append_file_tool,
        edit_file_tool,
        manage_imports_tool,
        apply_patch_tool,
        ast_replace_tool,
        Dalembert::Tools::GithubRepoSurvey,
        Dalembert::Tools::GithubCodeSearch
      )
    end

    it "restricts Stage 2 (:reproduce) to :read_local + :exec_sandbox + resolved cloud tools (no :write_local)" do
      reproduce_tools = workflow.phase_tools_for(:reproduce)

      expect(reproduce_tools).to include(
        read_file_tool,
        grep_tool,
        outline_tool,
        bash_tool,
        run_test_tool,
        pytest_tool,
        Dalembert::Tools::DocFetcher
      )
      expect(reproduce_tools).not_to include(
        write_file_tool,
        append_file_tool,
        edit_file_tool,
        manage_imports_tool,
        apply_patch_tool,
        ast_replace_tool,
        Dalembert::Tools::GithubRepoSurvey,
        Dalembert::Tools::GithubCodeSearch
      )
    end

    it "grants Stage 3 (:patch_and_verify) :read_local + :write_local + :exec_sandbox + resolved cloud tools" do
      patch_tools = workflow.phase_tools_for(:patch_and_verify)

      expect(patch_tools).to include(
        read_file_tool,
        grep_tool,
        outline_tool,
        bash_tool,
        run_test_tool,
        pytest_tool,
        write_file_tool,
        append_file_tool,
        edit_file_tool,
        manage_imports_tool,
        apply_patch_tool,
        ast_replace_tool,
        Dalembert::Tools::DocFetcher
      )
      expect(patch_tools).not_to include(
        Dalembert::Tools::GithubRepoSurvey,
        Dalembert::Tools::GithubCodeSearch
      )
    end

    it "respects cloud_tools: [] and disabled_tools across all stages" do
      strict_workflow = described_class.new(
        tools: all_local_tools,
        cloud_tools: [],
        disabled_tools: ["pytest", "ast_replace"]
      )

      expect(strict_workflow.phase_tools_for(:locate)).to contain_exactly(
        read_file_tool,
        grep_tool,
        outline_tool
      )
      expect(strict_workflow.phase_tools_for(:reproduce)).to contain_exactly(
        read_file_tool,
        grep_tool,
        outline_tool,
        bash_tool,
        run_test_tool
      )
      expect(strict_workflow.phase_tools_for(:patch_and_verify)).to contain_exactly(
        read_file_tool,
        grep_tool,
        outline_tool,
        bash_tool,
        run_test_tool,
        write_file_tool,
        append_file_tool,
        edit_file_tool,
        manage_imports_tool,
        apply_patch_tool
      )
    end

    it "raises ArgumentError for an unknown stage" do
      expect { workflow.phase_tools_for(:unknown_stage) }.to raise_error(ArgumentError, /Unknown SWE-bench workflow stage/)
    end
  end

  describe "#execute" do
    let(:context) do
      store = {}
      ctx = double("Descartes::Context")
      allow(ctx).to receive(:set) { |k, v| store[k] = v }
      allow(ctx).to receive(:get) { |k| store[k] }
      allow(ctx).to receive(:store).and_return(store)
      ctx
    end

    let(:workflow) do
      described_class.new(
        profile_name: "deepseek/deepseek-reasoner",
        tools: all_local_tools,
        cloud_tools: []
      )
    end

    it "executes all 3 stages sequentially, forwards events, and stores stage reports in context" do
      thoughts = []
      phases = []
      tool_starts = []
      tool_ends = []

      workflow.on(:thought) { |msg| thoughts << msg }
      workflow.on(:phase_change) { |phase| phases << phase }
      workflow.on(:tool_call_start) { |payload| tool_starts << payload }
      workflow.on(:tool_call_end) { |payload| tool_ends << payload }

      stage_prompts = {}
      stage_tools_snapshot = {}

      allow(Dalembert::Agent).to receive(:new).and_wrap_original { |orig, **kwargs|
        agent = orig.call(**kwargs)
        stage_name = kwargs[:name]
        stage_tools_snapshot[stage_name] = agent.enabled_tools

        allow(agent).to receive(:execute) do |_ctx, stage_prompt|
          stage_prompts[stage_name] = stage_prompt
          case stage_name
          when :swe_bench_locate
            agent.send(:emit, :thought, "Inspecting AST...") if agent.respond_to?(:emit, true)
            agent.send(:emit, :tool_call_start, { tool: "read_file", args: { "path" => "app.py" } }) if agent.respond_to?(:emit, true)
            agent.send(:emit, :tool_call_end, { tool: "read_file", result: "def bug(): pass" }) if agent.respond_to?(:emit, true)
            "Suspect file: app.py:10-20, off-by-one error"
          when :swe_bench_reproduce
            "Red Light confirmed: pytest test_app.py failed with AssertionError"
          when :swe_bench_patch_and_verify
            "Green Light confirmed: applied minimal patch to app.py and all 42 tests pass"
          end
        end

        agent
      }

      final_result = workflow.execute(context, "Fix off-by-one IndexError in app.py")

      expect(final_result).to eq("Green Light confirmed: applied minimal patch to app.py and all 42 tests pass")
      expect(phases).to eq(%i[locate reproduce patch_and_verify])
      expect(thoughts.join).to include("Phase 1/3 [:locate]")
      expect(thoughts.join).to include("Phase 2/3 [:reproduce]")
      expect(thoughts.join).to include("Phase 3/3 [:patch_and_verify]")
      expect(thoughts).to include("Inspecting AST...")
      expect(tool_starts).to eq([{ tool: "read_file", args: { "path" => "app.py" } }])
      expect(tool_ends).to eq([{ tool: "read_file", result: "def bug(): pass" }])

      expect(context.get(:localization_report)).to eq("Suspect file: app.py:10-20, off-by-one error")
      expect(context.get(:reproduction_report)).to eq("Red Light confirmed: pytest test_app.py failed with AssertionError")
      expect(context.get(:patch_report)).to eq("Green Light confirmed: applied minimal patch to app.py and all 42 tests pass")

      expect(stage_prompts[:swe_bench_reproduce]).to include("Suspect file: app.py:10-20, off-by-one error")
      expect(stage_prompts[:swe_bench_patch_and_verify]).to include("Suspect file: app.py:10-20, off-by-one error")
      expect(stage_prompts[:swe_bench_patch_and_verify]).to include("Red Light confirmed: pytest test_app.py failed with AssertionError")

      expect(stage_tools_snapshot[:swe_bench_locate]).not_to include(write_file_tool, append_file_tool, manage_imports_tool, bash_tool)
      expect(stage_tools_snapshot[:swe_bench_reproduce]).to include(bash_tool)
      expect(stage_tools_snapshot[:swe_bench_reproduce]).not_to include(write_file_tool, append_file_tool, manage_imports_tool)
      expect(stage_tools_snapshot[:swe_bench_patch_and_verify]).to include(write_file_tool, append_file_tool, manage_imports_tool, bash_tool)
    end

    it "allocates segmented turn quotas (6 -> 5 -> rollover) and rolls unused turns into Stage 3" do
      stage_budgets = {}
      stage_system_prompts = {}

      allow(Dalembert::Agent).to receive(:new).and_wrap_original { |orig, **kwargs|
        agent = orig.call(**kwargs)
        stage_name = kwargs[:name]
        stage_budgets[stage_name] = kwargs[:max_turns]
        stage_system_prompts[stage_name] = kwargs[:system_prompt]

        allow(agent).to receive(:execute) do |_ctx, _stage_prompt|
          case stage_name
          when :swe_bench_locate
            3.times { |i| agent.send(:emit, :tool_call_start, { tool: "read_file", args: { "step" => i } }) }
            "Localized root cause in 3 turns"
          when :swe_bench_reproduce
            2.times { |i| agent.send(:emit, :tool_call_start, { tool: "bash", args: { "step" => i } }) }
            "Reproduced failure in 2 turns"
          when :swe_bench_patch_and_verify
            "Patched and verified"
          end
        end

        agent
      }

      result = workflow.execute(context, "Fix bug with rollover")

      expect(result).to eq("Patched and verified")
      expect(stage_budgets[:swe_bench_locate]).to eq(6)
      expect(stage_budgets[:swe_bench_reproduce]).to eq(5)
      expect(stage_budgets[:swe_bench_patch_and_verify]).to eq(40)

      expect(stage_system_prompts[:swe_bench_locate]).to include("Stage turn budget: up to 6 turns. Call 'send_message'")
      expect(stage_system_prompts[:swe_bench_reproduce]).to include("Stage turn budget: up to 5 turns. Call 'send_message'")
      expect(stage_system_prompts[:swe_bench_patch_and_verify]).to include("Stage turn budget: up to 40 turns. Call 'send_message'")
    end

    it "tracks actual LLM invocations via call_with_system wrapping and forwards args cleanly" do
      stage_budgets = {}
      forwarded_calls = []

      allow(Dalembert::Agent).to receive(:new).and_wrap_original { |orig, **kwargs|
        agent = orig.call(**kwargs)
        stage_name = kwargs[:name]
        stage_budgets[stage_name] = kwargs[:max_turns]

        llm = agent.llm
        allow(llm).to receive(:call_with_system) do |sys, msgs, **opts|
          forwarded_calls << [stage_name, sys, msgs, opts]
          "llm_ok"
        end

        allow(agent).to receive(:execute) do |_ctx, _stage_prompt|
          case stage_name
          when :swe_bench_locate
            # 3 LLM invocations, even with 5 tool calls emitted inside them
            3.times { llm.call_with_system("sys", ["msg"], tools: []) }
            5.times { |i| agent.send(:emit, :tool_call_start, { tool: "read_file", args: { "i" => i } }) }
            "Locate complete"
          when :swe_bench_reproduce
            2.times { llm.call_with_system("sys", ["msg"]) }
            4.times { |i| agent.send(:emit, :tool_call_start, { tool: "bash", args: { "i" => i } }) }
            "Reproduce complete"
          when :swe_bench_patch_and_verify
            "Patch complete"
          end
        end

        agent
      }

      result = workflow.execute(context, "Fix bug via llm_calls")
      expect(result).to eq("Patch complete")
      expect(stage_budgets).to eq(
        swe_bench_locate: 6,
        swe_bench_reproduce: 5,
        swe_bench_patch_and_verify: 40
      )
      expect(forwarded_calls.size).to eq(5)
      expect(forwarded_calls.first[3]).to eq(tools: [])
      expect(forwarded_calls.last[3]).to eq({})
    end

    it "advances gracefully with auto-handoff when Stage 1 exceeds its sub-stage turn cap" do
      stage_budgets = {}
      stage_prompts = {}

      allow(Dalembert::Agent).to receive(:new).and_wrap_original { |orig, **kwargs|
        agent = orig.call(**kwargs)
        stage_name = kwargs[:name]
        stage_budgets[stage_name] = kwargs[:max_turns]

        allow(agent).to receive(:execute) do |_ctx, stage_prompt|
          stage_prompts[stage_name] = stage_prompt
          case stage_name
          when :swe_bench_locate
            agent.send(:emit, :thought, "Found validator regex in django/contrib/auth/validators.py")
            agent.send(:emit, :tool_call_start, { tool: "read_file", args: { "path" => "validators.py" } })
            agent.send(:emit, :tool_call_end, { tool: "read_file", result: "regex = r'^[\\w.@+-]+$'" })
            "Error: Agent exceeded maximum allowed reasoning turns."
          when :swe_bench_reproduce
            "Red Light confirmed from auto-handoff"
          when :swe_bench_patch_and_verify
            "Green Light confirmed"
          end
        end

        agent
      }

      res = workflow.execute(context, "Fix regex bug")
      expect(res).to eq("Green Light confirmed")
      expect(stage_budgets).to eq(
        swe_bench_locate: 6,
        swe_bench_reproduce: 5,
        swe_bench_patch_and_verify: 38
      )
      handoff = context.get(:localization_report)
      expect(handoff).to start_with("[Stage :locate auto-handoff after 6 turn limit]\n")
      expect(handoff).to include("Found validator regex in django/contrib/auth/validators.py")
      expect(handoff).to include("validators.py")
      expect(stage_prompts[:swe_bench_reproduce]).to include("[Stage :locate auto-handoff after 6 turn limit]")
    end

    it "advances gracefully with auto-handoff when Stage 2 exceeds its sub-stage turn cap" do
      stage_budgets = {}

      allow(Dalembert::Agent).to receive(:new).and_wrap_original { |orig, **kwargs|
        agent = orig.call(**kwargs)
        stage_name = kwargs[:name]
        stage_budgets[stage_name] = kwargs[:max_turns]

        allow(agent).to receive(:execute) do |_ctx, _stage_prompt|
          case stage_name
          when :swe_bench_locate
            "Localized to validators.py"
          when :swe_bench_reproduce
            agent.send(:emit, :tool_call_start, { tool: "run_test", args: { "cmd" => "pytest" } })
            agent.send(:emit, :tool_call_end, { tool: "run_test", result: "FAILED test_trailing_newline" })
            "Error: Agent exceeded maximum allowed reasoning turns."
          when :swe_bench_patch_and_verify
            "Green Light confirmed after Stage 2 auto-handoff"
          end
        end

        agent
      }

      res = workflow.execute(context, "Fix regex bug")
      expect(res).to eq("Green Light confirmed after Stage 2 auto-handoff")
      expect(stage_budgets).to eq(
        swe_bench_locate: 6,
        swe_bench_reproduce: 5,
        swe_bench_patch_and_verify: 39
      )
      handoff2 = context.get(:reproduction_report)
      expect(handoff2).to start_with("[Stage :reproduce auto-handoff after 5 turn limit]\n")
      expect(handoff2).to include("FAILED test_trailing_newline")
    end

    it "halts immediately if Stage 1 (:locate) returns an Error response" do
      stages_called = []

      allow(Dalembert::Agent).to receive(:new).and_wrap_original { |orig, **kwargs|
        agent = orig.call(**kwargs)
        allow(agent).to receive(:execute) do
          stages_called << kwargs[:name]
          "Error: LLM timeout during localization"
        end
        agent
      }

      res = workflow.execute(context, "Fix bug")
      expect(res).to eq("Error: LLM timeout during localization")
      expect(stages_called).to eq([:swe_bench_locate])
      expect(context.get(:localization_report)).to eq("Error: LLM timeout during localization")
      expect(context.get(:reproduction_report)).to be_nil
      expect(context.get(:patch_report)).to be_nil
    end

    it "halts immediately if Stage 2 (:reproduce) returns an Error response" do
      stages_called = []

      allow(Dalembert::Agent).to receive(:new).and_wrap_original { |orig, **kwargs|
        agent = orig.call(**kwargs)
        allow(agent).to receive(:execute) do
          stages_called << kwargs[:name]
          if kwargs[:name] == :swe_bench_locate
            "Localized to parser.rb:45"
          else
            "Error: Sandbox container disconnected"
          end
        end
        agent
      }

      res = workflow.execute(context, "Fix parser bug")
      expect(res).to eq("Error: Sandbox container disconnected")
      expect(stages_called).to eq(%i[swe_bench_locate swe_bench_reproduce])
      expect(context.get(:localization_report)).to eq("Localized to parser.rb:45")
      expect(context.get(:reproduction_report)).to eq("Error: Sandbox container disconnected")
      expect(context.get(:patch_report)).to be_nil
    end

    it "unwraps send_message confirmation strings to preserve real stage reports across stages" do
      stage_prompts = {}

      allow(Dalembert::Agent).to receive(:new).and_wrap_original { |orig, **kwargs|
        agent = orig.call(**kwargs)
        stage_name = kwargs[:name]

        allow(agent).to receive(:execute) do |ctx, stage_prompt|
          stage_prompts[stage_name] = stage_prompt
          case stage_name
          when :swe_bench_locate
            ctx.set(:localization_report, "Real Stage 1 localization report")
            "Successfully saved output to context key 'localization_report'"
          when :swe_bench_reproduce
            ctx.set(:reproduction_report, "Real Stage 2 reproduction report")
            "Successfully saved output to context key 'reproduction_report'"
          when :swe_bench_patch_and_verify
            ctx.set(:patch_report, "Real Stage 3 patch report")
            "Successfully saved output to context key 'patch_report'"
          end
        end

        agent
      }

      res = workflow.execute(context, "Fix validator trailing newline")
      expect(res).to eq("Real Stage 3 patch report")
      expect(context.get(:localization_report)).to eq("Real Stage 1 localization report")
      expect(context.get(:reproduction_report)).to eq("Real Stage 2 reproduction report")
      expect(context.get(:patch_report)).to eq("Real Stage 3 patch report")
      expect(stage_prompts[:swe_bench_reproduce]).to include("Real Stage 1 localization report")
      expect(stage_prompts[:swe_bench_reproduce]).not_to include("Successfully saved output to context key")
      expect(stage_prompts[:swe_bench_patch_and_verify]).to include("Real Stage 2 reproduction report")
    end
  end
end
