# KeyPoint OSC

A macOS menu-bar app that lets Bitfocus Companion, or any OSC client, control PowerPoint for Mac and Keynote slide shows and receive feedback from them.

It comes with its own Companion module, [companion-module-rustedroof-keypoint-osc](https://github.com/BasilChessman/companion-module-rustedroof-keypoint-osc). It also accepts the OSCPoint address space (`/oscpoint/...`), so the Zinc: OSCPoint module keeps working. KeyPoint OSC is not affiliated with OSCPoint. It's a separate Mac app inspired by it.

- Full action and feedback list, per app: [docs/osc.md](docs/osc.md)
- What PowerPoint and Keynote expose, and the workarounds used: [docs/capabilities.md](docs/capabilities.md)

**Download:** see the [install guide](docs/INSTALL.md) for the ready-to-run app and Companion module from [Releases](https://github.com/BasilChessman/KeyPoint-OSC/releases). Building from source is only needed for development.

## How it works

KeyPoint OSC listens for OSC over UDP and drives the presentation apps through AppleScript. It reads the show state a few times a second and sends feedback when something changes. It picks the app automatically: the one with a show running, otherwise the one used most recently. You can also fix the choice in the menu. It never launches an app on its own.

## Requirements

- macOS 14 or later
- PowerPoint for Mac (tested with 16.106) and/or Keynote (tested with 14.3)

## Setup

1. Build the app (see below) and open `build/KeyPoint OSC.app`. A slides icon appears in the menu bar.
2. The first time it talks to PowerPoint or Keynote, macOS asks whether KeyPoint OSC may control that app. Click **OK**. To change this later, use System Settings > Privacy & Security > Automation.
3. Optional but recommended: in the menu, under **Permissions**, click **Allow…** next to Accessibility and turn on KeyPoint OSC. This enables:
   - PowerPoint: go to slide N with the whole deck still reachable afterwards, and switching between open presentations.
   - Keynote: black and white screen.
4. If Companion runs on another computer, enter that computer's IP address under **Feedback to**, and leave "This Mac only" off. When macOS asks whether KeyPoint OSC may accept incoming network connections, click **Allow**.

### Companion

Use the **KeyPoint OSC** module ([companion-module-rustedroof-keypoint-osc](https://github.com/BasilChessman/companion-module-rustedroof-keypoint-osc)):

1. Build the package from that repo: `npm install && npm run package`. This creates `rustedroof-keypoint-osc-0.1.0.tgz`.
2. In the Companion web interface, open **Modules**, choose **Import module package**, and pick the `.tgz`.
3. Add a **KeyPoint OSC** connection. Enter this Mac's IP (shown in the KeyPoint menu as "This Mac") and leave the port at 35551.

KeyPoint answers the module directly at the address and port it sends from, so the module needs no feedback settings, and other modules (including Zinc: OSCPoint) can use port 35550 at the same time. See the module's `companion/HELP.md` for its actions, feedbacks, variables and presets.

**Zinc: OSCPoint module** (still supported): point it at this Mac, port 35551, feedback port 35550. In the KeyPoint menu, set **Feedback to** to the Companion computer's IP, and **Feedback format** to **OSCPoint compatible**.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Accept OSC actions / Send OSC feedback | on | Also switchable over OSC (`/oscpoint/actions/enable`, …) |
| Listen port | 35551 | 1024–65535 |
| This Mac only | off | Listen on 127.0.0.1 only |
| Feedback to | 127.0.0.1 : 35550 | Host and port for feedback |
| Also send feedback to the last controller | on | For OSCPoint-style clients (KeyPoint module connections are always answered) |
| Feedback format | KeyPoint | Format for "Feedback to" and the last controller: KeyPoint (`/keypoint/...`) or OSCPoint compatible (`/oscpoint/...`) |
| App | Automatic | Automatic, PowerPoint or Keynote |
| Use Accessibility features | on | See Setup step 3 |
| Allow file open/close over OSC | off | Can only be turned on here, never over OSC. Anyone who can reach the Mac can then open and close presentations in the active folder. |

## Troubleshooting

- **Nothing happens and the menu icon shows a warning triangle**: Automation was denied. Open System Settings > Privacy & Security > Automation and enable PowerPoint/Keynote under KeyPoint OSC.
- **"Can't listen"**: another app (for example OSCPoint in a VM, or a second copy of KeyPoint) is using port 35551. Change the listen port, or quit the other app.
- **No feedback in Companion**: check the feedback host and port, and that the Companion machine's firewall allows UDP 35550. The **Activity** list in the menu shows errors.
- **Keynote next/previous brings Keynote to the front**: Keynote only accepts these when it's frontmost. Turn off "Allow bringing the app to the front" to stop this; next/previous then fail while Keynote is in the background.
- **PowerPoint go-to-slide flickers**: PowerPoint for Mac can't jump within a running show by script, so KeyPoint restarts the show at that slide. Grant Accessibility so the rest of the deck stays reachable afterwards.
- **Build position looks wrong**: it's counted from KeyPoint's own next/previous commands. Clicking on the Mac itself isn't seen until the slide changes.
- **Logs**: `log stream --predicate 'subsystem == "org.keypointosc.KeyPointOSC"'`

## Building

Needs Swift 6 (Xcode or the Command Line Tools).

```sh
scripts/build-app.sh          # builds and ad-hoc signs build/KeyPoint OSC.app
scripts/test.sh               # unit tests (works without Xcode)
KEYPOINT_LIVE=1 scripts/test.sh --filter Live   # times polls against the running PowerPoint
```

Run `scripts/make-dev-cert.sh` once to create a self-signed "KeyPoint OSC Development" signing identity in the login keychain. `build-app.sh` uses it automatically, so Accessibility and Automation permissions survive rebuilds; with ad-hoc signing they're lost on every build. To publish a release (universal app plus Companion module, on GitHub Releases): `scripts/release.sh` (or `--dry-run` to only build). For notarized distribution, sign with a Developer ID (`SIGN_ID="Developer ID Application: …" scripts/build-app.sh`) and notarize.

Development tools:

```sh
swift build --product oscsend
.build/debug/oscsend --listen 35550 /oscpoint/feedbacks/refresh      # print all feedback
.build/debug/oscsend /oscpoint/goto/slide 4
.build/debug/oscsend /oscpoint/goto/section "b:Médias"                # b: = UTF-8 blob
KEYPOINT_TRACE=1 ".build/debug/KeyPointOSC" --bench next              # time backend calls
```

## Layout

| Path | Contents |
|---|---|
| `Sources/KeyPointCore` | OSC codec, UDP, router, feedback publisher, engine, settings (no app-specific code) |
| `Sources/KeyPointBackends` | `PowerPointBackend`, `KeynoteBackend`, AppleScript runner, Accessibility helpers |
| `Sources/KeyPointApp` | SwiftUI menu-bar app |
| `Sources/oscsend` | OSC send/receive CLI for testing |
| `spike/` | Step 0 capability-spike scripts and test decks |

## License

MIT. See [LICENSE](LICENSE).
