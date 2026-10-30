# frozen_string_literal: true

require "rspec"
require "dalembert/tools/knowledge_store_tool"

RSpec.describe Dalembert::Tools::KnowledgeStoreTool do
  let(:context) { double("Context") }
  let(:tool) { described_class.new(context) }
  let(:mock_store) { instance_double(Dalembert::KnowledgeStore) }

  before do
    allow(Dalembert::KnowledgeStore).to receive(:new).and_return(mock_store)
  end

  describe "#execute" do
    it "handles store action" do
      expect(mock_store).to receive(:store).with("ruby", "Ruby content").and_return("Stored knowledge in ./knowledge_vault/ruby.md")
      result = tool.execute({ "action" => "store", "topic" => "ruby", "content" => "Ruby content" })
      expect(result).to eq("Stored knowledge in ./knowledge_vault/ruby.md")
    end

    it "validates missing topic on store" do
      result = tool.execute({ "action" => "store", "content" => "Ruby content" })
      expect(result).to eq("Error: Missing topic")
    end

    it "validates missing content on store" do
      result = tool.execute({ "action" => "store", "topic" => "ruby" })
      expect(result).to eq("Error: Missing content")
    end

    it "handles retrieve action when topic found" do
      expect(mock_store).to receive(:retrieve).with("ruby").and_return("Found content")
      result = tool.execute({ "action" => "retrieve", "topic" => "ruby" })
      expect(result).to eq("Found content")
    end

    it "handles retrieve action when topic not found" do
      expect(mock_store).to receive(:retrieve).with("ruby").and_return(nil)
      result = tool.execute({ "action" => "retrieve", "topic" => "ruby" })
      expect(result).to eq("Topic not found.")
    end

    it "validates missing topic on retrieve" do
      result = tool.execute({ "action" => "retrieve" })
      expect(result).to eq("Error: Missing topic")
    end

    it "handles list_topics when topics exist" do
      expect(mock_store).to receive(:list_topics).and_return(["ruby", "descartes"])
      result = tool.execute({ "action" => "list_topics" })
      expect(result).to eq("ruby\ndescartes")
    end

    it "handles list_topics when vault is empty" do
      expect(mock_store).to receive(:list_topics).and_return([])
      result = tool.execute({ "action" => "list_topics" })
      expect(result).to eq("No topics found in vault.")
    end

    it "returns error on unknown action" do
      result = tool.execute({ "action" => "unknown" })
      expect(result).to include("Error: Unknown action 'unknown'")
    end
  end
end
