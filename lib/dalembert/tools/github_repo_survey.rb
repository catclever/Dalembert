# frozen_string_literal: true

require "descartes"
require "json"
require "net/http"
require "uri"

module Dalembert
  module Tools
    class GithubRepoSurvey < Descartes::Tool::Base
      name "github_repo_survey"
      description "Search GitHub repositories by topic, keywords, or stars, and fetch repository blueprints (like README.md, directory outline, or architectural documents) without cloning entire repos."
      parameters(
        type: "object",
        properties: {
          query: {
            type: "string",
            description: "The search query (e.g. 'topic:ruby stars:>100')."
          },
          repo_full_name: {
            type: "string",
            description: "If you already know the repository (e.g., 'catclever/Descartes'), provide this to skip search and directly fetch blueprints."
          }
        }
      )

      def execute(args)
        query = args["query"]
        repo = args["repo_full_name"]

        if repo && !repo.empty?
          fetch_blueprint(repo)
        elsif query && !query.empty?
          search_and_fetch_top(query)
        else
          "Error: Must provide either query or repo_full_name"
        end
      end

      private

      def search_and_fetch_top(query)
        url = URI("https://api.github.com/search/repositories?q=#{URI.encode_www_form_component(query)}&per_page=1")
        req = Net::HTTP::Get.new(url)
        req["Accept"] = "application/vnd.github.v3+json"
        req["User-Agent"] = "Dalembert-Agent"

        res = Net::HTTP.start(url.hostname, url.port, use_ssl: true) do |http|
          http.request(req)
        end

        return "Error fetching from GitHub: #{res.code} #{res.message}" unless res.is_a?(Net::HTTPSuccess)

        data = JSON.parse(res.body)
        items = data["items"]
        return "No repositories found for query: #{query}" if items.nil? || items.empty?

        top_repo = items.first["full_name"]
        "Found top repository: #{top_repo}\n\n" + fetch_blueprint(top_repo)
      end

      def fetch_blueprint(repo)
        readme_content = fetch_readme(repo)
        tree_content = fetch_tree(repo)

        <<~BLUEPRINT
          Blueprint for #{repo}:

          --- DIRECTORY OUTLINE ---
          #{tree_content}

          --- README ---
          #{readme_content}
        BLUEPRINT
      end

      def fetch_readme(repo)
        url = URI("https://api.github.com/repos/#{repo}/readme")
        req = Net::HTTP::Get.new(url)
        req["Accept"] = "application/vnd.github.v3.raw"
        req["User-Agent"] = "Dalembert-Agent"

        res = Net::HTTP.start(url.hostname, url.port, use_ssl: true) do |http|
          http.request(req)
        end

        if res.is_a?(Net::HTTPSuccess)
          res.body[0..2000] + (res.body.length > 2000 ? "\n...(truncated)" : "")
        else
          "README not found or inaccessible."
        end
      end

      def fetch_tree(repo)
        url = URI("https://api.github.com/repos/#{repo}/git/trees/HEAD?recursive=1")
        req = Net::HTTP::Get.new(url)
        req["Accept"] = "application/vnd.github.v3+json"
        req["User-Agent"] = "Dalembert-Agent"

        # Adding authorization for better rate limits if needed in real use, but for now we assume public APIs

        res = Net::HTTP.start(url.hostname, url.port, use_ssl: true) do |http|
          http.request(req)
        end

        return "Could not fetch directory tree." unless res.is_a?(Net::HTTPSuccess)

        data = JSON.parse(res.body)
        paths = data["tree"]&.map { |item| item["path"] } || []

        # filter to just show main architectural folders/files
        filtered = paths.select { |p| p.count("/") < 2 || p.include?("lib/") || p.include?("docs/") || p.include?("README") }
        filtered[0..50].join("\n") + (filtered.length > 50 ? "\n...(truncated)" : "")
      end
    end
  end
end
