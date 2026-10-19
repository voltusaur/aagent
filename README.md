# aagent

**Text-first agentic control of an Android device over ADB.**

`aagent` exists because most Android automation tooling assumes the agent can *see*
screenshots. Many LLM harnesses cannot — `view`-style tools return image bytes, but those
bytes never reach the model. Every screenshot-driven mobile agent (mobile-mcp, DroidRun,
Appium-based flows) is therefore blind in those environments.

`aagent` inverts the design: **every read verb returns text plus pixel coordinates.**
Screenshots are still taken, but they are consumed locally by the Windows OCR engine
(`Windows.Media.Ocr`) and reduced to something a language model can actually reason about.

```text
$ aagent ocr
Superuser                                     (144,124)
Obtainium                                     (258,275)
dev.imranr.obtainium                          (314,310)
Revoke                                        (1614,416)
Modules                                       (1542,984)

$ aagent tap "Revoke"
tapped "Revoke" at (1614,416)
```

## Why not uiautomator / Appium / Maestro?

They rely on the accessibility tree. That works for native and most Compose apps, but
**Flutter apps expose nothing** — `uiautomator dump` returns `null root node`. In practice
that means the settings screens of Obtainium, and a growing share of handheld frontends,
are untouchable by those tools.

`aagent` uses OCR as the primary channel, so Flutter, Compose and native all behave the
same. `uiautomator` is still available (`aagent ui`) and preferred when it works, because
its bounds are exact.

## Requirements

- Windows 10/11 (uses the built-in `Windows.Media.Ocr` engine — no network, no API key)
- PowerShell 5.1+
- [`adb`](https://developer.android.com/tools/releases/platform-tools) on `PATH`
  (or installed via `winget install Google.PlatformTools`)
- USB debugging enabled on the device

## Install

```powershell
git clone https://github.com/<you>/aagent.git
cd aagent
# adb must be on PATH; aagent also auto-detects the winget platform-tools location
.\aagent.ps1 devices
```

If script execution is restricted:

```powershell
powershell -ExecutionPolicy Bypass -File .\aagent.ps1 devices
```

## Commands

| Command | Purpose |
|---|---|
| `devices` | list attached devices |
| `shot [path]` | capture a screenshot to disk |
| `ocr [--json] [--filter text]` | read the screen as `text (x,y)` lines |
| `find <text> [--json]` | locate a label; non-zero exit if absent |
| `tap <text> [--retries n]` | tap by label, re-reading the screen on retry |
| `tapxy <x> <y>` | tap a coordinate |
| `type <text>` | type into the focused field |
| `key <KEYCODE>` | send a key event (`BACK`, `ENTER`, `WAKEUP`, …) |
| `swipe <x1> <y1> <x2> <y2> [ms]` | raw swipe |
| `scroll <up\|down> [--until text] [--max n]` | **scroll until a label appears** |
| `wait <text> [--timeout secs]` | block until a label appears |
| `ui` | `uiautomator` dump, falling back to OCR |
| `start <package>` / `stop <package>` | launch / force-stop an app |
| `flow <file.json>` | run a saved sequence |

### Examples

```powershell
# find the settings entry, then open Updates, scrolling until it is visible
aagent scroll down --until "Updates" --max 6
aagent tap "Updates"

# wait for a progress dialog to finish
aagent wait "All done!" --timeout 90

# dump the whole screen as JSON for programmatic use
aagent ocr --json | ConvertFrom-Json | Where-Object { $_.text -like '*Install*' }
```

## Flows

Repeatable sequences live in `flows/*.json`:

```json
[
  { "cmd": "start",  "args": ["dev.imranr.obtainium"] },
  { "cmd": "tap",    "args": ["Settings"] },
  { "cmd": "scroll", "args": ["down", "--until", "Installation method"] },
  { "cmd": "tap",    "args": ["Installation method"] },
  { "cmd": "tap",    "args": ["Root"] }
]
```

```powershell
aagent flow .\flows\obtainium-root.json
```

`stopOnFail` defaults to `true`; set `"stopOnFail": false` on a step to continue past a
failure.

## Limitations

- **Coordinates assume the captures match the swipe geometry.** The `scroll` verb uses
  hard-coded swipe bounds tuned for a 1920×1080 landscape device. Adjust for other
  resolutions.
- **OCR is not free.** Each read captures and recognises a frame (~1–2 s). Prefer
  `wait`/`scroll --until` over repeated `ocr` calls.
- **Text that OCR cannot read cannot be tapped by label.** Fall back to `tapxy`.
- Labels are matched case-insensitively as substrings; when several rows match, the
  top-most is chosen.

## Roadmap

- Device-profile file (resolution, swipe geometry, OCR language)
- Element cache between verbs to avoid repeated captures
- YAML flows
- MCP wrapper so other agents can consume `aagent` as a tool server

## License

MIT © voltusaur
