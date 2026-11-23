<p align="center">
  <img src="docs/assets/icon.png" width="112" height="112" alt="HotspotKeeper Icon" />
</p>

<h1 align="center">HotspotKeeper</h1>

<p align="center">
  <strong>Keep your Mac reliably tethered to your pinned iPhone Personal Hotspot — even alongside Surge, Clash TUN, and Tailscale.</strong>
</p>

<p align="center">
  <a href="README.md"><strong>English</strong></a> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/Wangnov/HotspotKeeper/actions/workflows/ci.yml"><img src="https://github.com/Wangnov/HotspotKeeper/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://github.com/Wangnov/HotspotKeeper/releases/latest"><img src="https://img.shields.io/github/v/release/Wangnov/HotspotKeeper?color=10b981" alt="Latest Release" /></a>
  <img src="https://img.shields.io/badge/macOS-14%2B%20Universal-0ea5e9" alt="macOS 14+ Universal" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-64748b" alt="MIT License" /></a>
</p>

<p align="center">
  <img src="docs/assets/hero.jpg" width="100%" alt="HotspotKeeper Hero Banner" />
</p>

---

## Why HotspotKeeper?

macOS shows your iPhone under **Personal Hotspot** in the Wi-Fi menu, yet rarely reconnects to it reliably on its own when Wi-Fi drops — especially while working remotely from a backpack, café, or commute.

Existing hotspot scripts and utilities also break in two very common power-user setups:

1. **VPN / TUN proxy tools (`Surge Enhanced Mode`, `Clash / Mihomo TUN`, `Tailscale`)**: tools that read `State:/Network/Global/IPv4` see `PrimaryInterface = utun*` (`198.18.0.1`) instead of `en0`, mistakenly thinking your Mac is offline 100% of the time — or failing to detect that you are already on the hotspot (`172.20.10.x`).
2. **Multiple Apple devices on the same Apple Account**: tools that blindly wake the first Bluetooth device discovered will randomly trigger your secondary iPhone or cellular iPad instead of your main hotspot phone.

**HotspotKeeper** is a zero-dependency, single-file native macOS menu bar app + CLI (~10 MB RAM) built to solve both cleanly.

---

## Key Features

- **Surge / Clash TUN / Tailscale Safe** — Inspects real physical network services directly from `SCDynamicStore` (`State:/Network/Service/.*/IPv4`), automatically ignoring `utun*`, `198.18.*`, `100.64.*`, and link-local addresses.
- **Pin Your Exact iPhone** — Filter nearby same-Apple-Account devices by name (case- and whitespace-insensitive) from the menu bar, CLI, or custom input dialog — never accidentally wake the wrong phone.
- **Dual-Channel Reconnect + Active BLE Refresh** — Uses Apple's Instant Hotspot BLE wake (`SFRemoteHotspotSession`) first to wake sleeping hotspot radios and obtain live credentials (with active browse refresh and RAM-only credential caching); automatically falls back to direct Wi-Fi join if the SSID is already broadcasting.
- **Remote-Desktop Friendly (Sill / SSH / AI Agents)** — Never aggressively kicks you off your hotspot back to random weak café/public Wi-Fi networks. Optional *Switch When Wi-Fi Has No Internet (30s)* toggle handles dead or captive-portal Wi-Fi.
- **Opt-in Clamshell Keep-Awake (v1.2.0, MacBook Only, OFF by Default)** — Optional built-in replacement for Amphetamine + Power Protect designed specifically for closed-lid backpack/remote workflows. Keeps your MacBook awake while online, grants a **120s / ≥3-round offline reconnect grace period** (with zero backoff) when Wi-Fi drops, and automatically releases sleep if offline persists, battery drops below 20%, thermal pressure reaches `Serious`, or max closed-lid battery duration (4h default) is hit.
- **Sleep & Battery Respectful by Default** — With Clamshell Keep-Awake disabled (default), HotspotKeeper requests zero `sudo`, touches zero `pmset` settings, uses `NSActivityUserInitiatedAllowingIdleSystemSleep`, and coexists cleanly with macOS sleep policies and **Amphetamine**.
- **Bilingual Native UI** — Automatically adapts to Simplified Chinese and English based on macOS system language. Zero third-party dependencies, zero plaintext passwords written to disk or logged.

---

## Architecture

<p align="center">
  <img src="docs/assets/architecture.svg" width="100%" alt="HotspotKeeper Architecture" />
</p>

---

## Menu Bar Preview

<p align="center">
  <img src="docs/assets/menu-preview.svg" width="390" alt="HotspotKeeper Menu Bar Preview" />
</p>

---

## Quick Start

### Option 1: One-Line Install (Downloads Universal Binary + Enables Start at Login)

```bash
curl -fsSL https://raw.githubusercontent.com/Wangnov/HotspotKeeper/main/install.sh | bash
```

### Option 2: Build from Source (Requires Xcode Command Line Tools)

```bash
git clone https://github.com/Wangnov/HotspotKeeper.git
cd HotspotKeeper
chmod +x build.sh
./build.sh
~/.local/bin/hotspot-keeper --install-login
```

> Pass `./build.sh --universal` to compile a universal (`arm64` + `x86_64`) binary.

### Requirements

- macOS 14.0+ (Apple Silicon or Intel)
- For Bluetooth Instant Hotspot wake: iPhone and Mac signed in to the same Apple Account with Bluetooth & Personal Hotspot enabled.
- Even without Instant Hotspot (e.g. different Apple Account), direct Wi-Fi Keychain reconnect still works whenever your hotspot SSID is broadcasting.

---

## CLI Usage

```bash
hotspot-keeper --status               # Show physical link, IP, router, hotspot, lid, battery & power status
hotspot-keeper --list                 # Discover nearby same-Apple-Account Instant Hotspot devices
hotspot-keeper --test                 # Wake target iPhone hotspot over BLE without switching Wi-Fi
hotspot-keeper --force                # Immediately connect to target hotspot (dual-channel)
hotspot-keeper --target "My iPhone"   # Override target device name for one run
hotspot-keeper --headless             # Run daemon without a menu bar icon
hotspot-keeper --setup-clamshell      # [Opt-in, sudo] Install 3-layer Clamshell Keep-Awake helper
hotspot-keeper --enable-clamshell     # Enable Opt-in Clamshell Keep-Awake (requires --setup-clamshell)
hotspot-keeper --disable-clamshell    # Disable Clamshell Keep-Awake and release SleepDisabled=0
hotspot-keeper --sleep-now            # Release SleepDisabled=0 and put Mac to sleep immediately
hotspot-keeper --teardown-clamshell   # [sudo] Reset SleepDisabled=0 and remove all clamshell system hooks
hotspot-keeper --install-login        # Install & start LaunchAgent
hotspot-keeper --uninstall-login      # Remove LaunchAgent (and release SleepDisabled=0 if owned)
```

Example output:

```text
$ hotspot-keeper --status
target=iPhone 16 Pro Max wifiOn=1 hasPhysicalLink=1 iface=en0 ip=192.168.1.42 router=192.168.1.1 onHotspot=0 internet=1 paused=0 deadWifi=0 loginItem=1 clamshellOptIn=0 clamshellReady=0 amphetamine=0 lid=open sleepDisabled=0 batt=86%(BATT) thermal=nominal

$ hotspot-keeper --list
Found 2 Instant Hotspot device(s):
  * iPhone 16 Pro Max (82%, sig 4)
  - iPhone Duo (74%, sig 3)
```

---

## Opt-in Clamshell Keep-Awake Mode (v1.2.0 · MacBook Only)

> **OFF by default.** If you only want hotspot auto-reconnect — or prefer to keep using Amphetamine — you do **not** need this feature and HotspotKeeper will never ask for `sudo` or touch `pmset`.

When using a MacBook closed-lid inside a bag over hotspot (e.g. with **Sill**, SSH, or AI Agents), macOS on Apple Silicon puts the laptop into Clamshell Sleep on lid close unless `pmset -a disablesleep 1` is active. Using HotspotKeeper's built-in **Clamshell Keep-Awake** removes the dependency on Amphetamine + Power Protect and links power policy directly to network reconnection:

### How It Protects Your Mac (3-Layer Fail-Safe + Guardrails)

| Protection | Behavior |
| :--- | :--- |
| **Offline Reconnect Grace** | When Wi-Fi/hotspot drops while armed, stays awake for **≥ 120s and ≥ 3 full reconnect rounds** (hard cap **180s**, backoff cleared, forced BLE refresh each round). If all rounds fail, releases `disablesleep 0` and lets the Mac sleep safely. |
| **Dead-Link Cap** | If a physical interface stays connected with no internet for **4 minutes**, releases `disablesleep 0` so a captive portal cannot drain your battery forever. |
| **DarkWake Latch** | Once released while lid-closed, stays latched (`HKPowerStateReleasedLatched`) so Power Nap / DarkWake cannot silently re-arm `disablesleep 1` in your bag — only re-arms after lid open or full wake. |
| **Thermal & Battery Guards** | Immediately releases + triggers `pmset sleepnow` if `thermalState >= Serious`; releases below **20%** battery (re-arms at **≥ 25%** or AC); caps continuous closed-lid battery runtime (**4h** default, configurable in menu bar). |
| **3-Layer Crash & Reboot Fail-Safe** | 1. Clean release on Quit / `SIGTERM` / `SIGINT` / system power-off.<br>2. Independent `/bin/sh` LaunchAgent **lease watchdog** (every 30s) resets `disablesleep 0` if the heartbeat lease expires (>120s) — survives `kill -9` or deleting `HotspotKeeper.app`.<br>3. Root `RunAtLoad` **boot-reset LaunchDaemon** (`/Library/LaunchDaemons/io.github.wangnov.hotspot-keeper.sleepguard.plist`) resets `disablesleep 0` on every boot before login/FileVault. |
| **Amphetamine Conflict Guard** | Automatically refuses to arm and yields if **Amphetamine** (`com.if.Amphetamine`) is running or an external tool already holds `SleepDisabled=1`. |

### Setup & Safe Handoff from Amphetamine

```bash
# 1. Install least-privilege $USER-only sudoers (visudo-checked, 0440) + boot-reset daemon + lease watchdog
hotspot-keeper --setup-clamshell

# 2. If you previously used Amphetamine, quit it first (do this while lid is OPEN)
# 3. Enable Clamshell Keep-Awake (or toggle from the menu bar)
hotspot-keeper --enable-clamshell
```

> [!WARNING]
> - **Apple Menu → Sleep & short power-button press are disabled by macOS** while `SleepDisabled = 1` is active (long-press forced power-off still works). Use **Sleep Now (`⌘S`)** in HotspotKeeper's menu bar or `hotspot-keeper --sleep-now` whenever you want to put your Mac to sleep immediately.
> - **Thermal caution**: Running a MacBook closed inside an insulated sleeve/bag reduces passive cooling. Pair with Low Power Mode on battery (`sudo pmset -b lowpowermode 1`) and avoid heavy GPU/CPU loads while enclosed.
> - **Clean removal**: Always run `hotspot-keeper --teardown-clamshell` before uninstalling if you enabled Clamshell Keep-Awake, so `SleepDisabled` is reset to `0` and all system hooks are removed.

---

## Logs & Uninstall

- **Log file**: `~/Library/Logs/HotspotKeeper.log` (auto-trimmed at 2 MB; passwords are never logged)
- **Uninstall**:
  ```bash
  hotspot-keeper --teardown-clamshell   # Only needed if you ran --setup-clamshell
  hotspot-keeper --uninstall-login
  rm -rf ~/Applications/HotspotKeeper.app ~/.local/bin/hotspot-keeper \
         ~/Library/Logs/HotspotKeeper.log ~/Library/Application\ Support/HotspotKeeper
  ```

---

## Acknowledgments & License

Inspired by [samihalawa/mac-auto-hotspot](https://github.com/samihalawa/mac-auto-hotspot) and built from scratch to support TUN proxies (Surge / Clash / Tailscale), exact multi-iPhone pinning, dual-channel reconnect, and bilingual UI.

Released under the [MIT License](LICENSE).
