# frozen_string_literal: true

require "rspec"
require "dalembert/profile_resolver"

=begin
================================================================================
Test Suite: ProfileResolver Specifications
Task ID: multi_provider_model_selection_001

1. Problem / Feature Tested:
   - Validates the orthogonal provider and model decoupling logic in Dalembert::ProfileResolver.
   - Tests composite identifier parsing ("provider/model", "provider:model").
   - Tests explicit `model:` parameter overriding default models in llm.yml.
   - Tests fallback to the "default" profile when none is provided.
   - Tests protection of explicit profiles against ENV["LLM_BASE_URL"] hijacking, while
     confirming 12-factor zero-config fallback when no profile is explicitly passed.
   - Verifies that sanitized options hashes with symbol keys are returned.

2. Method / Logic Used:
   - Sets up clean ENV states per test via around/before/after hooks.
   - Supplies custom mock YAML configurations to isolate tests from local filesystem state.
   - Exercises boundary cases (nested slashes, colon delimiters, missing env vars, zero-config).

3. Caveats & Future Development Considerations:
   - When new provider fields are introduced to llm.yml, add corresponding resolution specs.
================================================================================
=end

RSpec.describe Dalembert::ProfileResolver do
  let(:mock_config) do
    {
      "default" => {
        "format" => "openai",
        "base_url" => "https://api.deepseek.com/v1",
        "model" => "deepseek-chat",
        "api_key" => "ENV['DEEPSEEK_API_KEY']",
        "max_tokens" => 8192,
        "timeout" => 120
      },
      "deepseek" => {
        "format" => "openai",
        "base_url" => "https://api.deepseek.com/v1",
        "model" => "deepseek-chat",
        "api_key" => "ENV['DEEPSEEK_API_KEY']",
        "max_tokens" => 8192,
        "timeout" => 120
      },
      "openai" => {
        "format" => "openai",
        "base_url" => "https://api.openai.com/v1",
        "model" => "gpt-4o",
        "api_key" => "ENV['OPENAI_API_KEY']",
        "max_tokens" => 4096,
        "timeout" => 60
      },
      "kimi" => {
        "format" => "openai",
        "base_url" => "https://api.moonshot.cn/v1",
        "model" => "kimi-k2.6",
        "api_key" => "ENV['KIMI_API_KEY']",
        "max_tokens" => 8192,
        "timeout" => 120
      }
    }
  end

  let(:original_env) { ENV.to_h }

  before do
    ENV["DEEPSEEK_API_KEY"] = "sk-deepseek-mock"
    ENV["OPENAI_API_KEY"]   = "sk-openai-mock"
    ENV["KIMI_API_KEY"]     = "sk-kimi-mock"
    ENV.delete("LLM_BASE_URL")
    ENV.delete("LLM_MODEL")
    ENV.delete("LLM_API_KEY")
  end

  after do
    ENV.clear
    ENV.update(original_env)
  end

  describe ".parse_identifier" do
    it "parses slash-delimited composite identifiers" do
      provider, model = described_class.parse_identifier("deepseek/deepseek-reasoner")
      expect(provider).to eq("deepseek")
      expect(model).to eq("deepseek-reasoner")
    end

    it "parses colon-delimited composite identifiers" do
      provider, model = described_class.parse_identifier("openai:gpt-4o-mini")
      expect(provider).to eq("openai")
      expect(model).to eq("gpt-4o-mini")
    end

    it "parses simple provider identifiers with nil model" do
      provider, model = described_class.parse_identifier("deepseek")
      expect(provider).to eq("deepseek")
      expect(model).to be_nil
    end

    it "handles nil and empty strings safely" do
      expect(described_class.parse_identifier(nil)).to eq([nil, nil])
      expect(described_class.parse_identifier("")).to eq([nil, nil])
      expect(described_class.parse_identifier("   ")).to eq([nil, nil])
    end

    it "splits only on the first delimiter to preserve model paths with slashes" do
      provider, model = described_class.parse_identifier("openrouter/anthropic/claude-3-5-sonnet")
      expect(provider).to eq("openrouter")
      expect(model).to eq("anthropic/claude-3-5-sonnet")
    end
  end

  describe ".resolve" do
    context "with composite profile identifiers" do
      it "resolves provider channel settings while extracting the model" do
        res = described_class.resolve("deepseek/deepseek-reasoner", config: mock_config)

        expect(res[:profile_name]).to eq("deepseek")
        expect(res[:model]).to eq("deepseek-reasoner")
        expect(res[:base_url]).to eq("https://api.deepseek.com/v1")
        expect(res[:format]).to eq("openai")
        expect(res[:api_key]).to eq("sk-deepseek-mock")
        expect(res[:max_tokens]).to eq(8192)
        expect(res[:timeout]).to eq(120)
      end

      it "resolves colon composite identifiers like 'openai:gpt-4o-mini'" do
        res = described_class.resolve("openai:gpt-4o-mini", config: mock_config)

        expect(res[:profile_name]).to eq("openai")
        expect(res[:model]).to eq("gpt-4o-mini")
        expect(res[:base_url]).to eq("https://api.openai.com/v1")
        expect(res[:api_key]).to eq("sk-openai-mock")
        expect(res[:max_tokens]).to eq(4096)
      end
    end

    context "with explicit model: parameter override" do
      it "overrides default model in llm.yml for the specified provider" do
        res = described_class.resolve("deepseek", model: "deepseek-reasoner", config: mock_config)

        expect(res[:profile_name]).to eq("deepseek")
        expect(res[:model]).to eq("deepseek-reasoner")
        expect(res[:base_url]).to eq("https://api.deepseek.com/v1")
      end

      it "takes precedence over model specified in composite string" do
        res = described_class.resolve("deepseek/deepseek-chat", model: "deepseek-reasoner", config: mock_config)

        expect(res[:profile_name]).to eq("deepseek")
        expect(res[:model]).to eq("deepseek-reasoner")
      end
    end

    context "with fallback to default profile" do
      it "falls back to default profile when profile is nil" do
        res = described_class.resolve(nil, config: mock_config)

        expect(res[:profile_name]).to eq("default")
        expect(res[:model]).to eq("deepseek-chat")
        expect(res[:base_url]).to eq("https://api.deepseek.com/v1")
      end

      it "falls back to default profile when profile is empty" do
        res = described_class.resolve("", config: mock_config)

        expect(res[:profile_name]).to eq("default")
        expect(res[:model]).to eq("deepseek-chat")
      end

      it "allows overriding model on default profile fallback" do
        res = described_class.resolve(nil, model: "custom-default-model", config: mock_config)

        expect(res[:profile_name]).to eq("default")
        expect(res[:model]).to eq("custom-default-model")
      end
    end

    context "with ENV['LLM_BASE_URL'] protection and 12-factor zero-config" do
      before do
        ENV["LLM_BASE_URL"] = "http://internal-proxy:8080/v1"
      end

      it "prevents ENV['LLM_BASE_URL'] from hijacking explicitly requested profiles" do
        res_deepseek = described_class.resolve("deepseek", config: mock_config)
        expect(res_deepseek[:base_url]).to eq("https://api.deepseek.com/v1")

        res_composite = described_class.resolve("deepseek/deepseek-reasoner", config: mock_config)
        expect(res_composite[:base_url]).to eq("https://api.deepseek.com/v1")

        res_openai = described_class.resolve("openai", config: mock_config)
        expect(res_openai[:base_url]).to eq("https://api.openai.com/v1")
      end

      it "allows ENV['LLM_BASE_URL'] to apply when no profile is explicitly specified (zero-config)" do
        res_fallback = described_class.resolve(nil, config: mock_config)
        expect(res_fallback[:base_url]).to eq("http://internal-proxy:8080/v1")

        res_default = described_class.resolve("default", config: mock_config)
        expect(res_default[:base_url]).to eq("http://internal-proxy:8080/v1")
      end
    end

    context "with environment variable resolution in YAML" do
      it "resolves ENV['VAR_NAME'] patterns" do
        expect(described_class.resolve_env_value("ENV['DEEPSEEK_API_KEY']")).to eq("sk-deepseek-mock")
        expect(described_class.resolve_env_value('ENV["OPENAI_API_KEY"]')).to eq("sk-openai-mock")
      end

      it "resolves ${VAR_NAME} and $VAR_NAME patterns" do
        expect(described_class.resolve_env_value("${DEEPSEEK_API_KEY}")).to eq("sk-deepseek-mock")
        expect(described_class.resolve_env_value("$OPENAI_API_KEY")).to eq("sk-openai-mock")
      end

      it "returns literal strings untouched" do
        expect(described_class.resolve_env_value("sk-plain-key-12345")).to eq("sk-plain-key-12345")
      end
    end

    context "sanitized options hash output" do
      it "returns all keys as Symbols suitable for RubyLLM::LLMService.new(**options)" do
        res = described_class.resolve("kimi", config: mock_config)

        res.each_key do |key|
          expect(key).to be_a(Symbol)
        end
        expect(res[:max_tokens]).to be_a(Integer)
        expect(res[:timeout]).to be_a(Integer)
        expect(res).to include(:profile_name, :format, :base_url, :model, :api_key, :max_tokens, :timeout)
      end
    end
  end
end
