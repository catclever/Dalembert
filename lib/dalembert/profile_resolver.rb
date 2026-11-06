# frozen_string_literal: true

require "yaml"

=begin
================================================================================
Feature: Orthogonal Provider & Model Decoupling (ProfileResolver)
Task ID: multi_provider_model_selection_001

1. Problem / Feature Implemented:
   - Dalembert previously tied LLM channel configuration (base_url, format, api_key)
     directly to a static profile name in llm.yml, preventing users from dynamically
     selecting different models (e.g. deepseek-reasoner vs deepseek-chat, or gpt-4o-mini
     vs gpt-4o) under the same provider without duplicating YAML profile blocks.
   - In 12-factor cloud deployments (Docker, Railway), setting ENV["LLM_BASE_URL"]
     could accidentally override explicitly requested profiles (e.g., deepseek or openai),
     breaking multi-provider routing while still needing zero-config fallback.
   - ProfileResolver introduces orthogonal provider and model resolution (方案 B),
     supporting composite identifiers ("provider/model", "provider:model"), explicit
     model overrides, clean 12-factor zero-config fallbacks, and sanitized option
     hashes for RubyLLM::LLMService.new.

2. Method / Logic Used:
   - parse_identifier: Parses composite strings such as "deepseek/deepseek-reasoner"
     or "openai:gpt-4o-mini" into [provider, model], splitting only on the first
     delimiter (/ or :) to safely support model names with downstream slashes.
   - resolve:
     a) Detects whether a profile was explicitly requested or defaulted.
     b) Decouples channel settings (base_url, api_key, format) from model.
     c) Explicit model parameter has highest priority, followed by composite parsed
        model, followed by YAML configuration, followed by ENV["LLM_MODEL"].
     d) If an explicit profile is requested, ENV["LLM_BASE_URL"] is ignored to prevent
        route hijacking. If no profile is explicitly requested (fallback to default),
        ENV["LLM_BASE_URL"] is honored for 12-factor zero-config agility.
     e) Evaluates "ENV['VAR_NAME']" and "${VAR_NAME}" string references dynamically.
     f) Returns a sanitized Hash with symbolized keys ready for RubyLLM::LLMService.new(**options).

3. Caveats & Future Development Considerations:
   - When adding new providers to llm.yml, ensure format ("openai", "claude", etc.)
     matches RubyLLM expectations.
   - All returned keys are symbolized; ensure any callers unpacking with **kwargs
     rely on symbol keys.
================================================================================
=end

module Dalembert
  class ProfileResolver
    DEFAULT_PROFILE = "default"
    DEFAULT_FORMAT  = "openai"
    DEFAULT_MODEL   = "deepseek-chat"
    DEFAULT_TIMEOUT = 120
    DEFAULT_MAX_TOKENS = 8192

    class << self
      # Resolves the provider channel configuration and model orthogonally.
      #
      # @param profile_or_name [String, nil] Identifier or profile name (positional)
      # @param profile_name [String, nil] Identifier or profile name (keyword)
      # @param profile [String, nil] Alias for profile_name
      # @param model [String, nil] Explicit model override
      # @param config_path [String, nil] Optional path to llm.yml
      # @param config [Hash, nil] Optional pre-loaded config Hash
      # @param explicit [Boolean, nil] Explicit override flag (auto-detected if nil)
      # @return [Hash] Sanitized options hash for RubyLLM::LLMService.new
      def resolve(profile_or_name = nil, profile_name: nil, profile: nil, model: nil, config_path: nil, config: nil, explicit: nil)
        raw_identifier = profile_or_name || profile_name || profile
        parsed_provider, parsed_model = parse_identifier(raw_identifier)

        # Determine if profile was explicitly requested
        is_explicit = if !explicit.nil?
                        !!explicit
                      elsif raw_identifier.nil? || raw_identifier.to_s.strip.empty?
                        false
                      elsif raw_identifier.to_s.strip == DEFAULT_PROFILE && parsed_model.nil?
                        false
                      else
                        true
                      end

        provider = (parsed_provider && !parsed_provider.empty?) ? parsed_provider : DEFAULT_PROFILE

        # Load YAML configuration
        loaded_config = config || load_config(config_path)
        provider_section = fetch_provider_section(loaded_config, provider)

        # Decouple channel settings
        format = provider_section["format"] || provider_section[:format] || DEFAULT_FORMAT

        cfg_base_url = resolve_env_value(provider_section["base_url"] || provider_section[:base_url])
        base_url = if is_explicit
                     # Explicit profile: prevent ENV["LLM_BASE_URL"] from hijacking channel
                     cfg_base_url || resolve_env_value(ENV["#{provider.upcase}_BASE_URL"])
                   else
                     # Zero-config 12-factor fallback: ENV["LLM_BASE_URL"] takes precedence
                     ENV["LLM_BASE_URL"] || cfg_base_url
                   end

        cfg_api_key = resolve_env_value(provider_section["api_key"] || provider_section[:api_key])
        api_key = cfg_api_key ||
                  resolve_env_value(ENV["#{provider.upcase}_API_KEY"]) ||
                  (!is_explicit ? ENV["LLM_API_KEY"] : nil) ||
                  ENV["DEEPSEEK_API_KEY"]

        # Resolve Model: explicit param > parsed composite model > config > ENV["LLM_MODEL"] > default
        cfg_model = resolve_env_value(provider_section["model"] || provider_section[:model])
        effective_model = if model && !model.to_s.strip.empty?
                            model.to_s.strip
                          elsif parsed_model && !parsed_model.empty?
                            parsed_model
                          elsif cfg_model && !cfg_model.to_s.strip.empty?
                            cfg_model.to_s.strip
                          elsif !is_explicit && ENV["LLM_MODEL"] && !ENV["LLM_MODEL"].strip.empty?
                            ENV["LLM_MODEL"].strip
                          else
                            DEFAULT_MODEL
                          end

        max_tokens = (provider_section["max_tokens"] || provider_section[:max_tokens] || DEFAULT_MAX_TOKENS).to_i
        timeout    = (provider_section["timeout"] || provider_section[:timeout] || DEFAULT_TIMEOUT).to_i

        # Build sanitized options hash
        options = {
          profile_name: provider,
          format: format.to_s,
          base_url: base_url ? base_url.to_s : nil,
          model: effective_model.to_s,
          api_key: api_key ? api_key.to_s : nil,
          max_tokens: max_tokens,
          timeout: timeout
        }

        # Merge additional custom options from YAML provider section
        provider_section.each do |k, v|
          sym_k = k.to_sym
          next if options.key?(sym_k)

          options[sym_k] = resolve_env_value(v)
        end

        options
      end

      # Parses composite profile identifiers like "provider/model" or "provider:model".
      # Splits strictly on the first delimiter to support downstream model slashes.
      #
      # @param identifier [String, nil]
      # @return [Array<String, nil>] [provider, model]
      def parse_identifier(identifier)
        return [nil, nil] if identifier.nil?

        id_str = identifier.to_s.strip
        return [nil, nil] if id_str.empty?

        if id_str.include?("/") || id_str.include?(":")
          parts = id_str.split(%r{[/:]}, 2)
          provider = parts[0]&.strip
          model = parts[1]&.strip
          provider = nil if provider && provider.empty?
          model = nil if model && model.empty?
          [provider, model]
        else
          [id_str, nil]
        end
      end

      # Dynamically evaluates environment variable references in config strings.
      # Supports "ENV['NAME']", 'ENV["NAME"]', "${NAME}", and "$NAME".
      #
      # @param val [Object]
      # @return [Object]
      def resolve_env_value(val)
        return val unless val.is_a?(String)

        trimmed = val.strip
        if trimmed =~ /\AENV\[['"](.+?)['"]\]\z/
          ENV[$1]
        elsif trimmed =~ /\A\$\{?([A-Za-z0-9_]+)\}?\z/
          ENV[$1]
        else
          trimmed
        end
      end

      # Loads configuration file from given path or auto-discovers standard paths.
      #
      # @param custom_path [String, nil]
      # @return [Hash]
      def load_config(custom_path = nil)
        search_paths = [
          custom_path,
          ENV["LLM_CONFIG_PATH"],
          File.join(Dir.pwd, "llm.yml"),
          File.expand_path("../../llm.yml", __dir__),
          File.join(Dir.pwd, "llm.example.yml"),
          File.expand_path("../../llm.example.yml", __dir__)
        ].compact.uniq

        search_paths.each do |path|
          next unless File.file?(path)

          begin
            loaded = YAML.safe_load(File.read(path), permitted_classes: [], aliases: true)
            return loaded if loaded.is_a?(Hash)
          rescue StandardError
            next
          end
        end

        {}
      end

      private

      def fetch_provider_section(config_hash, provider_name)
        return {} unless config_hash.is_a?(Hash)

        config_hash[provider_name.to_s] ||
          config_hash[provider_name.to_sym] ||
          {}
      end
    end
  end
end
