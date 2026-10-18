#!/usr/bin/env python3
"""Send one command to an Emby session. Prints {"ok":true} or {"ok":false,"error":...}.

Never prints the resulting state: the command is fire-and-confirm, and the next poll
is the authority on what actually happened. A command that reported its own idea of
the result would disagree with the bar the moment the client did something else.

Playback and general commands are DIFFERENT routes on Emby:
    POST /emby/Sessions/<id>/Playing/<PlayPause|Stop|NextTrack|PreviousTrack|Seek>
    POST /emby/Sessions/<id>/Command/<VolumeUp|VolumeDown|ToggleMute|...>
The playstate reference takes a PlaystateRequest body. Seek also accepts
SeekPositionTicks on the query string (remote-control guide). Volume and the
other general commands are the Command route; that reference lists no body.

SeekPositionTicks on the Seek command is an absolute position. Emby 4.8 added
SeekRelative, where the same field is an offset the client interprets. This
plugin keeps absolute Seek: it reads a fresh PositionTicks and computes the
target, then clamps short of the runtime. SeekRelative is not sent, because
the docs describe it as something each client has to implement.
"""

import json
import sys
import urllib.error
import urllib.parse

import emby

SEEK_SECONDS = 30
TICKS_PER_SEC = 10_000_000

# /Sessions/<id>/Playing/<verb>
PLAYING = {
    "playpause": "PlayPause",
    "stop": "Stop",
    "next": "NextTrack",
    "previous": "PreviousTrack",
}

# /Sessions/<id>/Command/<verb>
COMMAND = {
    "volup": "VolumeUp",
    "voldown": "VolumeDown",
    "mute": "ToggleMute",
}


def fail(msg):
    print(json.dumps({"ok": False, "error": str(msg)}))
    return 1


def load_config():
    cfg = emby.load_config()
    if not cfg["url"] or not cfg["token"]:
        raise ValueError("bad config")
    return cfg


def post(cfg, path, body=None):
    # Same LAN-then-public road as the poll, so a button pressed away from home
    # reaches the same Emby the popup is showing.
    emby.request(cfg, path, method="POST", body=body)


def session_position_ticks(cfg, session_id):
    """Current PositionTicks for one session, for relative seeking.

    Emby's Seek command is absolute (SeekRelative is the offset command, and it
    is not used here). A 30s skip has to be computed from a fresh position.
    Read here rather than passed down from QML: the panel's number is up to one
    poll interval stale, and seeking from a stale base would drift by however
    long ago the last poll was.
    """
    sessions = emby.request(cfg, "/Sessions") or []
    for s in sessions:
        if s.get("Id") != session_id:
            continue
        if not s.get("NowPlayingItem"):
            raise ValueError("nothing is playing")
        ps = s.get("PlayState") or {}
        if not ps.get("CanSeek"):
            raise ValueError("this client cannot seek")
        pos = ps.get("PositionTicks")
        runtime = (s.get("NowPlayingItem") or {}).get("RunTimeTicks") or 0
        return int(pos or 0), int(runtime)
    raise ValueError("that session is gone")


def main(argv):
    if len(argv) != 2:
        return fail("usage: control.py <session_id> <action>")
    session_id, action = argv
    sid = urllib.parse.quote(session_id, safe="")

    try:
        cfg = load_config()
    except ValueError as e:
        return fail(e)

    try:
        if action in PLAYING:
            verb = PLAYING[action]
            post(cfg, "/Sessions/%s/Playing/%s" % (sid, verb), {"Command": verb})
        elif action in COMMAND:
            post(cfg, "/Sessions/%s/Command/%s" % (sid, COMMAND[action]))
        elif action in ("back30", "fwd30"):
            pos, runtime = session_position_ticks(cfg, session_id)
            delta = SEEK_SECONDS * TICKS_PER_SEC * (1 if action == "fwd30" else -1)
            target = max(0, pos + delta)
            if runtime:
                # Seeking past the end is how you make a client stop dead rather than
                # advance; clamp just short of it instead.
                target = min(target, max(0, runtime - TICKS_PER_SEC))
            qs = urllib.parse.urlencode({"SeekPositionTicks": target})
            post(cfg, "/Sessions/%s/Playing/Seek?%s" % (sid, qs),
                 {"Command": "Seek", "SeekPositionTicks": target})
        else:
            return fail("unknown action %r" % action)
    except emby.AuthError:
        return fail("auth failed")
    except emby.EndpointRefused as e:
        return fail(e)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return fail("that session is gone")
        return fail("http %d" % e.code)
    except ValueError as e:
        return fail(e)
    except Exception:
        return fail("unreachable")

    print(json.dumps({"ok": True, "error": ""}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
