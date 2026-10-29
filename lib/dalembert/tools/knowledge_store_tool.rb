# frozen_string_literal: true

require "descartes"
require_relative "../knowledge_store"

module Dalembert
  module Tools
    class KnowledgeStoreTool < Descartes::Tool::Base
      name "knowledge_store"
      description "Persists architectural decisions, survey notes, and other important text into a local markdown knowledge vault."
      parameters(
        type: "object",
        properties: {
          action: {
            type: "string",
            description: "The action to perform: 'store', 'retrieve', or 'list_topics'."
          },
          topic: {
            type: "string",
            description: "The topic or filename to store/retrieve (required for 'store' and 'retrieve')."
          },
          content: {
            type: "string",
            description: "The markdown content to store (required for 'store')."
          }
        },
        required: ["action"]
      )

      def execute(args)
        action = args["action"]
        store = Dalembert::KnowledgeStore.new

        case action
        when "store"
          return "Error: Missing topic" unless args["topic"]
          return "Error: Missing content" unless args["content"]
          store.store(args["topic"], args["content"])
        when "retrieve"
          return "Error: Missing topic" unless args["topic"]
          result = store.retrieve(args["topic"])
          result || "Topic not found."
        when "list_topics"
          topics = store.list_topics
          topics.empty? ? "No topics found in vault." : topics.join("\n")
        else
          "Error: Unknown action '#{action}'. Valid actions are 'store', 'retrieve', 'list_topics'."
        end
      end
    end
  end
end
