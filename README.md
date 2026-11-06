# KeyPoint OSC

A macOS menu-bar app that lets Bitfocus Companion, or any OSC client, control PowerPoint for Mac and Keynote slide shows and receive feedback from them.

It comes with its own Companion module, [companion-module-rustedroof-keypoint-osc](https://github.com/BasilChessman/companion-module-rustedroof-keypoint-osc). It also accepts the OSCPoint address space (`/oscpoint/...`), so the Zinc: OSCPoint module keeps working. KeyPoint OSC is not affiliated with OSCPoint. It's a separate Mac app inspired by it.

- Full action and feedback list, per app: [docs/osc.md](docs/osc.md)
- What PowerPoint and Keynote expose, and the workarounds used: [docs/capabilities.md](docs/capabilities.md)

**Download:** see the [install guide](docs/INSTALL.md) for the ready-to-run app and Companion module from [Releases](https://github.com/BasilChessman/KeyPoint-OSC/releases). Building from source is only needed for development.

## Features

With the KeyPoint OSC Companion module, you can:

- Run a show from Companion: next/previous, go to a slide or section, start and end the show, black or white screen, and pause.
- Show live show info on buttons: slide counter, slides remaining, builds, notes, section, and media time remaining (in Keynote, only an [estimate](#keynote-media-time-is-an-estimate)).
- Use PowerPoint and Keynote. KeyPoint picks the app with a show running, or you can fix the choice.
- Control several Macs from one Companion, with one connection per Mac.
- Time Keynote movies that start on a click from your clicker: one plugged into the Mac ([clicker keys](#clicker-on-this-mac)) or a DSAN PerfectCue ([bridge](#perfectcue-clicker)).
- Use ready-made presets: navigation, show control, info displays, a media countdown that turns amber at 30 s and red at 10 s (and shows ≈ when estimated), app selection, and clicker on/off.

Items marked (PowerPoint) don't work in Keynote. See [What works in each app](#what-works-in-each-app).

### Actions

| Action | Options |
|---|---|
| Next / Previous (slide or build) | |
| Go to slide | Slide number. PowerPoint restarts the show at that slide, with a brief flicker. |
| Go to first slide / Go to last slide | |
| Go to section (PowerPoint) | Section name (case sensitive) |
| Hide / unhide slide | Slide number, hide or unhide |
| Start slide show | From slide (0 = the beginning) |
| Start slide show from current slide | |
| Start slide show from section (PowerPoint) | Section name |
| End slide show | |
| Black screen / White screen | On, off or toggle |
| Pause / resume auto-advance (PowerPoint) | Pause or resume |
| Media: play / pause / stop (PowerPoint) | Play/pause toggle, play, pause or stop. Acts on the first video or audio item on the slide. |
| Media: seek (PowerPoint) | Forward by, back by, to a position from the start, or to a position before the end (ms) |
| Media: seek to percent (PowerPoint) | 0–100 |
| Media: next / previous bookmark (PowerPoint) | Next or previous |
| Switch to open presentation | File name. PowerPoint needs Accessibility. |
| Select app | Automatic, PowerPoint or Keynote |
| Files: set active folder | Folder, relative to the home folder on the Mac |
| Files: refresh file list | |
| Files: open presentation | File name in the active folder |
| Files: close presentation | File name (empty = the active presentation). For unsaved changes: don't close, discard them, or save first. |
| KeyPoint: enable / disable OSC actions | While disabled, KeyPoint ignores everything except "enable". |
| Clicker keys: listen / stop (Keynote) | Listen, stop or toggle. Keys are learned in the KeyPoint menu. See [Clicker on this Mac](#clicker-on-this-mac). |
| PerfectCue bridge: listen / stop (Keynote) | Listen, stop or toggle, with optional bridge host and port. See [PerfectCue clicker](#perfectcue-clicker). |
| KeyPoint: refresh feedback | Resends all values |

The file actions only work after **Allow file open/close over OSC** is turned on in the KeyPoint menu on the Mac.

### Feedbacks

| Feedback | Options | Default style |
|---|---|---|
| Connected to KeyPoint | | Green |
| Slide show state | Show running (or paused), running, paused, not in a show | Green |
| Black / white screen is on | Black or white | Red |
| Current slide is | Slide number | Green |
| Current slide has builds remaining | | Amber |
| On the last visible slide | | Amber |
| Current section is (PowerPoint) | Section name | Green |
| Current presentation is | File name | Green |
| App in use | PowerPoint, Keynote, none open | Green |
| Media state | Playing, paused, stopped (Keynote: estimated) | Green |
| Media time remaining at or below (ending soon) | Seconds remaining, only while playing | Red |
| Media time is an estimate (Keynote) | | Amber |
| Clicker keys | Listening, on, or on but missing Input Monitoring | Green |
| PerfectCue bridge | Connected, on, or on but not connected | Green |
| Current app supports | A feature, for example media control, sections, black/white screen. Use it to grey out buttons the app in use can't do. | Green |
| File access is enabled on the Mac | | Green |

### Variables

Use these as `$(keypoint:name)`, with your connection's label in place of `keypoint`.

| Variable | Value |
|---|---|
| `connected` | Connected to KeyPoint (true/false) |
| `version` | KeyPoint OSC version |
| `app` | App in use (`powerpoint`, `keynote`, `none`) |
| `presentation_name` | Presentation file name |
| `presentations` | Open presentations, comma separated |
| `slide_count` | Number of slides |
| `slide_count_visible` | Number of slides, not counting hidden ones |
| `show_state` | `edit`, `running` or `paused` |
| `current_slide` | Current slide number |
| `slides_remaining` | Visible slides after the current one |
| `build_position` | Builds shown on the current slide |
| `build_count` | Clicks the current slide's builds take |
| `build_remaining` | Build clicks left on the current slide |
| `notes` | Presenter notes of the current slide |
| `section_index` | Current section number (PowerPoint) |
| `section_name` | Current section name (PowerPoint) |
| `section_slides_remaining` | Visible slides left in the section. Keynote has no sections, so there it's the same as `slides_remaining` |
| `overlay` | Black/white screen (`none`, `black`, `white`) |
| `media_state` | `playing`, `paused`, `stopped`, `notready` (Keynote: estimated) |
| `media_position`, `media_position_display` | Media position in ms, and as m:ss (Keynote: estimated) |
| `media_duration`, `media_duration_display` | Media length after trimming, in ms and as m:ss |
| `media_remaining`, `media_remaining_display` | Media time remaining, in ms and as m:ss (Keynote: estimated) |
| `media_estimated` | Media values are an estimate (true for Keynote) |
| `keyboard_enabled`, `keyboard_permission` | Listening for clicker keys is on; Input Monitoring is granted |
| `perfectcue_enabled`, `perfectcue_connected` | Listening to a PerfectCue bridge is on; connected to it |
| `files_enabled` | File access enabled on the Mac (true/false) |
| `active_folder` | Active folder for the file actions |
| `files` | Presentations in the active folder, after "Files: refresh file list" |
| `last_event` | Last event from KeyPoint, for example `slideshow_begin` |

### What works in each app

| | PowerPoint | Keynote |
|---|---|---|
| Next / previous, first / last, go to slide | ✅ | ✅ |
| Sections (go to, start from, variables) | ✅ | — |
| Black / white screen | ✅ | ✅ (needs Accessibility) |
| Pause / resume auto-advance | ✅ | — |
| Media play / pause / stop / seek | ✅ | — |
| Media length and time remaining | ✅ from the saved file | ⚠️ estimate only, see below |
| Build count and builds remaining | ✅ from the saved file | ✅ from the saved file |
| Notes, slide counts, slides remaining | ✅ | ✅ |

PowerPoint doesn't report a video's length, so KeyPoint reads it from the saved file, including any trims. Save the deck after adding or trimming a video.

Builds are counted in clicks. Neither app reports which builds wait for a click, so KeyPoint reads that from the saved file too: an animation or build set to run with or after the previous one doesn't add to the count. Save the deck after changing builds. If the file doesn't match the open deck (in Keynote, any unsaved change), PowerPoint counts every effect and Keynote leaves the count out. For the OSC addresses behind all of this, see [docs/osc.md](docs/osc.md).

### Keynote media time is an estimate

> **Keynote's media position, state and time remaining are estimates, not live readings.** Keynote doesn't tell other apps whether a movie is playing or how far it has got. KeyPoint reads the saved `.key` file to work out *when* the movie should start and how long it plays, then runs its own countdown. It never checks what Keynote is actually doing, so the countdown can be wrong. Don't use it where an exact cue matters.

**When the countdown starts.** KeyPoint reads the slide's build order from the saved file and starts counting when the movie's **Start Movie** build runs:

- **Plays when the slide appears** (Start Movie set to *After Transition*): after the transition, plus any delay.
- **Start movie on click** (Start Movie set to *On Click*): when that click is sent **through KeyPoint**, for example by a Companion "Next" button. Until then the movie shows `notready`, with the full length remaining.
- **Part of a build sequence** (*After Build N* or *With Build N*): KeyPoint adds up the clicks, delays and build durations before it. For example: on the second click, 1 s after a 0.5 s build.
- **No Start Movie build**: when the movie builds in, or else when the slide appears.

Trims made in Keynote (Format > Movie > Edit Movie > Trim) are applied, so the countdown covers only the part that plays. **Play movie across slides** carries the countdown over to the next slide when the same movie is on both.

**The countdown is wrong, or never starts, when:**

- **Clicks KeyPoint doesn't see.** By default KeyPoint only knows about its own next/previous. A press on a clicker, keyboard or mouse on the Mac isn't seen, so a movie waiting for a click never starts counting and build-based timing on that slide is off. Two ways to fix that: [listen for clicker keys](#clicker-on-this-mac) on this Mac, or listen to a [PerfectCue bridge](#perfectcue-clicker). Mouse clicks are never seen.
- **The movie is paused, skimmed or restarted on the Mac.** KeyPoint doesn't see this and keeps counting.
- **You step back onto a slide.** Which builds have run isn't known, so the movie shows `notready` until you leave the slide and come back forwards.
- **The deck has changed since it was last saved.** KeyPoint reads the saved file. If the slide count differs, or the slide's movie isn't in the saved file, it falls back to starting when the slide appears and doesn't apply trims. Save before the show.
- **The slide has more than one movie or audio clip.** KeyPoint times each one and reports one at a time: the one that started most recently while it plays, otherwise the next one still waiting to start (as `notready`, with its full length), and once all have finished, the last one. Overlapping movies show only the newest. Without a usable saved file they all count from the slide appearing, and the first one is shown.
- **Keynote's file format changes.** The timing comes from Keynote's undocumented file format (tested with Keynote 14.3). If a future version can't be read, KeyPoint falls back to starting when the slide appears.

### Clicker on this Mac

Most presentation clickers plug into the Mac (USB receiver or Bluetooth) and act as a keyboard: Forward sends a key such as Page Down or →, Back a key such as Page Up or ←. With **Listen for clicker keys** on, KeyPoint watches for those keys and counts each one like its own next/previous, so Keynote movies that start on a click or after a build are timed from the clicker.

- **Needs Input Monitoring.** Turn on **Listen for clicker keys** in the menu, click **Allow…** next to Input Monitoring, and turn on KeyPoint OSC in System Settings > Privacy & Security > Input Monitoring. If it still doesn't listen, quit and reopen KeyPoint OSC.
- **Listen only.** KeyPoint never blocks, changes or stores key presses. It compares each key with the clicker keys and counts it only if the key went to Keynote (the app being controlled) during a show. Typing in another app isn't counted.
- **Default keys** are the ones Keynote uses: Forward = Page Down, →, ↓, Space, Return; Back = Page Up, ←, ↑, Delete. A Shift-held version counts too (Keynote uses Shift to skip builds).
- **Learn your clicker's keys** if it sends something else (some send F5, Tab or a letter): click **Learn** next to Forward or Back, then press that clicker button. Esc cancels. Do this outside a show, as the press also goes to whatever app is in front. A learned key moves from the other list if it was there. Right-click a key list to remove a key; **Reset keys to defaults** puts the defaults back.
- **The keyboard counts too.** KeyPoint can't tell a clicker from the Mac's own keyboard, so pressing → on the keyboard during a show counts as Forward. That's usually what you want: it moves Keynote as well.
- **Each press is matched to the show after the fact**, as with the PerfectCue: KeyPoint compares the slide before and after to tell a build step from a slide change.
- Also switchable over OSC: `/keypoint/keyboard/enable`, `/keypoint/keyboard/disable`. Learning keys is only possible on the Mac.

A PerfectCue base station plugged into this Mac sends its presses as keys too. If KeyPoint also listens to a PerfectCue bridge, the same press arrives twice; presses from the bridge and the keyboard in the same direction less than a second apart count once.

### PerfectCue clicker

If the show is advanced with a DSAN PerfectCue, KeyPoint can listen to a [PerfectCue bridge](https://github.com/BasilChessman/perfectcue-bridge), which reports every Forward and Back press on the PerfectCue bus. KeyPoint counts those presses like its own next/previous, so Keynote movies that start on a click or after a build are timed from the clicker. The press still reaches Keynote the usual way, through the base station's USB keystroke; KeyPoint only listens and never sends anything to the bridge. Presses sent from Companion's PerfectCue module also count, because they fire the same keystroke.

Turn it on in the menu (**Listen to PerfectCue bridge**, host `perfectcue.local`, port 5100) or over OSC with `/keypoint/perfectcue/enable`. The menu shows whether the bridge is connected; KeyPoint reconnects on its own if the bridge restarts. The bridge accepts up to 4 connections, so it can serve Companion and KeyPoint at the same time.

Things to know:

- **Listen only on the Mac that runs the show.** KeyPoint assumes each press reached its own Keynote. If the base station's USB goes to a different computer, the count is wrong.
- **Each press is matched to the show after the fact.** KeyPoint compares the slide before and after the press to tell a build step from a slide change. Pressing faster than about 5 times a second, or pressing while Keynote is busy with a transition, can be miscounted.
- **One Companion button can do both.** A button that sends KeyPoint's Next *and* the PerfectCue module's Forward reaches KeyPoint twice: as its own next, and as a press from the bridge. KeyPoint counts a next and a press in the same direction less than a second apart as one click. That's right when only one of them actually moves Keynote. If both do, Keynote moves two steps for one count, so have each button use one or the other.
- **Blank presses are ignored.**
- PowerPoint doesn't use the presses: it reports media playback itself.

Timings are also off by a fraction of a second: transitions and builds don't run exactly to the saved durations, and KeyPoint checks the show about 3 times a second (clicks sent through KeyPoint are timed from the command itself).

For a looping movie, the countdown starts again on each pass. A movie that has finished shows `stopped` with 0 remaining. Media controls (play, pause, seek) still don't work in Keynote. Under the KeyPoint format, `/keypoint/slideshow/media/estimated` is `true` while the values are estimates, so clients can label them.

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

   For clicker timing in Keynote, **Input Monitoring** is also needed; see [Clicker on this Mac](#clicker-on-this-mac).
4. If Companion runs on another computer, enter that computer's IP address under **Feedback to**, and leave "This Mac only" off. When macOS asks whether KeyPoint OSC may accept incoming network connections, click **Allow**.

### Companion

Use the **KeyPoint OSC** module ([companion-module-rustedroof-keypoint-osc](https://github.com/BasilChessman/companion-module-rustedroof-keypoint-osc)):

1. Download `rustedroof-keypoint-osc-<version>.tgz` from [Releases](https://github.com/BasilChessman/KeyPoint-OSC/releases), or build it from that repo with `npm install && npm run package`.
2. In the Companion web interface, open **Modules**, choose **Import module package**, and pick the `.tgz`.
3. Add a **KeyPoint OSC** connection. Enter this Mac's IP (shown in the KeyPoint menu as "This Mac"), send port 35551, and a receive port of your choice, different for each KeyPoint connection (0 = any free port).

KeyPoint replies to each module connection at the address and port it sends from (its receive port), so no feedback settings are needed in KeyPoint, several Companion connections and Macs can run side by side, and other modules (including Zinc: OSCPoint) can keep using port 35550. See the module's `companion/HELP.md` for its actions, feedbacks, variables and presets.

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
| Listen for clicker keys | off | Needs Input Monitoring. Forward and Back keys can be learned. Also switchable over OSC (`/keypoint/keyboard/enable`, `/keypoint/keyboard/disable`) |
| Listen to PerfectCue bridge | off, `perfectcue.local` : 5100 | Also switchable over OSC (`/keypoint/perfectcue/enable`, `/keypoint/perfectcue/disable`) |
| Allow file open/close over OSC | off | Can only be turned on here, never over OSC. Anyone who can reach the Mac can then open and close presentations in the active folder. |

## Troubleshooting

- **Nothing happens and the menu icon shows a warning triangle**: Automation was denied. Open System Settings > Privacy & Security > Automation and enable PowerPoint/Keynote under KeyPoint OSC.
- **"Can't listen"**: another app (for example OSCPoint in a VM, or a second copy of KeyPoint) is using port 35551. Change the listen port, or quit the other app.
- **No feedback in Companion**: check the feedback host and port, and that the Companion machine's firewall allows UDP 35550. The **Activity** list in the menu shows errors.
- **Keynote next/previous brings Keynote to the front**: Keynote only accepts these when it's frontmost. Turn off "Allow bringing the app to the front" to stop this; next/previous then fail while Keynote is in the background.
- **PowerPoint go-to-slide flickers**: PowerPoint for Mac can't jump within a running show by script, so KeyPoint restarts the show at that slide. Grant Accessibility so the rest of the deck stays reachable afterwards.
- **Keynote media countdown doesn't match the movie, or stays at `notready`**: it's an estimate based on the saved file and on clicks sent through KeyPoint. Save the deck, and advance with Companion rather than a clicker on the Mac. See [Keynote media time is an estimate](#keynote-media-time-is-an-estimate).
- **Build position looks wrong**: it's counted from KeyPoint's own next/previous commands, plus clicker keys or PerfectCue presses if you turned those on. Other clicks on the Mac aren't seen until the slide changes. Pressing again while a build is still animating may only finish the animation, which KeyPoint can count as a step; the position never goes past the count and is right again on the next slide.
- **Build count is missing or too high**: save the deck. The count of clicks comes from the saved file.
- **Clicker keys aren't counted**: check Input Monitoring in the menu (quit and reopen KeyPoint OSC after granting it), that Keynote is in front during the show, and that the clicker's keys are in the Forward/Back lists (use **Learn**).
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
