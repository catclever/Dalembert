# frozen_string_literal: true

require "descartes"
require "net/http"
require "uri"

module Dalembert
  module Tools
    class SpecInspector < Descartes::Tool::Base
      name "spec_inspector"
      description "Extract test cases and assertions from a specific spec file URL as ground truth specifications."
      parameters(
        type: "object",
        properties: {
          spec_url: {
            type: "string",
            description: "The raw URL to the test file (e.g., raw.githubusercontent.com path to a _spec.rb file)."
          }
        },
        required: ["spec_url"]
      )

      def execute(args)
        url_string = args["spec_url"]
        return "Error: Missing spec_url" unless url_string && !url_string.empty?

        begin
          url = URI(url_string)
          req = Net::HTTP::Get.new(url)
          req["User-Agent"] = "Dalembert-SpecInspector"

          res = Net::HTTP.start(url.hostname, url.port, use_ssl: url.scheme == "https") do |http|
            http.request(req)
          end

          return "Error fetching spec: HTTP #{res.code} #{res.message}" unless res.is_a?(Net::HTTPSuccess)

          code = res.body

          # Simple naive extraction of it/test blocks and expects
          extract_assertions(code)
        rescue StandardError => e
          "Error fetching spec: #{e.message}"
        end
      end

      private

      def extract_assertions(code)
        lines = code.split("\n")
        assertions = []
        current_block = nil

        lines.each do |line|
          stripped = line.strip

          if stripped.match?(/^(it|test)\s+['"]/)
            current_block = stripped
            assertions << "\nTest Block: #{current_block}"
          elsif stripped.include?("expect(") || stripped.include?("assert") || stripped.include?("assert_")
            assertions << "  Assertion: #{stripped}"
          end
        end

        return "No standard RSpec/Minitest assertions found." if assertions.empty?

        result = assertions.join("\n")
        if result.length > 3000
          result[0..3000] + "\n... (truncated)"
        else
          result
        end
      end
    end
  end
end
