# Udha for iOS — setup and working notes

This is the iPhone/iPad client for **Udha**, which supervises long-running AI coding sessions (Claude Code, Codex,
Qwen Code, any shell command) on your own machines. The phone does not run sessions. It connects through a
**relay** to a **host**: the Udha macOS app or the headless `udha-agent` on a Linux box. From the phone you see every
session, read its terminal, answer prompts, start new sessions, record meetings and talk to an agent by voice.

These notes are for anyone setting the project up, human or Claude Code. Follow the sections in order. Section 2 is
enough to see the app running.

```
  iPhone / iPad ── wss ──►  your relay  ◄── wss ── Udha macOS app  /  udha-agent (Linux)
  (this repo)               (auth: your Auth0 tenant)    (the hosts run the sessions)
```

The relay and the hosts are in the **Udha desktop repository**, not here. Its `relay/README.md` and
`docs/self-hosting.md` cover running them.

---

## 1. Requirements

- macOS with **Xcode 26.1 or newer**. The deployment target is **iOS 26.1**.
- No package managers and no third-party dependencies. The project uses only system frameworks.
- For a device build you need an Apple developer team. A free personal team runs the app on your own device, but
  push notifications and Live Activities need a paid team. The simulator needs no team.

## 2. Five-minute run: the simulator with the mock host

You need no relay, no Auth0 and no Mac host for this. `Udha.ai/Debug/MockHost.swift` is a fake desktop that speaks
the real wire protocol to the real client code. It is compiled into Debug builds only.

```bash
git clone <this repo> udha-ios && cd udha-ios
open Udha.xcodeproj
```

In Xcode, choose **Product → Scheme → Edit Scheme… → Run → Arguments** and add the launch argument
`--udha-mock`. Pick an iPhone simulator and press Run.

Other launch arguments for the mock host:

| Argument | Effect |
|---|---|
| `--udha-scenario=standard` | A realistic mixed fleet (the default) |
| `--udha-scenario=empty` | No sessions |
| `--udha-scenario=allBlocked` | Every session waiting on a human |
| `--udha-scenario=longform` | Long, ugly strings, for testing layout |
| `--udha-select=<id>` | Opens straight into one session |
| `--udha-mute-terminal` | Stops the mock terminal's animation |

The same from the command line:

```bash
xcodebuild -project Udha.xcodeproj -scheme Udha \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build build
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; open -a Simulator
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Udha.app
xcrun simctl launch booted "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  build/Build/Products/Debug-iphonesimulator/Udha.app/Info.plist)" --udha-mock
```

## 3. Your configuration: `Local.xcconfig`

Everything that identifies a deployment is a build setting. `Udha.xcconfig` is committed and holds empty
defaults. It includes `Local.xcconfig`, which is git-ignored and holds your values:

```bash
cp Local.xcconfig.example Local.xcconfig
$EDITOR Local.xcconfig
```

| Setting | What it is | Needed for |
|---|---|---|
| `UDHA_BUNDLE_ID` | The app's bundle id. The widget becomes `<id>.UdhaWidgets`, and the Auth0 callback is `<id>://callback`. | Device builds (must be unique to your team) |
| `DEVELOPMENT_TEAM` | Your Apple team id | Device builds |
| `UDHA_RELAY_HOST` | Your relay's host name with no scheme, e.g. `relay.example.com`. The app dials `wss://<host>/client`. | Real hosts |
| `UDHA_AUTH0_DOMAIN` | Your Auth0 tenant, e.g. `your-tenant.us.auth0.com` | Sign-in |
| `UDHA_AUTH0_CLIENT_ID` | Client id of the Auth0 **Native** application (PKCE, no secret) | Sign-in |
| `UDHA_AUTH0_AUDIENCE` | Optional. Empty means `https://<UDHA_RELAY_HOST>`. To set a full URL, write it as `https:/$()/api.example.com`, because xcconfig treats `//` as a comment. | Only if your API identifier differs |

These values reach the app through `Info.plist`, as the `UdhaRelayHost` and `UdhaAuth0*` keys. Swift reads them
through `AppConfig` in `Udha.ai/Bridge/BridgeModels.swift`. Never hard-code a host, tenant or team in source. Put
it in `Local.xcconfig`.

None of these values is secret, but they are *yours*: `Local.xcconfig` must never be committed.

After you change an xcconfig, do a clean build (**Product → Clean Build Folder**). Xcode caches the expanded
`Info.plist`.

## 4. Connect to a real host

1. **Run a relay and an Auth0 tenant.** Follow `docs/self-hosting.md` in the desktop repo. In short:
   - Run the relay (`relay/`, Docker) behind TLS, so it's reachable at `wss://relay.example.com`.
   - In Auth0, create an **API** whose identifier is `https://relay.example.com` and turn on **Allow Offline
     Access**. Without it there's no refresh token, and the phone drops off when the access token expires.
   - In Auth0, create a **Native application**. The desktop, the agent and the phone can all share it.
2. **Allow the phone's callback** in that Native application. Add `<UDHA_BUNDLE_ID>://callback` to *Allowed
   Callback URLs*. Keep the *Refresh Token* grant enabled.
3. **Fill in `Local.xcconfig`** (section 3), then clean and build to your device or the simulator. Run without
   `--udha-mock`.
4. **Sign in on the phone** with the same Auth0 user the host is signed in with. The relay pairs devices by user,
   so the phone lists that user's online hosts and connects to one.
5. **Sign in the host.** On the Mac app, go to Settings → iPhone, enter the same four values and enable the
   bridge. On Linux, run `udha-agent login`.

If sign-in shows "No relay configured…", the relay and Auth0 settings didn't reach the build. Check
`Local.xcconfig`, then clean and rebuild.

## 5. Optional features

- **Push notifications** (a session needs you): need a paid team with the Push Notifications capability, plus
  the relay configured with an APNs key. See the relay README. The entitlement lives in
  `Udha.ai/Udha.entitlements` (`aps-environment`).
- **Live Activities** (meeting in progress): the `UdhaWidgets` extension target. It signs with the same team.
- **Ask-about-this-meeting**: needs an Anthropic API key. You enter it in the app's Settings and it's stored in the
  Keychain. It never ships in the build.
- **Voice agent**: uses ElevenLabs ConvAI. The *host* mints a signed URL, so no ElevenLabs key ever reaches the
  phone. Set it up on the desktop.

## 6. Tests

```bash
tests/run.sh
```

This compiles the Foundation-only wire layer (`Udha.ai/Bridge`, the terminal grid, the meeting and video models)
with `swiftc` and runs `tests/main.swift`. No simulator is involved. Run it after any change to the protocol or
the models. It must print `N/N passed`.

## 7. Layout

| Path | What it is |
|---|---|
| `Udha.ai/UdhaApp.swift`, `Udha.ai/App` | App entry and root navigation (`RootView.swift`) |
| `Udha.ai/Bridge` | The wire layer: protocol v2 models and coding, relay socket, `UdhaBridge` state, `AppConfig` |
| `Udha.ai/Sessions`, `Session`, `Terminal` | Session list and detail, diffs, the terminal renderer |
| `Udha.ai/Machines`, `Fleet` | Hosts, with their health and stats |
| `Udha.ai/Agents`, `Videos` | Host-side agents and recordings |
| `Udha.ai/Auth0Manager.swift`, `SecureStorage.swift` | Sign-in (PKCE) and the Keychain |
| `Udha.ai/Meetings` | On-device meeting recorder and host-recorded meetings |
| `Udha.ai/Voice` | Push-to-talk voice agent |
| `Udha.ai/Debug/MockHost.swift` | The fake host behind `--udha-mock`. Debug only. |
| `Udha.ai/Core` | Design system: theme, components, command palette, settings |
| `Shared/` | Code shared with the widget extension |
| `UdhaWidgets/` | Live Activity widget extension |
| `tests/` | Wire-layer tests (`run.sh`) |
| `docs/` | Design notes |

`Udha.ai`, `Shared` and `UdhaWidgets` are Xcode *file-system synchronized* groups, so a new file dropped into
them is part of the target with no `project.pbxproj` edit needed.

## 8. Conventions

- The protocol is shared with the desktop. When you change a message shape, change the desktop's side too and
  keep `tests/run.sh` green on both.
- Swift's default actor isolation is `MainActor` for the app target. Mark pure value or config types
  `nonisolated` when background code needs them, as `AppConfig` is.
- Log with `Logger(subsystem: AppConfig.logSubsystem, category: "<area>")`. Never hard-code a bundle id.
- No secrets or personal infrastructure in the repo: no hosts, tenants, team ids, home directories or machine
  names. Fixtures use invented names (`devbox`, `/Users/alex`, `/home/dev`, `acme`).
