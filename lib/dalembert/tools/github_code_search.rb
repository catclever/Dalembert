# frozen_string_literal: true

require "descartes"
require "json"
require "net/http"
require "uri"

module Dalembert
  module Tools
    class GithubCodeSearch < Descartes::Tool::Base
      name "github_code_search"
      description "Search for real-world usage examples of specific methods, classes, or APIs in popular open-source repositories."
      parameters(
        type: "object",
        properties: {
          query: {
            type: "string",
            description: "The code to search for (e.g., 'Descartes::Agent::Base')."
          },
          repo: {
            type: "string",
            description: "Optional repository to scope the search (e.g., 'catclever/Descartes')."
          },
          language: {
            type: "string",
            description: "Optional language filter (e.g., 'ruby')."
          },
          path: {
            type: "string",
            description: "Optional path filter (e.g., 'spec/')."
          }
        },
        required: ["query"]
      )

      def execute(args)
        query = args["query"]
        return "Error: Missing query" unless query && !query.empty?

        search_query = query.dup
        search_query += " repo:#{args["repo"]}" if args["repo"] && !args["repo"].empty?
        search_query += " language:#{args["language"]}" if args["language"] && !args["language"].empty?
        search_query += " path:#{args["path"]}" if args["path"] && !args["path"].empty?

        url = URI("https://api.github.com/search/code?q=#{URI.encode_www_form_component(search_query)}&per_page=3")
        req = Net::HTTP::Get.new(url)
        req["Accept"] = "application/vnd.github.v3+json"
        req["User-Agent"] = "Dalembert-Agent"

        res = Net::HTTP.start(url.hostname, url.port, use_ssl: true) do |http|
          http.request(req)
        end

        return "Error fetching from GitHub Code Search: #{res.code} #{res.message}" unless res.is_a?(Net::HTTPSuccess)

        data = JSON.parse(res.body)
        items = data["items"] || []
        return "No usage examples found for query: #{search_query}" if items.empty?

        results = items.map do |item|
          "File: #{item["path"]} in #{item.dig("repository", "full_name")}\nURL: #{item["html_url"]}"
        end

        "Found usage examples:\n\n" + results.join("\n\n")
      end
    end
  end
end
