# Dalembert

[![Ruby](https://img.shields.io/badge/Language-Ruby-red.svg)](https://www.ruby-lang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE.txt)

**百科全书式的编码与文档智能体。**
*以法国《百科全书》副主编让·勒朗·达朗贝尔（Jean le Rond d'Alembert）的名字命名*

基于 Descartes 生态系统构建：
- 🧠 **[Descartes](https://github.com/catclever/Descartes)**: 核心响应式智能体 SDK 与推理引擎。
- 🌐 **[Descartes Produit](https://github.com/catclever/descartes-produit)**: 协调云端推理与边缘执行的分布式 WebSocket 枢纽。

## 🏛️ 架构与使命
Dalembert 旨在成为 Descartes 生态系统的云端知识、文档阅读和开源情报大脑。它强制执行一个严格的原则：*优先查阅文档并对比真实世界的代码实现；绝不盲目猜测未知的 API。*

## 🛠 功能与工具
Dalembert 内置了几个专业的智能工具：
- **GithubRepoSurvey (`github_repo_survey`)**: 通过主题/关键字搜索 GitHub，并在不克隆整个仓库的情况下安全地获取仓库蓝图（如 README 和目录结构）。
- **GithubCodeSearch (`github_code_search`)**: 搜索代码片段在真实世界中的使用案例，跟踪开源库的实际实现方式。
- **DocFetcher (`doc_fetcher`)**: 干净地抓取原始 Markdown 文档和 API 规范。
- **SpecInspector (`spec_inspector`)**: 获取远程测试文件（`*_spec.rb` 或类似文件），以提取测试用例和断言作为基准事实。
- **KnowledgeStore**: 一个内置的持久化层，用于将架构笔记、决策和调查结果记录到本地的 Markdown 知识库中。

## 📦 安装

在您的应用程序的 `Gemfile` 中添加：

```ruby
gem "descartes", github: "catclever/Descartes"
gem "descartes-produit", github: "catclever/descartes-produit"
gem "dalembert", github: "catclever/Dalembert"
```

然后执行：
```bash
$ bundle install
```

## 🚀 使用方法

### 独立 CLI

Dalembert 可以直接从命令行调用：

```bash
$ bundle exec bin/dalembert -j "Analyze the catclever/Descartes architecture" -m 10
```

### 接入 Descartes-Produit

您可以引入 `Dalembert::Agent` 并将其配置到您的 `Descartes::Body` 执行花名册中。

```ruby
require 'dalembert'

Descartes::Body.define(:research_cluster) do
  roster do
    agent :researcher, instance: Dalembert::Agent.new
  end
end
```

## 📝 许可证
MIT License。
