require "rspec"
require "dalembert/tools/github_repo_survey"

RSpec.describe Dalembert::Tools::GithubRepoSurvey do
  let(:context) { double("Context") }
  let(:tool) { described_class.new(context) }

  describe "#execute" do
    it "requires either query or repo_full_name" do
      expect(tool.execute({})).to include("Error: Must provide either query or repo_full_name")
    end

    it "handles repo_full_name execution" do
      allow(tool).to receive(:fetch_blueprint).with("catclever/Descartes").and_return("Blueprint Data")
      expect(tool.execute({"repo_full_name" => "catclever/Descartes"})).to eq("Blueprint Data")
    end

    it "handles query execution" do
      allow(tool).to receive(:search_and_fetch_top).with("topic:ruby").and_return("Found repo")
      expect(tool.execute({"query" => "topic:ruby"})).to eq("Found repo")
    end
  end
end
