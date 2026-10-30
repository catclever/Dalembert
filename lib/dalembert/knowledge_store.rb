# frozen_string_literal: true

require "fileutils"
require "net/http"
require "json"
require "uri"
require "base64"

module Dalembert
  class KnowledgeStore
    DEFAULT_VAULT_PATH = "./knowledge_vault"
    DEFAULT_BRANCH = "main"

    attr_reader :vault_path

    def initialize(vault_path = DEFAULT_VAULT_PATH, token: nil, repo: nil, branch: nil)
      @vault_path = vault_path || DEFAULT_VAULT_PATH
      @token = token
      @repo = repo
      @branch = branch

      FileUtils.mkdir_p(@vault_path) unless github_mode?
    end

    def token
      @token || ENV["GITHUB_TOKEN"]
    end

    def repo
      @repo || ENV["KNOWLEDGE_REPO"]
    end

    def branch
      @branch || (ENV["KNOWLEDGE_BRANCH"].to_s.strip.empty? ? DEFAULT_BRANCH : ENV["KNOWLEDGE_BRANCH"].to_s.strip)
    end

    def github_mode?
      !(token.to_s.strip.empty? || repo.to_s.strip.empty?)
    end

    def store(topic, content)
      if github_mode?
        github_store(topic, content)
      else
        local_store(topic, content)
      end
    end

    def retrieve(topic)
      if github_mode?
        github_retrieve(topic)
      else
        local_retrieve(topic)
      end
    end

    def list_topics
      if github_mode?
        github_list_topics
      else
        local_list_topics
      end
    end

    private

    def sanitize_topic(topic)
      topic.to_s.gsub(/[^0-9A-Za-z.\-]/, "_")
    end

    def local_store(topic, content)
      FileUtils.mkdir_p(@vault_path)
      safe_topic = sanitize_topic(topic)
      file_path = File.join(@vault_path, "#{safe_topic}.md")

      File.write(file_path, content.to_s)
      "Stored knowledge in #{file_path}"
    end

    def local_retrieve(topic)
      safe_topic = sanitize_topic(topic)
      file_path = File.join(@vault_path, "#{safe_topic}.md")

      return nil unless File.exist?(file_path)

      File.read(file_path)
    end

    def local_list_topics
      return [] unless Dir.exist?(@vault_path)

      Dir.glob(File.join(@vault_path, "*.md")).map do |file|
        File.basename(file, ".md")
      end
    end

    def contents_uri(path = "")
      clean_repo = repo.to_s.strip.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
      clean_path = path.to_s.sub(%r{\A/+}, "")
      url = "https://api.github.com/repos/#{clean_repo}/contents"
      url += "/#{clean_path}" unless clean_path.empty?
      URI(url)
    end

    def execute_request(req, uri = nil)
      target_uri = uri || req.uri
      req["User-Agent"] = "Dalembert-Agent"
      req["Authorization"] = "Bearer #{token}"
      req["Accept"] = "application/vnd.github.v3+json"

      Net::HTTP.start(target_uri.hostname, target_uri.port, use_ssl: target_uri.scheme == "https") do |http|
        http.request(req)
      end
    end

    def fetch_file_sha(path)
      uri = contents_uri(path)
      uri.query = URI.encode_www_form(ref: branch)
      req = Net::HTTP::Get.new(uri)
      res = execute_request(req, uri)

      if res.is_a?(Net::HTTPSuccess)
        data = JSON.parse(res.body)
        data["sha"]
      else
        nil
      end
    rescue StandardError
      nil
    end

    def github_store(topic, content)
      safe_topic = sanitize_topic(topic)
      path = "#{safe_topic}.md"
      existing_sha = fetch_file_sha(path)

      uri = contents_uri(path)
      req = Net::HTTP::Put.new(uri)
      req["Content-Type"] = "application/json"

      payload = {
        "message" => (existing_sha ? "Update #{path} via Dalembert" : "Create #{path} via Dalembert"),
        "content" => Base64.strict_encode64(content.to_s),
        "branch" => branch
      }
      payload["sha"] = existing_sha if existing_sha

      req.body = JSON.generate(payload)
      res = execute_request(req, uri)

      if res.is_a?(Net::HTTPSuccess)
        "Stored knowledge in #{repo}/#{path}"
      else
        "Error storing knowledge to GitHub: #{res.code} #{res.message}"
      end
    end

    def github_retrieve(topic)
      safe_topic = sanitize_topic(topic)
      path = "#{safe_topic}.md"

      uri = contents_uri(path)
      uri.query = URI.encode_www_form(ref: branch)
      req = Net::HTTP::Get.new(uri)
      res = execute_request(req, uri)

      return nil if res.code.to_s == "404"
      return nil unless res.is_a?(Net::HTTPSuccess)

      data = JSON.parse(res.body)
      return nil unless data.is_a?(Hash) && data["content"]

      Base64.decode64(data["content"]).force_encoding("UTF-8")
    rescue StandardError
      nil
    end

    def github_list_topics
      uri = contents_uri("")
      uri.query = URI.encode_www_form(ref: branch)
      req = Net::HTTP::Get.new(uri)
      res = execute_request(req, uri)

      return [] unless res.is_a?(Net::HTTPSuccess)

      data = JSON.parse(res.body)
      return [] unless data.is_a?(Array)

      data.select { |item| item.is_a?(Hash) && item["name"]&.end_with?(".md") }
          .map { |item| File.basename(item["name"], ".md") }
    rescue StandardError
      []
    end
  end
end
