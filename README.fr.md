# Dalembert

<p align="center">
  <a href="README.md"><b>English</b></a> |
  <a href="README.zh-CN.md"><b>简体中文</b></a> |
  <a href="README.fr.md"><b>Français</b></a>
</p>

<p align="center">
  <a href="https://www.ruby-lang.org/"><img src="https://img.shields.io/badge/Langage-Ruby-red.svg" alt="Ruby" /></a>
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/Licence-MIT-blue.svg" alt="Licence" /></a>
  <a href="railway.json"><img src="https://img.shields.io/badge/D%C3%A9ploiement-Railway-0B0D0E.svg?logo=railway" alt="Railway" /></a>
</p>

**Le Cerveau Encyclopédique d'Intelligence et de Documentation pour l'Écosystème Descartes.**  
*Nommé en hommage à Jean le Rond d'Alembert (1717–1783), coéditeur de l'Encyclopédie et pionnier des Lumières dans la synthèse rationnelle des savoirs.*

Construit sur l'écosystème Descartes :
- 🧠 **[Descartes](https://github.com/catclever/Descartes)** : Le SDK d'agent réactif fondamental et moteur de raisonnement ;
- 🌐 **[Descartes Produit](https://github.com/catclever/descartes-produit)** : Le Hub WebSocket distribué coordonnant le raisonnement dans le Cloud et l'exécution en périphérie ;

Conçu pour s'associer à :
- ⚡ **[EnginEdge](https://github.com/catclever/EnginEdge)** : L'exécuteur natif ultra-rapide écrit en Rust — serveur local MCP stdio, moteur syntaxique AST Tree-sitter, bac à sable sécurisé et pont WebSocket direct vers le Cloud.

---

## 🌌 L'Écosystème : L'Esprit dans le Cloud, le Corps à la Périphérie

Dans le cadre du développement logiciel distribué, Dalembert agit comme le cerveau cognitif et documentaire en étroite synergie avec **[EnginEdge](https://github.com/catclever/EnginEdge)** :
* **L'Esprit dans le Cloud (Dalembert)** : Comprendre les intentions de haut niveau, explorer le code open source, consulter les spécifications officielles et conduire le raisonnement analytique propulsé par **[Descartes](https://github.com/catclever/Descartes)**.
* **Le Corps à la Périphérie (EnginEdge)** : Intégré aux machines de développement ou conteneurs locaux pour manipuler les fichiers, parser les arbres AST et exécuter les commandes en toute sécurité via le protocole MCP.

Grâce à la synergie entre **Dalembert** (l'Esprit dans le Cloud) et **EnginEdge** (le Corps à la Périphérie), le raisonnement cognitif est totalement découplé des manipulations de fichiers locales, garantissant sécurité, légèreté et réactivité maximale.

---

## 🏛️ Architecture et Philosophie Fondamentale

Dalembert impose un principe d'action strict : **Consulter la documentation officielle et comparer le code réel en premier lieu ; ne jamais inventer d'API inconnue.**

Les modèles de langage contemporains ont tendance à halluciner méthodes privées, paramètres obsolètes ou drapeaux de configuration inexistants. Dalembert neutralise ces dérives en explorant les dépôts publics, en extrayant les suites de tests et en ancrant chaque proposition architecturale sur la vérité éprouvée du code.

```
                           +-------------------------------------+
                           |            Hébergeur Cloud          |
                           |                                     |
                           |       +--------------------+        |
                           |       |  Cerveau Dalembert |        |
                           |       |   (LLM & Savoir)   |        |
                           |       +---------+----------+        |
                           |                 |                   |
                           |       +---------v----------+        |
                           |       |  Descartes-Produit |        |
                           |       |  (Hub WebSocket)   |        |
                           +-----------------+-------------------+
                                             ^
                                             | WSS (Authentifié)
                                             v
                           +-----------------+-------------------+
                           |            EnginEdge                |
                           |     (Moteur Edge natif en Rust)     |
                           |                                     |
                           |  - Analyse syntaxique AST Tree-sitt |
                           |  - Outils fichiers en bac à sable   |
                           |  - Protocole Model Context (MCP)    |
                           +-------------------------------------+
```

---

## 🛠 Outils Spécialisés d'Intelligence

Dalembert fournit un ensemble d'outils spécialisés dans l'analyse de code approfondie :

1. **`github_repo_survey`** : Recherche des dépôts GitHub par mots-clés ou sujets et récupère les plans d'architecture (README, arborescence) sans nécessiter de clonage complet lourd.
2. **`github_code_search`** : Recherche des cas d'utilisation concrets de bibliothèques, de classes ou de fonctions dans les projets open source existants.
3. **`doc_fetcher`** : Extrait de manière épurée les documentations brutes au format Markdown et les spécifications d'API.
4. **`spec_inspector`** : Inspecte les suites de tests distantes (`*_spec.rb`, etc.) afin de dégager les assertions fondamentales considérées comme vérités de référence.
5. **`knowledge_store`** : Couche de persistance bimodale. Enregistre les décisions et constats dans un coffre Markdown local, ou synchronise directement vers un dépôt GitHub dédié via l'API GitHub Contents.

---

## 🚀 Déploiement et Configuration

### Déploiement Cloud (Railway)

Dalembert comprend une configuration optimisée pour Railway et Docker :
* [`Dockerfile`](Dockerfile) : Image conteneurisée basée sur `ruby:3.3-slim`.
* [`railway.json`](railway.json) : Verrouille explicitement le moteur de build sur `DOCKERFILE`.
* [`bin/dalembert-server`](bin/dalembert-server) : Serveur Puma HTTP et WebSocket écoutant sur le port `8089`.

#### Configuration Directe par Variables d'Environnement (12-Factor)

Dalembert prend en charge la configuration native par variables d'environnement, sans nécessiter de fichier YAML statique :

```env
# 1. Configuration du Serveur
PORT=8089
HOST=0.0.0.0
HUB_AUTH_TOKEN=votre_jeton_secret          # Optionnel : protège la connexion WebSocket

# 2. Pilotage Direct du LLM (Zéro-Config)
LLM_BASE_URL=https://api.deepseek.com/v1   # ou http://workbuddy2api.railway.internal:48787/v1
LLM_MODEL=deepseek-chat
LLM_API_KEY=sk-xxxx

# 3. Persistance du Savoir (API GitHub Contents)
GITHUB_TOKEN=github_pat_xxxx
KNOWLEDGE_REPO=catclever/dalembert-knowledge
KNOWLEDGE_BRANCH=main
```

---

## ⚡ Connexion avec EnginEdge (Client Rust)

Exécutez vos tâches Dalembert directement depuis votre machine locale via [EnginEdge](https://github.com/catclever/EnginEdge) :

```bash
# Déclencher une tâche cognitive Cloud avec exécution Edge locale
DESCARTES_WS_URL="wss://dalembert-production.up.railway.app" \
HUB_AUTH_TOKEN="votre_jeton_secret" \
enginedge run "Analyser l'architecture de catclever/Descartes et rédiger un rapport"

# Ou lancer EnginEdge en tant que serveur MCP pour Cursor ou Claude Desktop
enginedge mcp
```

---

## 📦 Installation et Utilisation Locale (CLI)

Ajoutez Dalembert dans votre `Gemfile` :

```ruby
gem "descartes", github: "catclever/Descartes"
gem "descartes-produit", github: "catclever/descartes-produit"
gem "dalembert", github: "catclever/Dalembert"
```

Exécutez directement via l'outil en ligne de commande :

```bash
$ bundle exec bin/dalembert -j "Analyser l'architecture de catclever/Descartes" -m 10
```

Ou intégrez l'agent dans un registre d'exécution `Descartes::Body` :

```ruby
require "dalembert"

Descartes::Body.define(:research_cluster) do
  roster do
    agent :researcher, instance: Dalembert::Agent.new
  end
end
```

---

## 📝 Licence

Distribué sous la licence [MIT License](LICENSE.txt).
