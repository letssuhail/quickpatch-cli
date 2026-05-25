<div align="center">

# ⚡ QuickPatch CLI

**Ship Flutter updates over the air — in seconds, not weeks.**

Push Dart code changes straight to your users' devices. No App Store review for code fixes.

[![Release](https://img.shields.io/github/v/release/letssuhail/quickpatch-cli?color=10b981&label=release)](https://github.com/letssuhail/quickpatch-cli/releases)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux%20%7C%20Windows-10b981)](#installation)
[![License](https://img.shields.io/badge/license-Apache--2.0%20%7C%20MIT-blue)](#license)

</div>

---

## What is QuickPatch?

QuickPatch is a code‑push system for Flutter. After you ship a build to the
stores once, you can push **Dart code updates over the air** — bug fixes, UI
tweaks, new screens — and your users get them on the next launch. No re‑review,
no reinstall.

- ⚡ **Instant code‑push** — publish a patch in seconds
- 📱 **Android & iOS** — one workflow for both
- 🎯 **Staged rollouts** — release to 10%, watch, then ramp to 100% (or pause)
- 🔒 **Safe** — patches are verified against the exact release they target
- 📊 **Live telemetry** — downloads, installs, and failures per patch

## Installation

**Via pub.dev (recommended — macOS / Linux / Windows)**

```bash
dart pub global activate quickpatch_cli
```

Make sure `~/.pub-cache/bin` (or `%APPDATA%\Pub\Cache\bin` on Windows) is on your `PATH`, then run `quickpatch --version`.

**Or download a pre-built binary**

Grab the latest binary for your platform from the [GitHub Releases](https://github.com/letssuhail/quickpatch-cli/releases) page, extract it, and put it on your `PATH`.

**Upgrade**

```bash
quickpatch upgrade
# or run the same activate command again:
dart pub global activate quickpatch_cli
```

## Quick start

```bash
# 1. Log in (get an API key from https://quickpatch.vercel.app)
quickpatch login

# 2. Point the CLI at your server
export QUICKPATCH_HOSTED_URL="https://your-server.example.com"

# 3. In your Flutter project
quickpatch init
quickpatch release android        # build + publish a release; upload to the store as usual

# 4. Make a Dart change, then ship it over the air
quickpatch patch android --release-version=1.0.0+1
```

Your users' apps check for the patch on launch and apply it on the next one.

## Commands

| Command | Description |
| --- | --- |
| `quickpatch login` | Authenticate with your API key from the dashboard |
| `quickpatch logout` | Remove stored credentials |
| `quickpatch init` | Register the app and create `quickpatch.yaml` |
| `quickpatch release android\|ios` | Build + publish a release (ship this to the store) |
| `quickpatch patch android\|ios --release-version=<v>` | Publish an OTA patch for a release |
| `quickpatch releases list` | List releases for the current app |
| `quickpatch patches list` | List patches for the current app |
| `quickpatch doctor` | Diagnose your setup |
| `quickpatch upgrade` | Show how to upgrade to the latest version |

## What can be patched?

| ✅ Works as a patch | ❌ Needs a full release |
| --- | --- |
| Dart logic & bug fixes | New Flutter plugins |
| UI changes, new screens | Native code (Kotlin / Swift) |
| Text, colors, styling | New bundled assets / fonts |
| Business‑logic changes | App version / SDK changes |

## Platform support

| Platform | Build Android | Build iOS |
| --- | --- | --- |
| macOS | ✅ | ✅ |
| Linux | ✅ | — |
| Windows | ✅ | — |

iOS releases require macOS (Apple's toolchain). Android works everywhere.

## License

Dual‑licensed under [Apache 2.0](LICENSE-APACHE) and [MIT](LICENSE-MIT).
