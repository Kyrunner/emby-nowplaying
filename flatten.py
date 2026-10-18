#!/usr/bin/env python3
"""Flatten Emby /Sessions JSON (stdin) -> one compact line (stdout).

Separate from backend.sh on purpose: a bash heredoc and piped stdin cannot
coexist — the heredoc wins and python parses its own source instead of the
response. Also makes the transform testable on its own with a saved fixture.

The input is a SessionInfo array as documented for GET /Sessions. Fields this
script reads are ones that page lists (or, for the item, BaseItemDto /
MediaStream / TranscodingInfo on dev.emby.media). SupportsMediaControl is not
among them — it lives on ClientCapabilities, which /Sessions does not return —
so remote control is gated on SupportsRemoteControl alone.
"""
import json,sys,urllib.parse

# argv[1] = server origin for browser links (web_base). The Emby web client
# route used here is /web/index.html#!/item?id=&serverId=, which is what
# self-hosted Emby web answers. It is not part of the REST reference.
BASE = (sys.argv[1].rstrip('/') if len(sys.argv) > 1 else '')
# argv[2] = the API root that answered (origin + /emby). Posters are fetched
# by QML's Image directly. Falls back to BASE when unset so an older
# backend.sh keeps working.
API_BASE = (sys.argv[2].rstrip('/') if len(sys.argv) > 2 and sys.argv[2] else BASE)
# argv[3] = which endpoint answered ("lan" / "public"), reported so the popup
# can say when it is reaching Emby from outside the LAN.
ENDPOINT = (sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else "lan")

# 180px tall is ~2x the rendered thumbnail on a HiDPI bar. The image reference
# names MaxHeight and Tag as the query parameters.
POSTER_MAX_HEIGHT = 180


def poster_url(npi):
    """Series poster for an episode, the item's own Primary otherwise.

    A series poster is what "poster artwork" means for TV: tall, recognisable,
    and identical across a season. An episode's own Primary is a still, so it
    is only used when there is no series behind it. BaseItemDto carries
    SeriesId, SeriesPrimaryImageTag and ImageTags for this.

    No credential is attached. GET /Items/{Id}/Images/{Type} is documented as
    requiring authentication and lists 401, but putting api_key or the token
    in this URL would place a live credential in QML and in anything that logs
    the image request. The URL is therefore unauthenticated on purpose.

    The tag is the image cache tag. The image guide says adding it changes the
    URL when the artwork changes, so a replaced poster is not stuck in cache.
    """
    if not API_BASE:
        return None

    def image(item_id, tag):
        q = urllib.parse.urlencode({"Tag": tag, "MaxHeight": POSTER_MAX_HEIGHT})
        return f"{API_BASE}/Items/{urllib.parse.quote(str(item_id), safe='')}/Images/Primary?{q}"

    series_id = npi.get("SeriesId")
    series_tag = npi.get("SeriesPrimaryImageTag")
    if npi.get("Type") == "Episode" and series_id and series_tag:
        return image(series_id, series_tag)

    item_id = npi.get("Id")
    own_tag = (npi.get("ImageTags") or {}).get("Primary")
    if item_id and own_tag:
        return image(item_id, own_tag)

    # Music and some live content genuinely have no artwork. The panel hides the
    # thumbnail rather than showing a broken-image box.
    return None


def web_url(npi):
    item_id = npi.get("Id")
    if not BASE or not item_id:
        return None
    q = [("id", item_id)]
    if npi.get("ServerId"):
        q.append(("serverId", npi.get("ServerId")))
    return f"{BASE}/web/index.html#!/item?{urllib.parse.urlencode(q)}"


def hardware(ti):
    """Emby TranscodingInfo has no HardwareAccelerationType.

    The documented hardware signal is VideoEncoderIsHardware /
    VideoEncoderHwAccel, with the decoder pair as the fallback. Absent both,
    the panel's empty hw_accel renders as software.
    """
    if ti.get("VideoEncoderIsHardware"):
        return ti.get("VideoEncoderHwAccel") or "hardware"
    if ti.get("VideoDecoderIsHardware"):
        return ti.get("VideoDecoderHwAccel") or "hardware"
    return None


try:
    sessions=json.load(sys.stdin)
    if not isinstance(sessions,list): raise ValueError
except Exception:
    sys.exit(1)

def ticks_to_sec(t):
    return int(t)//10_000_000 if isinstance(t,(int,float)) else 0

streams=[]
for s in sessions:
    npi=s.get("NowPlayingItem")
    if not npi:                      # idle session, or a fixture note -> not playing
        continue
    ps=s.get("PlayState") or {}
    ti=s.get("TranscodingInfo")      # present ONLY while transcoding
    item=npi.get("Name") or "Unknown"
    series=npi.get("SeriesName")
    if series and npi.get("Type")=="Episode":
        idx=npi.get("IndexNumber"); pa=npi.get("ParentIndexNumber")
        tag=f"S{pa:02d}E{idx:02d} " if isinstance(idx,int) and isinstance(pa,int) else ""
        title=f"{series} — {tag}{item}"
    else:
        year=npi.get("ProductionYear")
        title=f"{item} ({year})" if year else item

    controllable = bool(s.get("SupportsRemoteControl"))
    entry={
      "title": title,
      "user": s.get("UserName") or "?",
      "device": s.get("DeviceName") or "?",
      "client": s.get("Client") or "?",
      "paused": bool(ps.get("IsPaused")),
      "position_sec": ticks_to_sec(ps.get("PositionTicks")),
      "duration_sec": ticks_to_sec(npi.get("RunTimeTicks")),
      "transcoding": ti is not None,
      "bitrate_mbps": None,
      "video_codec": None, "audio_codec": None,
      "reasons": [], "hw_accel": None,
      # MediaStream.DisplayTitle, documented as the display string the server sets.
      "video_label": None,
      # MediaStream.VideoRange. The Emby MediaStream reference does not list
      # VideoRangeType, so that Jellyfin field is not read.
      "video_range": None,
      "item_id": npi.get("Id"),
      "poster_url": poster_url(npi),
      # Transport targets the SESSION, not the item: Emby routes commands to the
      # client that is playing, so the same film on two devices is two controllable
      # things.
      "session_id": s.get("Id"),
      # SessionInfo documents SupportsRemoteControl only.
      "controllable": controllable,
      "can_seek": bool(ps.get("CanSeek")),
      "control_error": (
          "" if controllable
          else "%s cannot be controlled remotely" % (s.get("Client") or "this client")
      ),
      "web_url": web_url(npi),
    }
    if ti:
        br=ti.get("Bitrate")
        entry["bitrate_mbps"]=round(br/1_000_000,1) if isinstance(br,(int,float)) else None
        entry["video_codec"]=ti.get("VideoCodec"); entry["audio_codec"]=ti.get("AudioCodec")
        entry["reasons"]=ti.get("TranscodeReasons") or []
        entry["hw_accel"]=hardware(ti)
        entry["video_direct"]=bool(ti.get("IsVideoDirect"))
        entry["audio_direct"]=bool(ti.get("IsAudioDirect"))
    else:
        # direct play: source bitrate comes off the media stream instead
        for ms in (npi.get("MediaStreams") or []):
            if ms.get("Type")=="Video" and isinstance(ms.get("BitRate"),(int,float)):
                entry["bitrate_mbps"]=round(ms["BitRate"]/1_000_000,1)
                entry["video_codec"]=ms.get("Codec"); break
    for ms in (npi.get("MediaStreams") or []):
        if ms.get("Type") != "Video":
            continue
        entry["video_range"]=ms.get("VideoRange")
        dt=ms.get("DisplayTitle")
        if dt:
            # The Jellyfin port drops a suffix that server appends to DisplayTitle.
            # Harmless when Emby does not append it.
            entry["video_label"]=dt.split(" - Dolby Vision Profile")[0].strip()
        break

    streams.append(entry)

print(json.dumps({"ok":True,"error":None,"streams":streams,"endpoint":ENDPOINT}, separators=(",",":")))
