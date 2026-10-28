# OSC reference

Actions are accepted under `/keypoint/...` (used by the KeyPoint OSC Companion module) and `/oscpoint/...` (OSCPoint-compatible clients such as the Zinc: OSCPoint module). The paths after the prefix are the same; this page writes them without the prefix. Actions arrive on UDP port **35551**.

Feedback routing:
- A client that sends `/keypoint/...` messages is answered in KeyPoint format, from port 35551 to the address and port it sent from. It's forgotten after 15 s of silence; the Companion module pings every 3 s.
- The **Feedback to** host and port (default 127.0.0.1:35550), and "the last controller" for `/oscpoint` senders, get the format chosen under **Feedback format** (KeyPoint by default).

Both formats can be in use at the same time.

Text arguments can be an OSC string (ASCII) or a blob holding UTF-8. Numbers can be int or float. Bundles are accepted, and their messages run in order.

Legend: ✅ supported · ⚠️ supported with a caveat · ❌ not supported (ignored and logged)

## Actions

| Address | PowerPoint | Keynote |
|---|---|---|
| `next`, `previous` | ✅ steps builds; works in the background | ⚠️ Keynote is brought to the front if it isn't already (setting "Allow bringing the app to the front") |
| `goto/slide [n]` | ⚠️ restarts the show at slide n. With Accessibility: via *Play from Current Slide*, so the whole deck stays reachable. Without it: the show runs from n to the end. The screen flickers briefly. | ✅ |
| `goto/slide/first`, `goto/slide/last` | ✅ | ✅ |
| `goto/section [name]` | ⚠️ as `goto/slide` | ❌ no sections |
| `slide/hide [n]`, `slide/unhide [n]` | ✅ | ✅ |
| `slideshow/start [n?]` | ✅ (n: as `goto/slide`) | ✅ |
| `slideshow/start/current` | ✅ | ✅ |
| `slideshow/start/section [name]` | ✅ | ❌ |
| `slideshow/end` | ✅ | ✅ |
| `slideshow/black [0/1?]`, `slideshow/white [0/1?]` | ✅ | ⚠️ key press (needs Accessibility); state is tracked by KeyPoint, not read back |
| `slideshow/laserpointer` | ❌ | ❌ |
| `slideshow/pause`, `slideshow/resume` | ✅ | ❌ |
| `media/play`, `pause`, `playpause`, `stop` | ✅ first media item on the current slide | ❌ |
| `media/goto/position/fromstart`, `forward`, `back [ms]` | ✅ | ❌ |
| `media/goto/position/beforeend [ms]`, `percent [0-100]` | ✅ once the clip length is known (see below) | ❌ |
| `media/goto/bookmark/next`, `previous` | ✅ | ❌ |
| `presentations/activate [name]` | ⚠️ needs Accessibility (uses the Window menu) | ✅ |
| `files/setpath`, `list`, `open`, `close`, `close/force`, `close/save` | ✅ needs "Allow file open/close" turned on in the menu on the Mac | ✅ same |
| `actions/enable`, `actions/disable` | ✅ | ✅ |
| `feedbacks/enable`, `disable`, `refresh` | ✅ | ✅ |

Files: the active folder is relative to the home folder (default `Desktop/KeyPoint OSC`). Paths with `..`, `~` or subfolders in file names are rejected. `.pptx`, `.ppt` and `.key` files are listed, and each opens in the matching app. `files/close` refuses to close a presentation with unsaved changes; `close/force` discards them; `close/save` saves over the file first.

## Feedback

Sent only when a value changes. `feedbacks/refresh` (or a new controller connecting) resends everything.

| Address | PowerPoint | Keynote |
|---|---|---|
| `v2/event [type] [args]`: `add_in_startup`, `presentation_open`, `presentation_close`, `window_activate`, `slideshow_begin`, `slideshow_end`, `slideshow_next_slide`, `slideshow_next_build` | ✅ | ✅ |
| `v2/presentations` (JSON array), `v2/presentation` (JSON, string + UTF-8 blob) | ✅ incl. sections | ✅ (`sections` is null) |
| `v2/files/enabled`, `v2/files/activefolder[/fullpath]`, `v2/files` (after `files/list`) | ✅ | ✅ |
| `presentation/name`, `presentation/slides/count[/visible]` | ✅ | ✅ |
| `slideshow/state` (`edit`, `running`, `paused`) | ✅ | ✅ (never `paused`) |
| `slideshow/currentslide`, `slideshow/slidesremaining` | ✅ | ✅ |
| `slideshow/builds/count`, `remaining` | ⚠️ count = number of animation effects (effects set to "with/after previous" make it higher than the number of clicks) | ❌ |
| `slideshow/builds/position` | ⚠️ counted from KeyPoint's own next/previous; clicks made directly on the Mac aren't seen | ⚠️ same; unknown after stepping back onto a slide |
| `slideshow/notes` (ASCII, CR line breaks), `slideshow/notes-utf8` (blob) | ✅ | ✅ |
| `slideshow/section/index`, `name`, `slidesremaining` | ✅ | ❌ |
| `slideshow/media/state`, `position` | ✅ updated about 3 times a second while playing | ❌ |
| `slideshow/media/duration`, `durationtrimmed`, `startpoint`, `endpoint`, `remaining` | ✅ read from the saved file (see below) | ❌ |

Media length (PowerPoint): PowerPoint's scripting doesn't report clip length, so KeyPoint reads it from the saved `.pptx`. It finds the slide's first video or audio item, then measures the embedded copy, or the linked file if it can reach it. This takes up to about a second the first time a slide is shown, and the result is cached until the file is saved again. Trims made in PowerPoint (Playback > Trim) are applied:
- `duration` is the file's length.
- `durationtrimmed` is the length that plays.
- `startpoint` and `endpoint` are the trim points within the file.
- `position` counts from the trimmed start, so `remaining` = `durationtrimmed` − `position`.

There are three limits:
- Unsaved changes to a video aren't seen until the deck is saved.
- `.ppt` files and online videos have no length.
- A linked file that can't be found has no length.

Under `/keypoint`, a slide without media sends `slideshow/media/state ""`. An unknown length sends `""` for the length values, so clients can clear them.

## KeyPoint-only messages

| Address | Direction | Meaning |
|---|---|---|
| `/keypoint/ping` | to KeyPoint | Replies `/keypoint/pong [version]` to the sender |
| `/keypoint/app/select [auto\|powerpoint\|keynote]` | to KeyPoint | Which app to control |
| `/keypoint/app [powerpoint\|keynote\|none]` | feedback | App in use |
| `/keypoint/capabilities [JSON array]` | feedback | What the app in use supports (`navigate`, `gotoSlide`, `sections`, `media`, `blackWhite`, …) |
| `/keypoint/slideshow/overlay [none\|black\|white]` | feedback | Black/white screen state (Keynote: as last set by KeyPoint) |

All other feedback is the same as in OSCPoint format, under `/keypoint/` instead of `/oscpoint/`.
