# KeyPoint OSC: capability spike

Step 0 of the project brief. Tested 2026-10-25 on macOS 26 (Darwin 25.6), Apple Silicon, with **Keynote 14.3** and **PowerPoint for Mac 16.106**.

Throwaway scripts are in `spike/keynote/` and `spike/powerpoint/` (`make_deck.applescript` builds a test deck; `probe.sh` runs one AppleScript snippet inside a `tell` block and prints wall-clock ms). Test decks: `spike/keynote/KeyPointTest-builds.key` and `spike/powerpoint/KeyPointTest.pptx`. Both have a hidden/skipped slide 3, UTF-8 notes, builds on slide 2 and a movie on slide 4. The PowerPoint deck also has two sections.

Legend: **works** = native AppleScript, reliable. **partial** = works with a caveat or workaround. **UI** = needs System Events (Accessibility permission): keystrokes or menu clicks. **no** = not exposed.

## Results

| Capability | PowerPoint Mac | Keynote |
|---|---|---|
| Start / stop show (from slide N) | **works**: set `slide show settings` (`range type` = `slide show range`, `starting slide`, `ending slide`) then `run slide show` (~200 ms). `exit slide show (slideshow view of slide show window 1)`. Works on any open presentation, not only the active one. | **works**: `start doc from slide N`, `stop doc` (~670 ms). `start` brings Keynote to the front. Starting on a skipped slide lands on the previous visible slide. |
| Next / previous (including builds) | **works**, in the background too: `go to next slide` / `go to previous slide` on the slideshow view. Both step one build at a time and skip hidden slides. | **partial**: `show next` steps through builds (verified: 3 builds took 6 presses because of build order), and `show previous` reverses. **Both fail when Keynote isn't frontmost** (`No window`, -1708). Workaround: `activate` and retry (~750 ms, steals focus). |
| Go to slide N | **partial**: `go to slide view number N` always fails with a parameter error (-50), even as a raw Apple event, so it looks like a dictionary bug. `go to first slide` / `go to last slide` work. Workarounds: (a) exit, select slide N in the editor (`go to slide (view of document window 1) number N` works there), then click menu *Slide Show > Play from Current Slide* (UI, ~200 ms + exit, works in the background, keeps the full deck playable, editor flashes briefly, English menu title); (b) restart with range N..end (no UI, ~280 ms, but slides before N become unreachable). Typing N + Return does **not** jump on Mac. | **works**, in the background too: `show slide N of doc` during a show (N = real index). In edit mode: `set current slide of doc to slide N`. |
| Current slide number during show | **works**: `slide index of slide of slideshow view` = real index. | **partial**: `slide number` is the **position among visible slides**, in play and edit mode, and `-1` for a skipped slide. The backend must map it using `skipped of every slide`. The `current slide` object itself is right. |
| Total slide count, hidden slides | **works**: `count of slides`. `hidden of slide show transition of slide i`, read per slide (the `every slide` form returns `missing value`). | **works**: `count of slides`, `skipped of every slide` (read/write). Avoid `whose skipped is true`: it returns the `-1` numbers. |
| Build position / count / remaining | **partial**: count = `count of effects of main sequence of timeline of slide` (3 on the test slide; `print steps` = 4). Position isn't exposed, so it has to be counted from our own next/previous calls while the slide index doesn't change. Effects set to "with/after previous" make the count differ from clicks; to verify. | **no**: builds aren't in the dictionary. Position can be counted from our own `show next` calls, but there's no total. A future route is parsing the `.key` (IWA) file. |
| Presenter notes text | **works**: `content of text range of text frame of place holder 2 of notes page of slide`. UTF-8 round-trips. | **works**: `presenter notes of slide`. UTF-8 round-trips. |
| Sections | **works**: `section properties` of the presentation: `get count of sections`, `get name / first slide / slide count of section sp at position k`, `section index of slide`. | **no**: Keynote has no sections. |
| Black / white screen | **works**: `set slide state of view to slide show state black screen / white screen`. Reading `slide state` reports it reliably, in the background too. | **UI**: `b` / `w` keystroke toggles (138 ms), Keynote frontmost. State can't be read back. After `b`, the next `show next` only un-blanks. |
| Pause / resume auto-advance | **partial**: `slide state` has `paused` and can be read, but setting `running` from black/white/paused went to `paused`, not `running`. Navigation still works while "paused". Resume semantics need a test on an auto-advancing deck. | **UI / unverified**: no command. Doc-level `auto play`, `auto loop`, `auto restart` are read/write. |
| Laser pointer | **no**: pointer types are none/arrow/pen/always hidden only. | **no** |
| Media play / pause / seek / position | **works** (duration: read from the saved .pptx, see below), in the background too: `get player from view for (shape k of slide of view)`, then `play player`, `pause player`, `stop player`, `player state`, `current position` (ms, read/write), `go to next/previous bookmark for player`. The shape must come from `slide of view`; a `slide N of presentation` reference gives -50. Player is `not ready` until first played. **Duration is not exposed** (needs another source, e.g. reading the media file with AVFoundation). | **no** via scripting (`movie` exposes file name, volume, repeat only). Keyboard shortcuts at most, with no position readback; not tested. |
| Open / close / activate documents | **partial**: `open POSIX file`, `close presentation "name" saving no`, `name` / `full name` / `path` / `saved` of every presentation all work. **Switching the active presentation doesn't work** (`activate document window` returns after ~2 s with no change). Show-related actions can target a presentation by name, so this matters little. After `save p in`, the old reference `p` goes stale (-1728). | **works**: `open POSIX file`, `close doc saving no`, `name`/`id`/`file`/`modified`, raise via `set index of window`. |
| Detect "show running" without polling hacks | **partial**: `count of slide show windows` > 0, plus `slide state` (running / paused / black / white / done). No events, so it has to be polled. | **partial**: hidden app property `playing`. No events, so it has to be polled. |
| Behavior when the app is not frontmost | **works**: everything above, including next/previous and media, ran with Finder frontmost. | **partial**: reads, `show slide N`, `start`, `stop` work. `show next`/`previous` fail. Keystrokes need focus. |

## Timing

| | PowerPoint | Keynote |
|---|---|---|
| Simple read (osascript round trip, includes process launch) | 95-170 ms | 85-125 ms |
| Combined show-state read | ~150-220 ms | ~110 ms |
| Next / previous | ~110 ms | ~90 ms (frontmost) / ~750 ms (activate + retry) |
| Start / stop show | ~200 ms / ~120 ms | ~100 ms / ~670 ms |

In-process NSAppleScript or ScriptingBridge from the Swift app should be faster than `osascript`; to be measured in phase 2. A 250-500 ms poll with one combined script per tick is affordable for both.

## Implications for the design

1. **PowerPoint is the stronger backend**, not Keynote as the brief guessed: native black/white, media, sections, build counts, and background-safe navigation. Consider swapping phases 3 and 4.
2. **Keynote index mapping is mandatory**: visible-ordinal ↔ real index via `skipped of every slide`.
3. **PowerPoint go-to-slide needs a workaround**: the menu route (preferred, behind the Accessibility opt-in) with restart-at-N as the no-permission fallback. Report the method in the capability list.
4. **Build position is ours to track** in both backends (count our next/previous calls, reset when the slide changes). Mark it "estimated" if someone clicks on the Mac.
5. **UI-scripting features** (Keynote black/white, PowerPoint go-to via menu) go behind one "Accessibility features" opt-in. Never send keystrokes unless a show window is confirmed to exist. During this spike, keystrokes sent while no show was running went to the editor; they did no harm this time, but the risk is real.
6. **Unsupported** (reported in the capability list so Companion can grey them out): Keynote sections, build counts and media. Laser pointer on both. PowerPoint media duration (unless added from the file).
7. **Permissions seen**: Automation prompt per target app on first use. Accessibility for UI features. Screen Recording not needed.
8. **Sandboxing**: both apps refused some saves to a scripted location (Keynote's in-place save failed with "could not be saved"; a first PowerPoint save silently didn't write). The helper app shouldn't depend on the presentation apps writing files.

## Decisions (from the user, 2026-10-25)

- **Companion usually runs on another machine**: listen on all interfaces (configurable bind address), document the macOS firewall prompt, and send feedback to a configurable remote host (default: the source address of the last incoming packet, as an option).
- **Auto-detect the backend**: prefer whichever app has a show running. If both or neither, use the most recently active, with a manual override in the menu.

## Findings while building (2026-10-25)

These came up during implementation and are handled in the backends:

- **NSAppleScript must be compiled on the main thread.** A script created and compiled on a background thread intermittently loses Apple event replies: 19 of 60 calls hung until they timed out. Compiled on the main thread and executed on a background queue: 0 of 300. `AppleScriptRunner` does this.
- **Per-event cost**: PowerPoint takes about 50 ms per Apple event. A full poll (presentations, slide, state, notes, build count, media) is about 350 ms. During a show the backend runs a cheap poll (slide, state, media) at about 66 ms per tick, and runs the full poll only when the slide changes or every 2 s. Next/previous: about 85 ms.
- **PowerPoint scripting quirks**:
  - `repeat with p in presentations` fails (-2763). Use an index loop.
  - A presentation reference obtained via `presentation of slide show window 1` dies when the show window closes (-1728). Look it up by name instead.
  - `run slide show` right after `exit slide show` is ignored until the old show window is gone, so the scripts wait for it and retry once.
  - `make new presentation` returns a reference that `save … in` silently ignores. Saving by name works.
  - Turning black/white off with `set slide state … running` returns to running (the spike's "goes to paused" didn't reproduce).
  - Opening a file that is a byte-for-byte copy of an already-open deck fails with -9074. Opening right after closing the same file was ignored once.
- **AppleScript name clashes**: `x` (a PowerPoint animation property), `st` (the ordinal suffix, as in `1st`), and `before`, `after`, `last` are reserved. The compile tests catch these.
- **Keynote reports the new slide about 100 ms after `show next` returns**, so the step script waits 150 ms before reading it back. Otherwise build counting is off by one.
- **Keynote build position after stepping back** onto a slide is unknown (no build count), so it isn't reported until the slide changes again.

## Still to verify

- [x] With Accessibility granted (verified 2026-10-25): PowerPoint go-to-slide via *Play from Current Slide* keeps the whole deck reachable; presentation switching via the Window menu works once PowerPoint is brought to the front (it ignores the menu while in the background); Keynote black/white key presses work (confirmed on screen).
- [ ] PowerPoint: build counts with "with/after previous" effects; resume from `paused` on an auto-advancing deck.
- [x] PowerPoint media duration (verified 2026-10-27). KeyPoint reads the .pptx: the slide order comes from `presentation.xml`, then the first top-level `p:pic` with media in `spTree`. It uses the `p14:media` r:embed (or the link), extracts the clip with `unzip`, and gets its length from AVFoundation (about 0.7 s for a 224 MB clip). `p14:trim st/end` is the time cut from the start and the end. PowerPoint's `current position` counts from the trimmed start and stops at the trimmed length (tested: a 59078 ms clip trimmed 10000/20000 stopped at 29078). A new file opened by script triggers PowerPoint's sandbox *Grant File Access* dialog.
- [ ] Keynote: movie keystrokes, and pause on a self-playing show.
- [ ] Both: presenter view / two-screen setups.
- [ ] Both: non-English UI (menu titles used by UI fallbacks).
- [ ] Compatibility with the Zinc: OSCPoint Companion module (phase 5).
