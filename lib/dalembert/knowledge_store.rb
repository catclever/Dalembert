# frozen_string_literal: true

require "fileutils"

module Dalembert
  class KnowledgeStore
    attr_reader :vault_path

    def initialize(vault_path = "./knowledge_vault")
      @vault_path = vault_path
      FileUtils.mkdir_p(@vault_path)
    end

    def store(topic, content)
      safe_topic = topic.gsub(/[^0-9A-Za-z.\-]/, "_")
      file_path = File.join(@vault_path, "#{safe_topic}.md")

      File.write(file_path, content)
      "Stored knowledge in #{file_path}"
    end

    def retrieve(topic)
      safe_topic = topic.gsub(/[^0-9A-Za-z.\-]/, "_")
      file_path = File.join(@vault_path, "#{safe_topic}.md")

      return nil unless File.exist?(file_path)
      File.read(file_path)
    end

    def list_topics
      Dir.glob(File.join(@vault_path, "*.md")).map do |file|
        File.basename(file, ".md")
      end
    end
  end
end
