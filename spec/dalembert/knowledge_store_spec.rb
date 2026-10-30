# frozen_string_literal: true

require "rspec"
require "tmpdir"
require "dalembert/knowledge_store"

RSpec.describe Dalembert::KnowledgeStore do
  let(:original_env) { ENV.to_h }

  after do
    ENV.clear
    ENV.update(original_env)
  end

  describe "initialization and mode switching" do
    context "when neither GITHUB_TOKEN nor KNOWLEDGE_REPO is set" do
      before do
        ENV.delete("GITHUB_TOKEN")
        ENV.delete("KNOWLEDGE_REPO")
        ENV.delete("KNOWLEDGE_BRANCH")
      end

      it "defaults to local mode with ./knowledge_vault and main branch" do
        store = described_class.new
        expect(store.github_mode?).to be false
        expect(store.vault_path).to eq("./knowledge_vault")
        expect(store.branch).to eq("main")
      end
    end

    context "when only GITHUB_TOKEN is set" do
      before do
        ENV["GITHUB_TOKEN"] = "token123"
        ENV.delete("KNOWLEDGE_REPO")
      end

      it "falls back to local mode" do
        store = described_class.new
        expect(store.github_mode?).to be false
      end
    end

    context "when only KNOWLEDGE_REPO is set" do
      before do
        ENV.delete("GITHUB_TOKEN")
        ENV["KNOWLEDGE_REPO"] = "owner/repo"
      end

      it "falls back to local mode" do
        store = described_class.new
        expect(store.github_mode?).to be false
      end
    end

    context "when both GITHUB_TOKEN and KNOWLEDGE_REPO are set" do
      before do
        ENV["GITHUB_TOKEN"] = "token123"
        ENV["KNOWLEDGE_REPO"] = "owner/my-knowledge"
      end

      it "switches to GitHub mode with default main branch" do
        store = described_class.new
        expect(store.github_mode?).to be true
        expect(store.token).to eq("token123")
        expect(store.repo).to eq("owner/my-knowledge")
        expect(store.branch).to eq("main")
      end

      it "respects KNOWLEDGE_BRANCH when set" do
        ENV["KNOWLEDGE_BRANCH"] = "custom-branch"
        store = described_class.new
        expect(store.branch).to eq("custom-branch")
      end

      it "supports explicit constructor overrides" do
        store = described_class.new(
          token: "override-token",
          repo: "override-owner/override-repo",
          branch: "override-branch"
        )
        expect(store.github_mode?).to be true
        expect(store.token).to eq("override-token")
        expect(store.repo).to eq("override-owner/override-repo")
        expect(store.branch).to eq("override-branch")
      end
    end
  end

  describe "local mode" do
    let(:tmp_dir) { Dir.mktmpdir("dalembert_test_vault_") }
    let(:store) { described_class.new(tmp_dir) }

    before do
      ENV.delete("GITHUB_TOKEN")
      ENV.delete("KNOWLEDGE_REPO")
    end

    after do
      FileUtils.remove_entry(tmp_dir) if File.exist?(tmp_dir)
    end

    describe "#store" do
      it "writes content to the local vault and returns status" do
        res = store.store("architecture-notes", "# Architecture Overview")
        expected_file = File.join(tmp_dir, "architecture-notes.md")

        expect(res).to eq("Stored knowledge in #{expected_file}")
        expect(File.read(expected_file)).to eq("# Architecture Overview")
      end

      it "sanitizes non-alphanumeric characters in topic" do
        store.store("Topic With Special / Characters! & Spaces", "Content")
        expected_file = File.join(tmp_dir, "Topic_With_Special___Characters____Spaces.md")

        expect(File.exist?(expected_file)).to be true
        expect(File.read(expected_file)).to eq("Content")
      end
    end

    describe "#retrieve" do
      it "reads stored content from the vault" do
        store.store("ruby-guide", "Ruby 3.3 notes")
        expect(store.retrieve("ruby-guide")).to eq("Ruby 3.3 notes")
      end

      it "returns nil if topic does not exist" do
        expect(store.retrieve("non-existent-topic")).to be_nil
      end
    end

    describe "#list_topics" do
      it "returns all topic names stripped of .md extension" do
        store.store("topic-one", "Content 1")
        store.store("topic-two", "Content 2")
        File.write(File.join(tmp_dir, "ignored.txt"), "Ignored file")

        topics = store.list_topics
        expect(topics).to contain_exactly("topic-one", "topic-two")
      end

      it "returns empty array when vault has no topics" do
        expect(store.list_topics).to eq([])
      end
    end
  end

  describe "GitHub mode" do
    let(:token) { "ghp_testtoken12345" }
    let(:repo) { "test-owner/test-knowledge" }
    let(:branch) { "main" }
    let(:store) { described_class.new(token: token, repo: repo, branch: branch) }
    let(:http_double) { double("Net::HTTP") }

    before do
      allow(Net::HTTP).to receive(:start).and_yield(http_double)
    end

    describe "#store" do
      context "when creating a new file (file does not exist on GitHub)" do
        it "fetches sha with GET (receiving 404), then sends PUT to create file" do
          get_performed = false
          put_performed = false

          allow(http_double).to receive(:request) do |req|
            expect(req["User-Agent"]).to eq("Dalembert-Agent")
            expect(req["Authorization"]).to eq("Bearer #{token}")
            expect(req["Accept"]).to eq("application/vnd.github.v3+json")

            if req.is_a?(Net::HTTP::Get)
              get_performed = true
              expect(req.uri.to_s).to eq("https://api.github.com/repos/#{repo}/contents/my-topic.md?ref=#{branch}")
              not_found = Net::HTTPNotFound.new("1.1", "404", "Not Found")
              allow(not_found).to receive(:body).and_return('{"message":"Not Found"}')
              not_found
            elsif req.is_a?(Net::HTTP::Put)
              put_performed = true
              expect(req.uri.to_s).to eq("https://api.github.com/repos/#{repo}/contents/my-topic.md")
              expect(req["Content-Type"]).to eq("application/json")

              body = JSON.parse(req.body)
              expect(body["message"]).to eq("Create my-topic.md via Dalembert")
              expect(body["content"]).to eq(Base64.strict_encode64("# My New Topic"))
              expect(body["branch"]).to eq(branch)
              expect(body).not_to have_key("sha")

              created = Net::HTTPCreated.new("1.1", "201", "Created")
              allow(created).to receive(:body).and_return('{"content":{"name":"my-topic.md"}}')
              created
            end
          end

          result = store.store("my-topic", "# My New Topic")
          expect(get_performed).to be true
          expect(put_performed).to be true
          expect(result).to eq("Stored knowledge in #{repo}/my-topic.md")
        end
      end

      context "when updating an existing file" do
        it "fetches existing sha with GET (receiving 200), then sends PUT with sha" do
          get_performed = false
          put_performed = false

          allow(http_double).to receive(:request) do |req|
            if req.is_a?(Net::HTTP::Get)
              get_performed = true
              expect(req.uri.to_s).to eq("https://api.github.com/repos/#{repo}/contents/my-topic.md?ref=#{branch}")
              ok = Net::HTTPOK.new("1.1", "200", "OK")
              allow(ok).to receive(:body).and_return(JSON.generate({ "sha" => "existing_sha_999" }))
              ok
            elsif req.is_a?(Net::HTTP::Put)
              put_performed = true
              expect(req.uri.to_s).to eq("https://api.github.com/repos/#{repo}/contents/my-topic.md")

              body = JSON.parse(req.body)
              expect(body["message"]).to eq("Update my-topic.md via Dalembert")
              expect(body["content"]).to eq(Base64.strict_encode64("# Updated Topic"))
              expect(body["branch"]).to eq(branch)
              expect(body["sha"]).to eq("existing_sha_999")

              ok = Net::HTTPOK.new("1.1", "200", "OK")
              allow(ok).to receive(:body).and_return('{"content":{"name":"my-topic.md"}}')
              ok
            end
          end

          result = store.store("my-topic", "# Updated Topic")
          expect(get_performed).to be true
          expect(put_performed).to be true
          expect(result).to eq("Stored knowledge in #{repo}/my-topic.md")
        end
      end

      context "when PUT fails" do
        it "returns an error string" do
          allow(http_double).to receive(:request) do |req|
            if req.is_a?(Net::HTTP::Get)
              not_found = Net::HTTPNotFound.new("1.1", "404", "Not Found")
              allow(not_found).to receive(:body).and_return('{"message":"Not Found"}')
              not_found
            elsif req.is_a?(Net::HTTP::Put)
              forbidden = Net::HTTPForbidden.new("1.1", "403", "Forbidden")
              allow(forbidden).to receive(:body).and_return('{"message":"Bad credentials"}')
              forbidden
            end
          end

          result = store.store("my-topic", "Content")
          expect(result).to include("Error storing knowledge to GitHub: 403 Forbidden")
        end
      end
    end

    describe "#retrieve" do
      it "fetches file via GET and decodes Base64 content" do
        allow(http_double).to receive(:request) do |req|
          expect(req).to be_a(Net::HTTP::Get)
          expect(req.uri.to_s).to eq("https://api.github.com/repos/#{repo}/contents/my-topic.md?ref=#{branch}")
          expect(req["User-Agent"]).to eq("Dalembert-Agent")
          expect(req["Authorization"]).to eq("Bearer #{token}")

          raw_text = "# Decoded Knowledge\nSome details here."
          payload = {
            "name" => "my-topic.md",
            "content" => Base64.encode64(raw_text),
            "encoding" => "base64"
          }

          ok = Net::HTTPOK.new("1.1", "200", "OK")
          allow(ok).to receive(:body).and_return(JSON.generate(payload))
          ok
        end

        expect(store.retrieve("my-topic")).to eq("# Decoded Knowledge\nSome details here.")
      end

      it "returns nil when GET returns 404" do
        allow(http_double).to receive(:request) do |req|
          not_found = Net::HTTPNotFound.new("1.1", "404", "Not Found")
          allow(not_found).to receive(:body).and_return('{"message":"Not Found"}')
          not_found
        end

        expect(store.retrieve("missing-topic")).to be_nil
      end

      it "returns nil on non-success HTTP status" do
        allow(http_double).to receive(:request) do |req|
          server_err = Net::HTTPInternalServerError.new("1.1", "500", "Internal Server Error")
          allow(server_err).to receive(:body).and_return('{"message":"Error"}')
          server_err
        end

        expect(store.retrieve("broken-topic")).to be_nil
      end
    end

    describe "#list_topics" do
      it "fetches directory contents and filters .md files, stripping the extension" do
        allow(http_double).to receive(:request) do |req|
          expect(req).to be_a(Net::HTTP::Get)
          expect(req.uri.to_s).to eq("https://api.github.com/repos/#{repo}/contents?ref=#{branch}")
          expect(req["User-Agent"]).to eq("Dalembert-Agent")
          expect(req["Authorization"]).to eq("Bearer #{token}")

          payload = [
            { "name" => "ruby-patterns.md", "type" => "file" },
            { "name" => "architecture.md", "type" => "file" },
            { "name" => "diagram.png", "type" => "file" },
            { "name" => "docs", "type" => "dir" }
          ]

          ok = Net::HTTPOK.new("1.1", "200", "OK")
          allow(ok).to receive(:body).and_return(JSON.generate(payload))
          ok
        end

        expect(store.list_topics).to eq(["ruby-patterns", "architecture"])
      end

      it "returns empty array when no files match or response is empty" do
        allow(http_double).to receive(:request) do |req|
          ok = Net::HTTPOK.new("1.1", "200", "OK")
          allow(ok).to receive(:body).and_return("[]")
          ok
        end

        expect(store.list_topics).to eq([])
      end

      it "returns empty array on 404 or non-success response" do
        allow(http_double).to receive(:request) do |req|
          not_found = Net::HTTPNotFound.new("1.1", "404", "Not Found")
          allow(not_found).to receive(:body).and_return('{"message":"Not Found"}')
          not_found
        end

        expect(store.list_topics).to eq([])
      end
    end
  end
end
