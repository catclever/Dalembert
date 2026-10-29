# Dalembert

[![Ruby](https://img.shields.io/badge/Language-Ruby-red.svg)](https://www.ruby-lang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE.txt)

**The Encyclopedic Coding & Documentation Intelligence Agent.**
*Named after Jean le Rond d'Alembert (co-editor of the French Encyclopédie)*

Built on top of the Descartes ecosystem:
- 🧠 **[Descartes](https://github.com/catclever/Descartes)**: The core reactive Agent SDK and reasoning engine.
- 🌐 **[Descartes Produit](https://github.com/catclever/descartes-produit)**: The distributed WebSocket Hub coordinating cloud reasoning and edge execution.

## 🏛️ Architecture & Mission
Dalembert is designed to be the cloud knowledge, doc-reading, and open-source intelligence brain for the Descartes ecosystem. It enforces a strict principle: *Consult docs and compare real-world implementations first; never guess unknown APIs.*

## 🛠 Features & Tools
Dalembert ships with several built-in specialized intelligence tools:
- **GithubRepoSurvey (`github_repo_survey`)**: Searches GitHub by topics/keywords and securely fetches repository blueprints (like READMEs and folder structures) without cloning large repositories.
- **GithubCodeSearch (`github_code_search`)**: Searches for real-world usage of code snippets, tracking how open-source libraries are effectively implemented.
- **DocFetcher (`doc_fetcher`)**: Cleanly pulls raw markdown documentation and API specifications.
- **SpecInspector (`spec_inspector`)**: Fetches remote test files (`*_spec.rb` or similar) to extract test cases and assertions to treat as ground truth.
- **KnowledgeStore**: A built-in persistence layer that records architectural notes, decisions, and survey findings to a local markdown vault.

## 📦 Installation

Add to your application's `Gemfile`:

```ruby
gem "descartes", github: "catclever/Descartes"
gem "descartes-produit", github: "catclever/descartes-produit"
gem "dalembert", github: "catclever/Dalembert"
```

Then execute:
```bash
$ bundle install
```

## 🚀 Usage

### Standalone CLI

Dalembert can be invoked directly from the command line:

```bash
$ bundle exec bin/dalembert -j "Analyze the catclever/Descartes architecture" -m 10
```

### Hooking into Descartes-Produit

You can require the `Dalembert::Agent` and configure it in your `Descartes::Body` execution roster.

```ruby
require 'dalembert'

Descartes::Body.define(:research_cluster) do
  roster do
    agent :researcher, instance: Dalembert::Agent.new
  end
end
```

## 📝 License
MIT License.
