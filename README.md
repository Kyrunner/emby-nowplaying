# Emby Now Playing — Omarchy bar widget

Who is watching Emby, and **whether the server is transcoding for them**. It also sends
per-session transport commands (play/pause, seek, skip, stop, volume).

Quiet when the server is reachable and nobody is watching. A *fault* stays visible and worded, because a
hidden widget and a broken widget must not look the same.

"Not yet" is not a fault. The bar starts about ten seconds before WiFi associates, so the first poll of every
boot fails. While a poll is failing the widget retries every **5s** and says nothing; it reports a fault only
after **45s of continuous failure**, and one success resets that clock. So a boot is quiet, a network blip is
quiet, and a genuinely dead server still speaks up within a minute.

This is a minimal port of [jellyfin-nowplaying](https://github.com/Kyrunner/jellyfin-nowplaying) (MIT).
Where Emby's documented API differs, the difference is called out below rather than papered over.
Checked on the owner's LAN against Emby 4.10.1.0: `backend.sh` with a real API key returned `ok` and
`streams: []` (22 idle sessions). A wrong token is `auth failed`, a missing config file is
`not configured`, a config with no token is `bad config`, and a closed port is `unreachable`, each
with exit 1. What that run did not cover is listed at the end.

## Configure

`~/.config/omarchy-emby/config.json`, mode 600. Override the path with `OMARCHY_EMBY_CONFIG`.

```json
{ "url": "http://<emby-host>:8096", "token": "<emby api key>" }
```

`url` is the server origin (Emby's default port is 8096). The plugin appends `/emby` itself, and sends the
key in the `X-Emby-Token` header. It does not put the key in a query string.

Use a **dedicated** Emby API key. The published guide
([API-Key Authentication](https://dev.emby.media/doc/restapi/API-Key-Authentication.html)) creates one at
Dashboard → Expert → Advanced → Security → Add. On the owner's 4.10 server the same screen is
Dashboard → Advanced → API Keys. A separate key means revoking this machine's access never breaks anything else.

## Install on a new machine

Requires Omarchy 4 ("Quattro", Quickshell bar).

```bash
# 1. Drop the plugin in place (dir name MUST be the manifest id)
mkdir -p ~/.config/omarchy/plugins
cp -r emby-nowplaying ~/.config/omarchy/plugins/ky.emby-nowplaying

# 2. Config — mode 600, outside the plugin dir so the token is never in the repo
mkdir -p ~/.config/omarchy-emby
cat > ~/.config/omarchy-emby/config.json <<'EOF'
{ "url": "http://<emby-host>:8096",
  "token": "<dedicated emby api key>",
  "web_base": "https://<public-emby-url>",
  "public_url": "https://<public-emby-url>" }
EOF
chmod 600 ~/.config/omarchy-emby/config.json

# 3. Prove the data layer BEFORE touching the bar — this is why backend.sh exists
bash ~/.config/omarchy/plugins/ky.emby-nowplaying/backend.sh

# 4. Register it on the bar
#    Add {"id": "ky.emby-nowplaying"} to bar.layout.right in ~/.config/omarchy/shell.json
#    shell.json hot-reloads on save. Reposition later with:
#    omarchy bar move ky.emby-nowplaying --section right
```

- **`web_base` is optional** but drives the click-through; without it the title links to `url` (the LAN address),
  which won't resolve off-network. The link is `{web_base}/web/index.html#!/item?id=…&serverId=…`.
- **`public_url` is optional** and is the API fallback: used only when `url` is unreachable, so the widget keeps
  working away from home. It must be `https://`: the token is never sent to a public address over plain HTTP,
  never follows a redirect, and replies over 4 MiB are refused. It defaults to `web_base`; set it to `""` if
  Emby must never be polled from outside the LAN. The LAN address is always tried first — at 10s polling this widget makes ~8,640 requests a day, and
  pointing that at a public edge with a rate limiter or an IP-ban daemon is how you lock yourself out of your own
  server. After a fallback it stays on the public endpoint for 10 minutes, then re-probes the LAN, so coming home
  restores the fast path on its own. The popup shows `remote` while on that path. A wrong token never fails over
  (a 401 does not try the other address).
- ⛔ **A bar widget goes in `bar.layout.right`, NOT the top-level `plugins[]` array.** The Omarchy skill does not
  mention that array. The Jellyfin plugin's working install does: a bar widget listed in `plugins[]` silently
  never appears, because that array is for overlay plugins. Put the entry in `bar.layout.right`. The manifest's
  `defaultSection` is `right`.
- **Reload follows the Omarchy skill, not the Jellyfin README.** The skill says `shell.json` hot-reloads on save,
  and saving a file under `~/.config/omarchy/plugins/` reloads plugin code. If a change does not apply, run
  `omarchy-shell shell rescanPlugins`. The documented restart is `omarchy restart shell`.
  The Jellyfin README conflicts with this: it says `omarchy-restart-shell` is required, that
  `omarchy-refresh-shell` leaves the running process untouched, and that `Panel.qml` stays as a cached compile
  until that restart. If a QML edit looks like it did nothing, use the skill's rescan and then
  `omarchy restart shell`. Do not edit anything under `/usr/share/omarchy/`.
- ⚠️ **If the widget is invisible with nothing in the logs, the Panel is missing `implicitWidth`/`implicitHeight`.**
  The skill does not mention this. The Jellyfin plugin does, and the failure is silent: the bar allocates zero
  width. `Panel.qml` sets both deliberately; the zero-width case is also how it hides when nobody is watching.
- Icon: `emby.png` / `emby.svg` from dashboard-icons. See Credits.

## Test the backend without the widget

```bash
bash backend.sh                                  # uses the real config
OMARCHY_EMBY_CONFIG=/tmp/other.json bash backend.sh
printf '%s' "$(cat fixtures/sessions.synthetic.json)" | python3 flatten.py   # transform alone
```

Expected shapes:

```
{"ok":true,"error":null,"streams":[…]}          # streams: [] when nobody is watching
{"ok":false,"error":"not configured", …}        # exit 1 — no config file
{"ok":false,"error":"bad config", …}            # exit 1 — file unreadable, or url/token missing
{"ok":false,"error":"auth failed", …}           # exit 1 — the server rejected the token (HTTP 401)
{"ok":false,"error":"unreachable", …}           # exit 1
```

`bad config` and `auth failed` are kept strictly apart. A config mistake reported as an auth failure sends you
to the API Keys screen, where everything looks correct, while the real fault goes unnamed.

A **403 is not `auth failed`.** Emby's reference describes 401 as "client needs to authenticate" and 403 as
"no permission". On 4.10.1.0 a bad or missing API key returned 401, not 403, and the widget reported
`auth failed`. 403 stays `http 403`.

The four suites run with no server and no credentials:

```bash
node Readiness.test.js          # the grace-window decision table
bash backend-config.test.sh     # config parsing, against a stub Emby on localhost
bash state-write-safety.test.sh # what the state writes refuse to follow
bash plain-text.test.sh         # every Text in every .qml renders as plain text
```

## Requirements

Omarchy 4 ("Quattro", Quickshell bar), plus `curl`, `python3` and `sed` — all present on a stock Omarchy
install. Nothing else is pulled in, and the plugin writes nothing outside its own popout except the endpoint
memory under `${XDG_STATE_HOME:-~/.local/state}/omarchy-emby/` (mode 0700).

## Remove

```bash
# 1. Take it out of the bar: delete the {"id": "ky.emby-nowplaying"} entry
#    from bar.layout.right in ~/.config/omarchy/shell.json
# 2. Drop the plugin
rm -rf ~/.config/omarchy/plugins/ky.emby-nowplaying
# 3. Drop the config (this is the file the install creates outside the plugin directory)
rm -rf ~/.config/omarchy-emby
# 4. Reload the bar
omarchy restart shell
```

Endpoint memory, if you also want it gone: `rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-emby"`.

Then revoke the Emby API key (Dashboard → Advanced → API Keys, or Expert → Advanced → Security). Using a
dedicated key is what makes that a one-click action with no side effects.

## Files

| File | Role |
|---|---|
| `manifest.json` | Identity `ky.emby-nowplaying`, `bar-widget` kind, `refreshIntervalSec` setting |
| `backend.sh` | Config + HTTP status handling. The only thing that talks to Emby |
| `emby.py` | Config, `X-Emby-Token`, `/emby` prefix, LAN-then-public, safe state writes |
| `flatten.py` | Turns `/Sessions` into one flat line |
| `EmbyService.qml` | Poll cadence, `Process`, parsed state. No layout |
| `Panel.qml` | Bar button + popout. Presentation only |
| `Readiness.qml` / `.js` | When to poll, and when a failure is old enough to be worth showing |
| `Readiness.test.js` | `node Readiness.test.js` — the grace-window decision table |
| `control.py` | One command to one session. Playstate route and general-command route stay apart |
| `backend-config.test.sh` | Config parsing against a stub server, plus the synthetic fixture |
| `state-write-safety.test.sh` | State writes never follow a planted symlink and refuse a state directory others can write |
| `plain-text.test.sh` | Every Text element in every `.qml` sets `textFormat: Text.PlainText` |
| `fixtures/sessions.synthetic.json` | Synthetic `/Sessions` body. Placeholder names, not a real library |
| `emby.png` / `.svg` | Bar icon and popup header mark |

## Preview image

`preview.png` is a generated placeholder. It is not a screenshot of a running widget and it contains no
library metadata: the words on it are "PLACEHOLDER PREVIEW", "NOT A REAL EMBY LIBRARY", "NO LIBRARY METADATA",
"PLACEHOLDER TITLE" and "PLACEHOLDER VIEWER".

## Credits and trademarks

Icon from [dashboard-icons](https://github.com/homarr-labs/dashboard-icons) (`emby.svg`, `emby.png`),
licensed **Apache-2.0**. Unmodified. Copyright (c) 2024 Bjorn Lammers, Meier Lukas, Thomas Camlong and
Homarr Labs. See `NOTICE`.

The Emby name and logo are trademarks of their owner, used here for identification only. This plugin is not
affiliated with or endorsed by Emby. Plugin code is MIT — see `LICENSE`.

## Where this is not the Jellyfin plugin

Documented against [dev.emby.media](https://dev.emby.media/) (the reference is updated with server releases;
the owner's server is 4.10.1.0). Checked offline only.

- **Base path.** The API is `http[s]://host:port/emby/{apipath}`. `url` is the origin; requests go to
  `{origin}/emby/Sessions` and the rest. An origin that already ends in `/emby` is not doubled.
- **Auth header.** `X-Emby-Token: <key>`. Not `Authorization: MediaBrowser Token="…"`, and not `api_key=`
  on the query. The token is stripped of surrounding whitespace.
- **`/Sessions` shape.** `NowPlayingItem`, `PlayState` (`PositionTicks`, `CanSeek`, `IsPaused`),
  `TranscodingInfo`, `SupportsRemoteControl`. There is **no `SupportsMediaControl` on `SessionInfo`**.
  That flag is on `ClientCapabilities`, which this response does not include. Controllable means
  `SupportsRemoteControl` only. Requiring both, as the Jellyfin plugin does, would grey out every client.
- **Playstate vs general commands.** `POST /emby/Sessions/{Id}/Playing/{Command}` with a `PlaystateRequest`
  body (`PlayPause`, `Stop`, `NextTrack`, `PreviousTrack`, `Seek`). `POST /emby/Sessions/{Id}/Command/{Command}`
  for `VolumeUp`, `VolumeDown`, `ToggleMute` (that reference lists no body). Sending one to the other's path
  404s.
- **Seek is absolute.** The remote-control guide is `POST …/Playing/Seek?SeekPositionTicks=`. The reference
  also takes `SeekPositionTicks` on the `PlaystateRequest` body, so both are sent. The plugin reads a fresh
  `PositionTicks` and clamps to one second short of `RunTimeTicks`. `SeekRelative` (4.8+) treats the same
  field as an offset the **client** interprets; it is not sent, because the docs describe it as something
  each client has to add.
- **Posters on the LAN do not need a token.** The image reference says `GET /Items/{Id}/Images/{Type}`
  requires authentication and lists 401. On 4.10.1.0, `/emby/Items/{id}/Images/Primary?Tag=…&MaxHeight=180`
  returned `200 image/jpeg` with no token, and the same path without the `/emby` prefix did too. The URL
  still carries no credential: QML's `Image` cannot set `X-Emby-Token`, and `api_key=` would put a live key
  in the URL. Public-URL posters were not tried. The URL uses the documented `Tag` and `MaxHeight`
  parameters, the series `Primary` for an episode (`SeriesId` + `SeriesPrimaryImageTag`) and the item's own
  `Primary` otherwise, and the API root that actually answered.
- **Transcoding hardware.** `TranscodingInfo` has no `HardwareAccelerationType`. The badge uses
  `VideoEncoderIsHardware` / `VideoEncoderHwAccel`, then the decoder pair. `TranscodeReasons`, `Bitrate`,
  `VideoCodec`, `AudioCodec`, `IsVideoDirect` and `IsAudioDirect` are the documented fields and are read
  the same way. `MediaStream` documents `VideoRange` and `DisplayTitle`, not `VideoRangeType`.
- **Bad token.** On 4.10.1.0 a bad or missing key was HTTP 401, reported as `auth failed`. 403 stays
  `http 403` (the reference: no permission). Other HTTP statuses stay `http N`. Connection
  failure, timeout and a response that is not JSON stay `unreachable`.

## Transport controls

Each stream gets its own row: previous, −30s, play/pause, +30s, next, stop, and mute/volume down/up.

Controls target the **session**, not the item. Two devices watching the same film are two independent
remotes, which is why the buttons sit per-stream rather than once at the bottom.

- **`controllable` is `SupportsRemoteControl`.** When false the buttons grey out and the panel names the
  client, rather than leaving a dead row to be guessed at.
- **Commands never report their own result.** The next poll is the authority. The confirming poll is
  deferred 400ms, carried over from the Jellyfin port.

```bash
./backend.sh control <session_id> playpause   # next previous stop back30 fwd30 volup voldown mute
```

## Poster artwork

Each stream shows a poster: the **series** poster for an episode, the item's own `Primary` for a film.
Content with no artwork simply shows no thumbnail.

- **No credential is attached to the image URL.** See the image note above.
- **Posters load over the API address that answered, not `web_base`.**

> **QML edits.** The skill says a save under `~/.config/omarchy/plugins/` reloads plugin code. The Jellyfin
> README says `Panel.qml` does not, until `omarchy restart shell`. If an edit does not appear, rescan and
> then restart, as in Install.

## Notes

- **`TranscodingInfo` only appears while Emby is actually transcoding**, so its presence *is* the
  transcode signal — no inferring from codec names. On direct play the bitrate is read from the video
  `MediaStream` instead.
- **Do not gate the poster's `visible` on `status === Image.Ready`.** An `Image` that starts invisible
  at zero layout width is never driven to load, so the status it waits for never arrives and the
  poster silently never appears — with nothing in the logs.
- Colours come from Omarchy's own theme objects, so it follows theme switches with nothing to maintain.
- A failed poll keeps the last known streams and marks them stale rather than blanking.
- The 45s grace window is measured as real elapsed time, accumulated one poll at a time and sanity-checked
  against the delay actually scheduled. It has to be: `systemd-timesyncd` makes its first correction inside
  that very window, and a suspend moves the clock by hours.

## What still needs a live Emby

Verified on the owner's LAN, Emby 4.10.1.0:

- An API key in `X-Emby-Token` is accepted on `GET /emby/Sessions` (200).
- A bad or missing key returns 401, not 403.
- Poster images load with no token. `/emby/Items/{id}/Images/Primary?Tag=…&MaxHeight=180` returned
  `200 image/jpeg`, and the same path without the `/emby` prefix did too. Public-URL posters were not tested.
- `/web/index.html` returns 200, and the item's `ServerId` matches the server id, so the click-through
  format fits. It was not opened in a browser.

Still open:

- Posters over `public_url`.
- Transport controls, seek, and volume, and the 400ms confirm delay.
- The 10-minute public sticky window.
- QML bar rendering and reload behaviour.
