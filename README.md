<h1 align="center">Octopus</h1>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-1C1B33?logo=apple&logoColor=white" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%26%20Intel-universal-60A5FA" alt="Universal app" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2DD4BF" alt="MIT License" /></a>
</p>

<p align="center">
  🇬🇧 English · <a href="README.fr.md">🇫🇷 Français</a>
</p>

---

Octopus is a native graphical interface for [Mole](https://github.com/tw93/Mole), tw93's command-line tool for cleaning and maintaining macOS.

Every Mole command, including those missing from the `mo` menu, is grouped by category with its options as checkboxes. The generated command line is shown before launch, and the command runs in a real embedded terminal: Mole's interactive screens, `sudo` and Touch ID work just like in Terminal.

> [!NOTE]
> **Built with AI help.** Octopus is a personal project, built with [Claude](https://claude.ai), Anthropic's AI assistant.

> [!IMPORTANT]
> Octopus is not affiliated with Mole or its author. It drives the `mo` installed on your Mac, without modifying it.

## ✨ Features

- **Every Mole command**: cleanup, project artifacts, installer files, app uninstall, slimming universal apps, optimization, system status, disk explorer, history, Touch ID, shell completion.
- **Preview first**: `--dry-run` is checked by default on commands that delete; a real run asks for confirmation.
- **Embedded terminal** (SwiftTerm): Mole's colored output and keyboard-driven screens.
- **Mole updates**: Octopus spots a new version and updates it with Homebrew or `mo update`, depending on how Mole was installed. If Mole is missing, Octopus offers to install it.

## 🧩 Compatibility

macOS 14 or later, Apple Silicon or Intel. Mole must be installed (Octopus can do it for you).

## 📝 Version history

### 0.1.0

- First release: Mole commands generated from a catalog, embedded terminal, Mole install and update.

## 🛠️ Build from source

```sh
brew install xcodegen
xcodegen generate
open Octopus.xcodeproj
```

## 📄 License

MIT, see [LICENSE](LICENSE).
