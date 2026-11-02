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

**Descartes 生态系统下的百科全书式编码与文档情报大脑。**  
*以让·勒朗·达朗贝尔（Jean le Rond d'Alembert，1717–1783，法国《百科全书》副主编、启蒙思想家与理性知识综合先驱）命名。*

基于 Descartes 生态系统构建：
- 🧠 **[Descartes](https://github.com/catclever/Descartes)**：响应式智能体 SDK 与推理核心；
- 🌐 **[Descartes Produit](https://github.com/catclever/descartes-produit)**：协调云端与边缘的分布式 WebSocket 枢纽；

配合使用的原生边缘执行体：
- ⚡ **[EnginEdge](https://github.com/catclever/EnginEdge)**：用 Rust 编写的高性能原生边缘执行体——提供本地 MCP stdio 服务、Tree-sitter AST 解析引擎、沙箱隔离以及实时云端 WebSocket 桥接。

---

## 🌌 完整生态：“魂在云端，身在边缘”（Soul in Cloud, Body at Edge）

在真实的软件工程研发中，Dalembert 作为云端知识与情报智脑，与本地边缘执行体 **[EnginEdge](https://github.com/catclever/EnginEdge)** 紧密协同：
* **云端智脑 (Dalembert)**：负责理解复杂研发意图、主动调研开源代码与查阅权威规范，依托底层 **[Descartes](https://github.com/catclever/Descartes)** 核心算法进行深度推理与架构决策。
* **边缘执行体 (EnginEdge)**：扎根开发者本地机器或受控容器，通过 MCP 协议与 AST 引擎安全执行文件读写、语法分析与命令操作。

两者实现了认知推理与本地环境读写执行的彻底解耦，在保障开发环境安全的前提下带来极速、低延迟的智能编程体验。

---

## 🏛️ 架构与核心准则

Dalembert 严格恪守核心准则：**优先查阅权威文档并比对真实世界开源实现；绝不盲目猜测未知的 API。**

大语言模型常在复杂架构中凭空幻觉私有方法、过时参数或不存在的配置项。Dalembert 通过主动检索公共开源仓库、提取核心测试断言，将一切设计决策锚定在“已被代码检验的事实”之上。

```
                           +-------------------------------------+
                           |         Railway / 云端服务器         |
                           |                                     |
                           |       +--------------------+        |
                           |       |   Dalembert 智脑   |        |
                           |       |  (百科知识与推理)  |        |
                           |       +---------+----------+        |
                           |                 |                   |
                           |       +---------v----------+        |
                           |       |  Descartes-Produit |        |
                           |       |  (WebSocket Hub)   |        |
                           +-----------------+-------------------+
                                             ^
                                             | WSS 安全长连接
                                             v
                           +-----------------+-------------------+
                           |            EnginEdge                |
                           |      (Rust 原生边缘执行体)          |
                           |                                     |
                           |  - Tree-sitter AST 与代码结构提取   |
                           |  - 沙箱隔离文件读写与命令执行       |
                           |  - Model Context Protocol (MCP)     |
                           +-------------------------------------+
```

---

## 🛠 特性与专属情报工具

Dalembert 内置了面向深度代码调研的一组专业工具：

1. **`github_repo_survey`**：按主题或关键词搜索 GitHub 仓库，无需执行冗重的全量克隆即可安全拉取仓库蓝图（README、目录拓扑和架构配置文件）。
2. **`github_code_search`**：在生产级开源代码库中检索类、方法与调用范式的真实使用案例。
3. **`doc_fetcher`**：从官方文档站点纯净抽取原始 Markdown 文档与 API 规范。
4. **`spec_inspector`**：远程检视测试文件（如 `*_spec.rb`、测试套件），提取测试断言和边界条件作为权威真相。
5. **`knowledge_store`**：双模持久化存储层。可将架构决策与调研笔记保存到本地 Markdown Vault，或通过 GitHub Contents API 直写远端 GitHub 知识仓库。

---

## 🚀 云端部署与配置

### Railway 一键容器部署

Dalembert 提供了生产级容器化配置：
* [`Dockerfile`](Dockerfile)：基于 `ruby:3.3-slim` 构建。
* [`railway.json`](railway.json)：强制锁定构建器为 `DOCKERFILE`，防止回退。
* [`bin/dalembert-server`](bin/dalembert-server)：基于 Puma 的 HTTP 与 WebSocket 服务入口，监听 `8089` 端口。

#### 12-Factor 纯环境变量直驱（Zero-Config）

完全解耦代码与配置文件，支持在 Railway 控制台通过环境变量一键切换模型服务商：

```env
# 1. 服务端口与安全防护
PORT=8089
HOST=0.0.0.0
HUB_AUTH_TOKEN=your_secret_access_token   # 可选：保护 WebSocket 连接的握手鉴权令牌

# 2. 大模型直驱配置（零配置文件）
LLM_BASE_URL=https://api.deepseek.com/v1 # 或 http://workbuddy2api.railway.internal:48787/v1
LLM_MODEL=deepseek-chat
LLM_API_KEY=sk-xxxx

# 3. 知识库持久化（GitHub Contents API）
GITHUB_TOKEN=github_pat_xxxx
KNOWLEDGE_REPO=catclever/dalembert-knowledge
KNOWLEDGE_BRANCH=main
```

---

## ⚡ 配合 EnginEdge (Rust 客户端) 联动

通过本地安装的 [EnginEdge](https://github.com/catclever/EnginEdge) 随时直连云端 Dalembert：

```bash
# 触发一次云端推理 + 本地执行的即时任务
DESCARTES_WS_URL="wss://dalembert-production.up.railway.app" \
HUB_AUTH_TOKEN="your_secret_access_token" \
enginedge run "调研 catclever/Descartes 的架构并输出演进报告"

# 或将 EnginEdge 作为本地 MCP Server 接入 Cursor / Claude Desktop
enginedge mcp
```

---

## 📦 安装与本地命令行使用

在应用的 `Gemfile` 中添加：

```ruby
gem "descartes", github: "catclever/Descartes"
gem "descartes-produit", github: "catclever/descartes-produit"
gem "dalembert", github: "catclever/Dalembert"
```

通过独立 CLI 执行单次调研：

```bash
$ bundle exec bin/dalembert -j "Analyze the catclever/Descartes architecture" -m 10
```

或接入 `Descartes::Body` 状态机执行集群：

```ruby
require "dalembert"

Descartes::Body.define(:research_cluster) do
  roster do
    agent :researcher, instance: Dalembert::Agent.new
  end
end
```

---

## 📝 许可证

采用 [MIT 许可证](LICENSE.txt)。
