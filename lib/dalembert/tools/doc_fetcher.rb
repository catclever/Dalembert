# frozen_string_literal: true

require "descartes"
require "net/http"
require "uri"

module Dalembert
  module Tools
    class DocFetcher < Descartes::Tool::Base
      name "doc_fetcher"
      description "Cleanly fetch official markdown documentation and API specifications from a URL."
      parameters(
        type: "object",
        properties: {
          url: {
            type: "string",
            description: "The direct URL to the markdown documentation or API spec file."
          }
        },
        required: ["url"]
      )

      def execute(args)
        url_string = args["url"]
        return "Error: Missing URL" unless url_string && !url_string.empty?

        begin
          url = URI(url_string)
          req = Net::HTTP::Get.new(url)
          req["User-Agent"] = "Dalembert-DocFetcher"

          res = Net::HTTP.start(url.hostname, url.port, use_ssl: url.scheme == "https") do |http|
            http.request(req)
          end

          return "Error fetching documentation: HTTP #{res.code} #{res.message}" unless res.is_a?(Net::HTTPSuccess)

          content = res.body

          # Basic clean up: return first 5000 characters to prevent overflow
          if content.length > 5000
            content[0..5000] + "\n\n... (truncated for length)"
          else
            content
          end
        rescue StandardError => e
          "Error fetching documentation: #{e.message}"
        end
      end
    end
  end
end
