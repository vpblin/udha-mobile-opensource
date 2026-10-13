# Udha in the Car — CarPlay Plan

Written 2026-08-23 against `bridge-v2`. Target: two personally-owned CarPlay head units
first, App Store later. Line references are to the tree as read today.

---

## 0. The one constraint that shapes everything

CarPlay app UI requires a per-app entitlement Apple grants only by application, only to
apps in an approved category: navigation, audio, communication/messaging, EV charging,
parking, fueling, quick food ordering, driving task. Udha — a remote control for Claude
Code sessions — is in none of them.

Three facts change what that actually costs us:

1. **The CarPlay Simulator does not validate entitlements.** Simulator builds are ad-hoc
   signed against no provisioning profile, so an entitlement written into
   `Udha.ai/Udha.entitlements` is simply honoured. The entire template app can be
   built and driven today, at zero cost, with no approval from anyone.
2. **A real head unit does validate.** The entitlement must be in the provisioning
   profile, and Xcode refuses to sign a device build carrying one Apple has not granted to
   the app's bundle id. There is no workaround — not a paid account, not TestFlight,
   not ad-hoc distribution.
3. **`INFOPLIST_KEY_UIBackgroundModes = audio` is already set** (`project.pbxproj:369`).
   That one line is why the entitlement-free path is not a consolation prize: an active
   audio session keeps the process alive, which keeps `RelaySocket` alive, which means the
   agent can talk to you in the car over the media channel with no CarPlay entitlement
   whatsoever.

So the work splits into three tracks that proceed in parallel.

| Track | Reaches your car | Needs Apple | Effort |
|---|---|---|---|
| **A** — audio, Siri, notification actions | this week | no | ~3 days |
| **B** — CarPlay templates | simulator now; car only if granted | yes, for the car | ~3 days |
| **C** — the entitlement request | — | yes | 1 hour to file, 2–8 weeks to hear |

Read Track A as the product and Track B as an option on a better one.

---

## 1. Phase 0 — the refactor both tracks need

### 1.1 The bridge is trapped inside a SwiftUI view

`RootView.swift:27` — `@State private var bridge: UdhaBridge?`, constructed in
`startBridge()` (`RootView.swift:105`).

A CarPlay scene is a **separate `UIScene` with its own delegate**. It can connect before
the phone scene exists, after the phone scene was discarded, or while the phone is locked
and the app has never been foregrounded this launch. An App Intent fired by Siri launches
the app into the background with no window scene at all. In every one of those cases
`RootView` has not run, so `bridge` is `nil`, so the car shows nothing.

**Fix: hoist ownership to the process.** New `Udha.ai/App/AppState.swift`:

```swift
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    let auth0 = Auth0Manager()
    let meetingStore = MeetingStore()
    private(set) var bridge: UdhaBridge?

    /// Idempotent. Safe to call from RootView.onAppear, the CarPlay scene
    /// delegate and an App Intent's perform(), in any order, any number of times.
    @discardableResult
    func startBridge() -> UdhaBridge? { … }

    /// Awaits `.ready`, or gives up. Intents need this: Siri launched us three
    /// seconds ago and the relay handshake is not instant.
    func bridgeReady(timeout: Duration = .seconds(6)) async -> UdhaBridge? { … }
}
```

`RootView` keeps its exact shape and reads `AppState.shared` instead of owning the
objects. `Auth0Manager` moves too — an intent cannot present a login sheet, so when auth
is missing every car surface says "open Udha on your phone" and stops there.

`AppState` must be `@MainActor` because `UdhaBridge` is. Mixing `Auth0Manager`
(`ObservableObject`) with the two `@Observable` types inside it is fine.

### 1.2 Backgrounding must not kill the socket while the car is attached

`RootView.swift:74` → `bridge.appDidEnterBackground()` → `RelaySocket.enterBackground()`
(`RelaySocket.swift:139`), which stops the ping, cancels reconnects and drops path
monitoring. Exactly right for a phone in a pocket. Fatal in a car: the phone screen is
off, the app is nominally "backgrounded", and the CarPlay screen is live in front of you
showing a fleet frozen at the moment you started driving.

The comment on `enterBackground()` — *"the process is about to be frozen"* — is an
assumption that stops holding the moment something else keeps the app alive.

```swift
// AppState
var isAttachedToCar: Bool {
    UIApplication.shared.connectedScenes.contains { $0.session.role == .carTemplateApplication }
        || AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
}
```

and in `RootView`'s `scenePhase` handler:

```swift
case .background:
    guard !AppState.shared.isAttachedToCar else { break }
    bridge?.appDidEnterBackground()
```

Track A's audio session is what actually buys the runtime. This guard is what stops us
throwing it away.

---

## 2. Track A — the car build that needs nobody's permission

### A1. Notification actions — highest value per line in the whole plan

`NotificationManager` registers no `UNNotificationCategory` at all; `requestPermission()`
(`NotificationManager.swift:33`) asks for `[.alert, .sound, .badge]` and stops. In the car
that means Siri's *Announce Notifications* reads the push aloud and then offers only
"Reply", which is meaningless for Udha.

With a category carrying actions, Siri announces **and offers them by name**:

> *"Udha: rust-refactor needs you. Approve, or deny?"* → "approve" → `didReceive response`
> fires with `actionIdentifier == "APPROVE"` → `bridge.approve(id)`.

Hands never leave the wheel and no CarPlay entitlement is involved.

```swift
let needsYou = UNNotificationCategory(
    identifier: "SESSION_NEEDS_YOU",
    actions: [
        UNNotificationAction(identifier: "APPROVE", title: "Approve", options: []),
        UNNotificationAction(identifier: "DENY",    title: "Deny",    options: []),
        UNNotificationAction(identifier: "OPEN",    title: "Open",    options: [.foreground]),
    ],
    intentIdentifiers: [],
    options: []
)
```

Three things go with it:

- **Announcement is a per-app user setting**, not a code flag (`allowAnnouncement` was
  deprecated in iOS 15). Toggle Settings → Notifications → Udha → Announce Notifications
  once on each phone, and note it in `INSTALL_ON_IPHONE.md`.
- **Driving Focus will silence Udha** unless the push is
  `content.interruptionLevel = .timeSensitive`. That needs the
  `com.apple.developer.usernotifications.time-sensitive` entitlement — freely enabled in
  Signing & Capabilities, no Apple approval.
- **Relay side**: the APNs payload must carry `"category": "SESSION_NEEDS_YOU"` next to
  the `sessionId` it already sends (`NotificationManager.swift:86`). That belongs in the
  `notify` verb from `BRIDGE_V2_PLAN.md` §0.2.

The action handler faces the same "app may not be running" problem as intents, so it
routes through `AppState.bridgeReady()` rather than assuming a live bridge.

### A2. Now Playing — the car's built-in surface for an app that talks

There is no `MPNowPlayingInfoCenter` or `MPRemoteCommandCenter` anywhere in the app.
Adding them buys, with no entitlement: a Now Playing card on the head unit, Udha listed
as an audio source, and **steering-wheel buttons wired to our own handlers**.

New `Udha.ai/Car/CarNowPlaying.swift`:

| Car control | Meaning in Udha |
|---|---|
| title | active session `label` |
| artist / album | `phase` + `phaseDetail`, else `lastQuestion` |
| ▶︎ / ❚❚ | claim / release the voice floor (`bridge.claimVoice()` / `releaseVoice()`) |
| ⏭ / ⏮ | next / previous session in `sessions(in: .needsYou)` |

Play/pause as claim/release is a hack; it is also the only wheel control we get, and it
maps onto the one binary state that matters while driving.

### A3. Talk as media, not as a phone call

`SpeakerPlayback.setupSharedAudioSession()` (`SpeakerPlayback.swift:70`) sets
`.playAndRecord` / `.voiceChat` / `.defaultToSpeaker` unconditionally at claim time. In a
car that puts every agent utterance on the **hands-free call channel**: your music stops
rather than ducks, the head unit shows a call, and Now Playing never appears.

`configureSessionForPlayback()` (`:140`) already tries `.playback`/`.spokenAudio` first
and falls back — which is the behaviour we want whenever the mic is not hot.

**Decision: split the two paths.** `.playback`/`.spokenAudio` while the agent speaks;
escalate to `.playAndRecord` only for the duration of a PTT press, then drop straight
back. That is the difference between Udha ducking your podcast for eight seconds and
hijacking the stereo for the whole drive.

While in the file: iOS 26 renamed `.allowBluetooth` to `.allowBluetoothHFP` and the
deployment target here is 26.1 (`project.pbxproj:284`), so the deprecation warning is
already there — fix it.

### A4. App Intents — the real hands-free interface

There is no `AppIntent` anywhere in the repo. This is the largest gap in the app, and it
is the one in-car surface Apple lets us use without asking.

`Udha.ai/Intents/UdhaIntents.swift`:

```swift
struct WhatNeedsMeIntent: AppIntent {
    static let title: LocalizedStringResource = "What needs me"
    static let openAppWhenRun = false                 // anything that opens the app is refused while driving
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed  // the phone is locked in your pocket

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let bridge = await AppState.shared.bridgeReady() else {
            return .result(dialog: "Udha can't reach your Mac right now.")
        }
        let rows = bridge.sessions(in: .needsYou)
        guard !rows.isEmpty else { return .result(dialog: "Nothing needs you.") }
        return .result(dialog: .init(stringLiteral: rows.carSpokenSummary))
    }
}
```

Four of them:

- `WhatNeedsMeIntent` — count, plus the first two labels and their questions, spoken.
- `ApproveSessionIntent` — `@Parameter` session, defaulting to the sole `.needsYou` row,
  disambiguating by `label` when there are several.
- `SendToSessionIntent` — free text → `bridge.sendInput(to:text:)`; also fronts
  `QuickCommand.fallback` (`BridgeModels.swift:534`) so "run tests" works as a phrase.
- `SessionStatusIntent` — spoken summary of one named session.

`AppShortcutsProvider` gives zero-setup phrases, and every phrase must embed
`\(.applicationName)`:

```swift
AppShortcut(intent: WhatNeedsMeIntent(),
            phrases: ["What needs me in \(.applicationName)",
                      "Ask \(.applicationName) what's blocked"],
            shortTitle: "What needs me",
            systemImageName: "exclamationmark.bubble.fill")
```

Four gotchas, each worth an afternoon if discovered the hard way:

- `openAppWhenRun = false` is mandatory.
- Without `.alwaysAllowed` the intent silently no-ops against a locked phone.
- `perform()` gets seconds, not minutes — `bridgeReady(timeout:)` must fail closed with a
  spoken sentence, never hang.
- Intents must live in the **app target**, not `UdhaWidgets`, or they cannot reach
  `AppState`.

### A5. What Track A adds up to

Driving, phone in a pocket, screen off:

- Siri announces "rust-refactor needs you" through the car speakers; you say "approve".
- "Hey Siri, what needs me in Udha" → spoken fleet summary.
- "Hey Siri, tell Udha to run tests" → sent.
- Claim the voice floor from the wheel; agent speech arrives as media and ducks your music.

The only thing missing is an app icon on the CarPlay home screen. That is the only thing
Track B adds.

---

## 3. Track B — CarPlay templates

### B1. Wiring

1. **Entitlement** — add `com.apple.developer.carplay-communication` to
   `Udha.ai/Udha.entitlements` (see Track C for why that one).
2. **Scene manifest** — `INFOPLIST_KEY_UIApplicationSceneManifest_Generation` must go to
   `NO` (`project.pbxproj:370` and `:411`). Xcode's generated manifest has no room for a
   second scene role, so the manifest becomes hand-written in `Info.plist` beside the
   existing `CFBundleURLTypes`:

```xml
<key>UIApplicationSceneManifest</key>
<dict>
  <key>UIApplicationSupportsMultipleScenes</key><true/>
  <key>UISceneConfigurations</key>
  <dict>
    <!-- No delegate class: SwiftUI supplies its own for the window role. -->
    <key>UIWindowSceneSessionRoleApplication</key>
    <array><dict>
      <key>UISceneConfigurationName</key><string>Default Configuration</string>
    </dict></array>
    <key>CPTemplateApplicationSceneSessionRoleApplication</key>
    <array><dict>
      <key>UISceneConfigurationName</key><string>Udha Car</string>
      <key>UISceneDelegateClassName</key><string>$(PRODUCT_MODULE_NAME).CarSceneDelegate</string>
    </dict></array>
  </dict>
</dict>
```

3. **New files need no pbxproj surgery.** The project uses
   `PBXFileSystemSynchronizedRootGroup` (`project.pbxproj:42`), so anything dropped under
   `Udha.ai/Car/` joins the target automatically — and there is no `project.pbxproj` merge
   conflict waiting at the end of the branch.

### B2. What CarPlay will and will not let us build

Templates only. No SwiftUI, no custom drawing, no keyboard while moving, at most 5
templates on the stack, `CPTabBarTemplate` capped at 5 tabs, `CPGridTemplate` at 8
buttons, and list length capped per head unit — read `CPListTemplate.maximumItemCount` at
runtime rather than hardcoding it.

Dead on arrival, permanently: `TerminalPane` / `TerminalGrid` / `ANSIText`, `DiffView`,
`SessionDetail`, `CommandPalette`, `NewSessionSheet`, `DirectoryPicker`, and every meeting
view. Not "hard" — impossible. There is no template that renders arbitrary text.

Portable:

| Phone | Car |
|---|---|
| `SessionsList` kanban | one `CPListTemplate` per `SessionAttention`, inside a `CPTabBarTemplate` |
| a row's `dialogOptions` | `CPActionSheetTemplate` (keep it to ~4) |
| approve / deny | `CPAlertTemplate`, two actions |
| `quickCommands` | `CPGridTemplate`, first 8 |
| push-to-talk | `CPVoiceControlTemplate` |
| agent speech | `CPNowPlayingTemplate` — free, once A2 lands |

### B3. The interaction model, which is the actual design problem

Apple's review bar is "usable at 70 mph". For a personal build that is still the right
bar, because you will be the one driving.

- **Never require reading.** `lastQuestion` is arbitrary Claude prose; putting it on a car
  screen is the wrong instinct. Speak it, don't print it.
- **Two taps to the only action that matters**: root list → session → Approve / Deny.
- **No text input while moving.** It is blocked anyway. Free text is voice-only.
- **`isDestructive` on `QuickCommand` (`BridgeModels.swift:513`) must gate a confirm
  alert**, and `killSession` / `closeSession` should not exist in the car at all.

```swift
final class CarSceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect controller: CPInterfaceController) {
        self.controller = controller
        AppState.shared.startBridge()
        controller.setRootTemplate(CarInterface.shared.rootTemplate(), animated: false)
        CarInterface.shared.observe()   // re-render on every UdhaBridge delta
    }
}
```

`observe()` is the interesting part: `UdhaBridge` is `@Observable`, so a
`withObservationTracking` re-arm loop turns each delta into
`listTemplate.updateSections(…)`. Rebuild sections **in place** — pushing a new template
per delta overflows the 5-template stack limit inside a minute.

### B4. Testing without a car

Xcode's iOS Simulator → **I/O → External Displays → CarPlay**. The entitlement in the
`.entitlements` file is honoured, because simulator builds are never checked against a
profile. Pair it with `MockHost` (`Udha.ai/Debug/MockHost.swift`, already gated behind
`MockHost.isEnabled`) and the whole car UI is drivable at a desk against a synthetic
fleet — including states that are painful to provoke for real, like six sessions blocked
at once.

All of Track B's work happens here. It is real, complete, verifiable, costs nothing and is
blocked on nobody.

---

## 4. Track C — the entitlement request

Filed through the CarPlay request form at `developer.apple.com/carplay`. Free; a rejection
costs nothing but the form.

| Entitlement | Intended for | Udha against it |
|---|---|---|
| `carplay-audio` | audio playback apps | the agent does speak and meetings are audio, but Udha is not an audio app and Apple will say so. Weak. |
| `carplay-communication` | messaging and VoIP | **best fit.** `VoiceSession` is a genuine bidirectional voice channel over a socket, with push-to-talk, a transcript and a floor-claim protocol. |
| `carplay-driving-task` | single-step driving-related tasks | nominally the broadest; in practice Apple reads "driving-related" strictly. No. |
| maps / parking / fueling / charging / food | — | no. |

**Request `carplay-communication`, and pitch the voice channel — not the fleet dashboard.**
The honest framing is "a voice link between a driver and their remote agent", which is
precisely what `VoiceSession` already is. Do not describe it as remote-controlling a
terminal from the road; that reads as a driver-distraction hazard and is an instant no.

Realistic odds: low. Apple grants these sparingly and favours apps with a user base; a
single-developer tool is not the profile. Budget zero emotional investment — Track A is
the product. If it is granted, Track B is already written and tested and the only change
is a provisioning profile. If it is declined, we lost one form.

---

## 5. Sequencing and estimate

| # | Work | Days | Blocked on |
|---|---|---|---|
| C | File the entitlement request | 0.1 | — *(do this first; the clock is long)* |
| 0 | `AppState` hoist + car-aware background guard | 1 | — |
| A1 | Notification category, actions, `.timeSensitive`; relay `category` field | 0.5 | 0 |
| A2 | `CarNowPlaying` — info centre + remote commands | 0.5 | 0 |
| A3 | Split playback vs. record audio categories | 0.5 | — |
| A4 | Four App Intents + `AppShortcutsProvider` | 1 | 0 |
| — | **Drive both cars. This is a real ship.** | 0.5 | A1–A4 |
| B1 | Entitlement, hand-written scene manifest, `CarSceneDelegate` | 0.5 | 0 |
| B2 | `CarInterface` — tabs, lists, observation loop | 1 | B1 |
| B3 | Approve/deny sheets, quick-command grid, voice template | 1 | B2 |
| B4 | Drive it in the CarPlay Simulator against `MockHost` | 0.5 | B3 |

**≈ 5.5 days**, of which Track A is 3 — and Track A is the part you will actually use.

New files, all auto-joining the target:

```
Udha.ai/App/AppState.swift
Udha.ai/Car/CarSceneDelegate.swift
Udha.ai/Car/CarInterface.swift      // template stack, observation loop
Udha.ai/Car/CarTemplates.swift      // SessionRow -> CPListItem
Udha.ai/Car/CarNowPlaying.swift     // MPNowPlayingInfoCenter + MPRemoteCommandCenter
Udha.ai/Intents/UdhaIntents.swift
Udha.ai/Intents/UdhaShortcuts.swift
```

---

## 6. Risks, in the order they will bite

1. **Runtime.** Track A rests entirely on the audio session holding the process alive. If
   it lapses between utterances, iOS suspends us and the socket dies mid-drive. Hold the
   session for the whole car attachment rather than per-utterance, and prove it with a
   30-minute drive and `os_log`.
2. **The relay is a single point of failure; cell coverage is not a constant.**
   `RelaySocket`'s reconnect policy was written for a phone that will be looked at again
   soon. A car needs it aggressive and silent — `ConnectionHealth` probably needs a
   car-specific timeout profile.
3. **Speaking `lastQuestion` verbatim.** Claude's prose is full of paths, flags and code
   spans; read aloud it is unintelligible. A `carSpokenSummary` on `SessionRow` — strip
   code spans, cap around 15 words — is not polish, it is the difference between usable
   and not. It is also pure Foundation, so it belongs in `BridgeModels.swift` and is
   directly testable by `tests/run.sh`.
4. **Approving something you could not see.** The dangerous case is Claude asking to run
   something destructive and you saying "approve" off a one-line summary. Refuse voice
   approval when `dialogOptions` is empty or the question trips a destructive-pattern
   check, and answer "that one needs your eyes." Also pure Foundation, also testable.
5. **Two cars, two head units.** Screen size, wheel-button mapping and whether Siri
   announcements come through at all differ between them. Test both before believing any
   of this.
6. **App Store.** Track A ships with no CarPlay review at all. Track B without the
   entitlement is dead code in the binary — strip the entitlement from Release configs
   until it is granted, or the upload gets rejected.
