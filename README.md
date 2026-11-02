# Dalembert

<p align="center">
  <a href="README.md"><b>English</b></a> |
  <a href="README.zh-CN.md"><b>简体中文</b></a> |
  <a href="README.fr.md"><b>Français</b></a>
</p>

<p align="center">
  <a href="https://www.ruby-lang.org/"><img src="https://img.shields.io/badge/Language-Ruby-red.svg" alt="Ruby" /></a>
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License" /></a>
  <a href="railway.json"><img src="https://img.shields.io/badge/Deployment-Railway-0B0D0E.svg?logo=railway" alt="Railway" /></a>
</p>

**The Encyclopedic Coding & Documentation Intelligence Brain for the Descartes Ecosystem.**  
*Named in honour of Jean le Rond d'Alembert (1717–1783), co-editor of the French Encyclopédie and champion of rational, evidence-based knowledge.*

---

## 🌌 The Ecosystem: Soul in Cloud, Body at Edge

Dalembert is an essential pillar of the distributed Descartes AI coding agent architecture:

* 🧠 **[Descartes](https://github.com/catclever/Descartes)**: The core reactive Agent SDK, reflection algorithms, and tool orchestration runtime (Ruby).
* 🌐 **[Descartes Produit](https://github.com/catclever/descartes-produit)**: The distributed WebSocket Hub coordinating cloud-based reasoning with local edge tool execution.
* 📚 **[Dalembert](https://github.com/catclever/Dalembert)**: The encyclopedic intelligence brain providing ground-truth documentation, open-source code surveys, spec verification, and GitHub-backed knowledge persistence.
* ⚡ **[EnginEdge](https://github.com/catclever/EnginEdge)**: The ultra-fast native edge executor written in Rust — local MCP stdio server, Tree-sitter AST engine, security chroot jail, and real-time cloud WebSocket bridge.

Together, **Dalembert** (cloud intelligence) and **EnginEdge** (edge execution) separate cognitive reasoning from filesystem manipulation, enabling seamless, secure, and low-latency agent workflows across cloud and workstation environments.

---

## 🏛️ Architecture & Core Philosophy

Dalembert enforces a fundamental rule: **Consult documentation and compare real-world implementations first; never guess unknown APIs.**

Large language models frequently hallucinate private methods, obsolete signatures, and non-existent configuration flags. Dalembert counteracts this by actively inspecting public repositories, extracting test suites, and grounding decisions in verified code before proposing architectural changes.

```
                           +-------------------------------------+
                           |         Railway / Cloud Host        |
                           |                                     |
                           |       +--------------------+        |
                           |       |   Dalembert Brain  |        |
                           |       | (Encyclopedic LLM) |        |
                           |       +---------+----------+        |
                           |                 |                   |
                           |       +---------v----------+        |
                           |       |  Descartes-Produit |        |
                           |       |  (WebSocket Hub)   |        |
                           +-----------------+-------------------+
                                             ^
                                             | WSS (Authenticated)
                                             v
                           +-----------------+-------------------+
                           |            EnginEdge                |
                           |     (Native Rust Edge Engine)       |
                           |                                     |
                           |  - Tree-sitter AST & Parser         |
                           |  - Sandboxed Workspace Tools        |
                           |  - Model Context Protocol (MCP)     |
                           +-------------------------------------+
```

---

## 🛠 Features & Specialized Intelligence Tools

Dalembert equips agents with built-in tools tailored for deep code research:

1. **`github_repo_survey`**: Searches GitHub repositories by topic or query and fetches architectural blueprints (README, directory structure, and config files) without the overhead of full git clones.
2. **`github_code_search`**: Searches real-world usage of classes, functions, or idioms across production open-source repositories.
3. **`doc_fetcher`**: Fetches raw documentation, release notes, and API specifications from online documentation portals.
4. **`spec_inspector`**: Extracts remote test files (`*_spec.rb`, test suites) to examine assertions and edge cases as the ultimate ground truth.
5. **`knowledge_store`**: Dual-mode persistence layer. Saves architectural decisions and findings to a local Markdown vault, or syncs directly to a remote GitHub repository via the GitHub Contents API.

---

## 🚀 Deployment & Configuration

### Cloud Deployment (Railway)

Dalembert includes ready-to-run configurations for Railway and Docker containers:
* [`Dockerfile`](Dockerfile): Multi-stage container based on `ruby:3.3-slim`.
* [`railway.json`](railway.json): Explicitly locks build configuration to `DOCKERFILE`.
* [`bin/dalembert-server`](bin/dalembert-server): Puma HTTP and WebSocket server listening on port `8089`.

#### 12-Factor Zero-Config Environment Variables

Dalembert supports cloud-native direct environment drive without requiring static YAML files:

```env
# 1. Server Configuration
PORT=8089
HOST=0.0.0.0
HUB_AUTH_TOKEN=your_secret_access_token   # Optional: Protects WebSocket handshake

# 2. LLM Direct Drive (Zero-Config)
LLM_BASE_URL=https://api.deepseek.com/v1 # or http://workbuddy2api.railway.internal:48787/v1
LLM_MODEL=deepseek-chat
LLM_API_KEY=sk-xxxx

# 3. Knowledge Persistence (GitHub Contents API)
GITHUB_TOKEN=github_pat_xxxx
KNOWLEDGE_REPO=catclever/dalembert-knowledge
KNOWLEDGE_BRANCH=main
```

---

## ⚡ Connecting with EnginEdge (Rust Client)

Run Dalembert tasks directly from your local terminal through [EnginEdge](https://github.com/catclever/EnginEdge):

```bash
# Execute an ad-hoc cloud task with local edge execution
DESCARTES_WS_URL="wss://dalembert-production.up.railway.app" \
HUB_AUTH_TOKEN="your_secret_access_token" \
enginedge run "Analyze the catclever/Descartes architecture and draft a report"

# Or run EnginEdge as an MCP Server for Cursor / Claude Desktop
enginedge mcp
```

---

## 📦 Installation & Local CLI Usage

Add Dalembert to your `Gemfile`:

```ruby
gem "descartes", github: "catclever/Descartes"
gem "descartes-produit", github: "catclever/descartes-produit"
gem "dalembert", github: "catclever/Dalembert"
```

Run directly via the standalone CLI:

```bash
$ bundle exec bin/dalembert -j "Analyze the catclever/Descartes architecture" -m 10
```

Or integrate into a `Descartes::Body` execution roster:

```ruby
require "dalembert"

Descartes::Body.define(:research_cluster) do
  roster do
    agent :researcher, instance: Dalembert::Agent.new
  end
end
```

---

## 📝 License

Distributed under the [MIT License](LICENSE.txt).
