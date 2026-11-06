<h1 align="center">Octopus</h1>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-1C1B33?logo=apple&logoColor=white" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%26%20Intel-universelle-60A5FA" alt="App universelle" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/licence-MIT-2DD4BF" alt="Licence MIT" /></a>
</p>

<p align="center">
  <a href="README.md">🇬🇧 English</a> · 🇫🇷 Français
</p>

---

Octopus est une interface graphique native pour [Mole](https://github.com/tw93/Mole), l'outil de nettoyage et d'entretien de macOS en ligne de commande de tw93.

Toutes les commandes de Mole, y compris celles absentes du menu de `mo`, sont rangées par catégorie avec leurs options en cases à cocher. La ligne de commande générée s'affiche avant le lancement, et la commande s'exécute dans un vrai terminal intégré : les écrans interactifs de Mole, `sudo` et Touch ID y fonctionnent comme dans Terminal.

> [!NOTE]
> **Fait avec l'aide de l'IA.** Octopus est un projet personnel, construit avec [Claude](https://claude.ai), l'assistant IA d'Anthropic.

> [!IMPORTANT]
> Octopus n'est pas affilié à Mole ni à son auteur. Il pilote le `mo` installé sur ton Mac, sans le modifier.

## ✨ Fonctionnalités

- **Toutes les commandes de Mole** : nettoyage, artefacts de projets, fichiers d'installation, désinstallation d'apps, allègement des apps universelles, optimisation, état du système, exploration du disque, historique, Touch ID, complétion.
- **Aperçu d'abord** : `--dry-run` est coché par défaut sur les commandes qui suppriment ; un vrai lancement demande confirmation.
- **Terminal intégré** (SwiftTerm) : la sortie de Mole, en couleurs, et ses écrans au clavier.
- **Mise à jour de Mole** : Octopus détecte une nouvelle version et la met à jour avec Homebrew ou `mo update`, selon la façon dont Mole est installé. S'il est absent, Octopus propose de l'installer.

## 🧩 Compatibilité

macOS 14 ou plus récent, Apple Silicon ou Intel. Mole doit être installé (Octopus peut s'en charger).

## 📝 Historique des versions

### 0.1.0

- Première version : commandes de Mole générées depuis un catalogue, terminal intégré, installation et mise à jour de Mole.

## 🛠️ Compiler depuis les sources

```sh
brew install xcodegen
xcodegen generate
open Octopus.xcodeproj
```

## 📄 Licence

MIT, voir [LICENSE](LICENSE).
