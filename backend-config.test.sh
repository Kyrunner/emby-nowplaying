#!/usr/bin/env bash
# Config parsing and credential handling for backend.sh.
#
#   bash backend-config.test.sh
#
# Runs against a stub Emby on localhost, so it needs no real server and no
# credentials. The stub records the X-Emby-Token it was sent and only answers
# under /emby/, which is how a request that forgot the base path or sent the
# Jellyfin Authorization scheme fails closed.
set -u

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'kill ${STUB_PID:-} 2>/dev/null; rm -rf "$WORK"' EXIT
export XDG_STATE_HOME="$WORK/state"   # keep the endpoint memory out of the real one

PORT="${EMBY_TEST_PORT:-8792}"
GOOD_TOKEN="realtoken-abcdef0123456789"
export STUB_TOKEN="$GOOD_TOKEN" STUB_LOG="$WORK/seen-token.txt" STUB_PATH="$WORK/seen-path.txt" STUB_BODY="$WORK/seen-body.txt" STUB_PORT="$PORT"

# One plain stub, one TLS stub, and three hostile ones: a redirector, the host it
# redirects to, and a server that answers with more bytes than any real reply.
# The TLS cert is self-signed for 127.0.0.1 and trusted through SSL_CERT_FILE,
# so the public-address path runs over real HTTPS rather than being faked.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=127.0.0.1" \
  -addext "subjectAltName=IP:127.0.0.1" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1
export SSL_CERT_FILE="$WORK/cert.pem" STUB_CERT="$WORK/cert.pem" STUB_CERTKEY="$WORK/key.pem"
TLS_PORT=$((PORT + 20)); REDIR_PORT=$((PORT + 21)); CATCH_PORT=$((PORT + 22)); BIG_PORT=$((PORT + 23))
export TLS_PORT REDIR_PORT CATCH_PORT BIG_PORT CATCH_LOG="$WORK/caught-token.txt"

python3 - <<'PY' &
import http.server, json, os, threading, ssl
TOKEN = os.environ["STUB_TOKEN"]
LOG = os.environ["STUB_LOG"]
PATH_LOG = os.environ["STUB_PATH"]
BODY_LOG = os.environ["STUB_BODY"]
CATCH_LOG = os.environ["CATCH_LOG"]

# Two placeholder sessions so seek math can be checked without a real server.
# Not library metadata.
TICK = 10_000_000
SESSIONS = json.dumps([
    {
        "Id": "sess-seek",
        "SupportsRemoteControl": True,
        "UserName": "Placeholder Viewer",
        "NowPlayingItem": {"Id": "synthetic-item", "Name": "Placeholder", "RunTimeTicks": 600 * TICK},
        "PlayState": {"CanSeek": True, "IsPaused": False, "PositionTicks": 100 * TICK},
    },
    {
        "Id": "sess-end",
        "SupportsRemoteControl": True,
        "NowPlayingItem": {"Id": "synthetic-item-end", "Name": "Placeholder", "RunTimeTicks": 600 * TICK},
        "PlayState": {"CanSeek": True, "IsPaused": False, "PositionTicks": 590 * TICK},
    },
]).encode()


def token_of(h):
    # Emby's API-key header. The Jellyfin MediaBrowser Authorization scheme is ignored.
    return h.headers.get("X-Emby-Token", "")


def under_emby(path):
    return path.split("?", 1)[0].startswith("/emby/")


class H(http.server.BaseHTTPRequestHandler):
    def _reject_leak(self):
        if "api_key=" in self.path:
            self.send_response(400)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return True
        return False

    def _record(self, body):
        with open(LOG, "w") as f:
            f.write(token_of(self))
        with open(PATH_LOG, "w") as f:
            f.write(self.path)
        with open(BODY_LOG, "w") as f:
            f.write(body.decode("utf-8", "replace"))

    def do_GET(self):
        if self._reject_leak():
            return
        self._record(b"")
        if not under_emby(self.path):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        got = token_of(self)
        if got == "forbidden-token":
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = SESSIONS if self.path.split("?", 1)[0] == "/emby/Sessions" else b"[]"
        self.send_response(200 if got == TOKEN else 401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body if got == TOKEN else b"")))
        self.end_headers()
        if got == TOKEN:
            self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        if self._reject_leak():
            return
        self._record(body)
        if not under_emby(self.path):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        got = token_of(self)
        # Playstate reference: 200 empty. 204 is also a success for urllib.
        self.send_response(200 if got == TOKEN else 401)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *a):
        pass


class Redirect(H):
    def _go(self):
        self.send_response(302)
        self.send_header("Location", "http://127.0.0.1:%s%s" % (os.environ["CATCH_PORT"], self.path))
        self.send_header("Content-Length", "0")
        self.end_headers()
    do_GET = do_POST = _go


class Catch(H):
    def _got(self):
        with open(CATCH_LOG, "w") as f:
            f.write(token_of(self))
        body = b"[]"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    do_GET = do_POST = _got


class Big(H):
    def do_GET(self):
        body = b'[{"pad": "' + b"x" * (5 * 1024 * 1024) + b'"}]'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def serve(port, handler, tls=False):
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", int(port)), handler)
    if tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(os.environ["STUB_CERT"], os.environ["STUB_CERTKEY"])
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()


serve(os.environ["STUB_PORT"], H)
serve(os.environ["TLS_PORT"], H, tls=True)
serve(os.environ["REDIR_PORT"], Redirect)
serve(os.environ["CATCH_PORT"], Catch)
serve(os.environ["BIG_PORT"], Big)
threading.Event().wait()
PY
STUB_PID=$!

for p in "$PORT" "$TLS_PORT" "$REDIR_PORT" "$CATCH_PORT" "$BIG_PORT"; do
  for _ in $(seq 30); do
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && break
    read -r -t 0.1 < /dev/zero 2>/dev/null || true
  done
done

pass=0
fail=0

run() { # name, expected-substring, config-json ("" means no config file at all), [backend args...]
  local name="$1" want="$2" cfg="$3" out
  shift 3
  rm -f "$WORK/seen-token.txt" "$WORK/seen-path.txt" "$WORK/seen-body.txt"
  if [ -z "$cfg" ]; then rm -f "$WORK/config.json"; else printf '%s' "$cfg" >"$WORK/config.json"; fi
  out=$(OMARCHY_EMBY_CONFIG="$WORK/config.json" "$PLUGIN/backend.sh" "$@" 2>&1)
  if [[ "$out" == *"$want"* ]]; then
    pass=$((pass + 1)); printf '  ok    %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL  %s\n        want %s\n        got  %s\n' "$name" "$want" "$out"
  fi
}

check() { # name, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok    %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL  %s\n        want %s\n        got  %s\n' "$1" "$2" "$3"
  fi
}

U="http://127.0.0.1:$PORT"
UT="https://127.0.0.1:$TLS_PORT"    # the public address must be HTTPS
UR="http://127.0.0.1:$REDIR_PORT"
UB="http://127.0.0.1:$BIG_PORT"

echo "config errors are reported as config errors:"
run "missing file"          '"error":"not configured"' ""
run "unparseable JSON"      '"error":"bad config"'     '{"url": '
run "not a JSON object"     '"error":"bad config"'     '["url","token"]'
# The regression. An absent token once collapsed the field split and put
# web_base in the token's place, which the server rejected as "auth failed".
run "token absent"          '"error":"bad config"'     "{\"url\":\"$U\",\"web_base\":\"https://web.example\"}"
run "token empty"           '"error":"bad config"'     "{\"url\":\"$U\",\"token\":\"\",\"web_base\":\"https://web.example\"}"
run "token null"            '"error":"bad config"'     "{\"url\":\"$U\",\"token\":null,\"web_base\":\"https://web.example\"}"
run "url absent"            '"error":"bad config"'     "{\"token\":\"$GOOD_TOKEN\"}"
run "url empty"             '"error":"bad config"'     "{\"url\":\"\",\"token\":\"$GOOD_TOKEN\"}"

echo "credentials:"
run "a wrong token is still an auth failure" '"error":"auth failed"' "{\"url\":\"$U\",\"token\":\"nope\"}"
run "a 403 is permission, not a bad token" '"error":"http 403"' "{\"url\":\"$U\",\"token\":\"forbidden-token\"}"
run "valid config polls"    '"ok":true' "{\"url\":\"$U\",\"token\":\"$GOOD_TOKEN\",\"web_base\":\"https://web.example\"}"
if [ "$(cat "$WORK/seen-token.txt" 2>/dev/null)" = "$GOOD_TOKEN" ]; then
  pass=$((pass + 1)); echo "  ok    the token on the wire is the token in the file"
else
  fail=$((fail + 1)); echo "  FAIL  sent '$(cat "$WORK/seen-token.txt" 2>/dev/null)' instead of the configured token"
fi
check "the poll hits /emby/Sessions" "/emby/Sessions" "$(cat "$WORK/seen-path.txt" 2>/dev/null)"
run "token pasted with stray whitespace" '"ok":true' "{\"url\":\"$U\",\"token\":\"  $GOOD_TOKEN \\n\"}"
run "web_base absent falls back to url"  '"ok":true' "{\"url\":\"$U\",\"token\":\"$GOOD_TOKEN\"}"
run "trailing slash on url"              '"ok":true' "{\"url\":\"$U/\",\"token\":\"$GOOD_TOKEN\"}"
run "url that already ends in /emby is not doubled" '"ok":true' "{\"url\":\"$U/emby\",\"token\":\"$GOOD_TOKEN\"}"
check "a pre-suffixed url still requests /emby/Sessions once" "/emby/Sessions" "$(cat "$WORK/seen-path.txt" 2>/dev/null)"

# Nothing listens on port 1, so the LAN address fails fast and deterministically.
DEAD="http://127.0.0.1:1"
ENDPOINT="$WORK/state/omarchy-emby/endpoint.json"

echo "endpoint fallback:"
rm -f "$ENDPOINT"
run "LAN dead, public_url answers" '"endpoint":"public"' "{\"url\":\"$DEAD\",\"token\":\"$GOOD_TOKEN\",\"public_url\":\"$UT\"}"
if grep -q '"which": *"public"' "$ENDPOINT" 2>/dev/null; then
  pass=$((pass + 1)); echo "  ok    the public choice is remembered for the next poll"
else
  fail=$((fail + 1)); echo "  FAIL  endpoint.json does not record the public choice: $(cat "$ENDPOINT" 2>/dev/null)"
fi
run "a control follows the same fallback" '"ok": true' "{\"url\":\"$DEAD\",\"token\":\"$GOOD_TOKEN\",\"public_url\":\"$UT\"}" control sess1 playpause
if [ "$(cat "$WORK/seen-token.txt" 2>/dev/null)" = "$GOOD_TOKEN" ]; then
  pass=$((pass + 1)); echo "  ok    the control carried the configured token"
else
  fail=$((fail + 1)); echo "  FAIL  control sent '$(cat "$WORK/seen-token.txt" 2>/dev/null)'"
fi
check "playpause posts to the Playing route" "/emby/Sessions/sess1/Playing/PlayPause" "$(cat "$WORK/seen-path.txt" 2>/dev/null)"
check "playpause sends a PlaystateRequest body" '{"Command": "PlayPause"}' "$(cat "$WORK/seen-body.txt" 2>/dev/null)"
rm -f "$ENDPOINT"
run "mute posts to the Command route" '"ok": true' "{\"url\":\"$U\",\"token\":\"$GOOD_TOKEN\"}" control sess1 mute
check "mute path is Command/ToggleMute" "/emby/Sessions/sess1/Command/ToggleMute" "$(cat "$WORK/seen-path.txt" 2>/dev/null)"
check "mute sends no body" "" "$(cat "$WORK/seen-body.txt" 2>/dev/null)"
rm -f "$ENDPOINT"
run "forward 30s seeks absolutely" '"ok": true' "{\"url\":\"$U\",\"token\":\"$GOOD_TOKEN\"}" control sess-seek fwd30
check "seek path carries absolute SeekPositionTicks" \
  "/emby/Sessions/sess-seek/Playing/Seek?SeekPositionTicks=1300000000" \
  "$(cat "$WORK/seen-path.txt" 2>/dev/null)"
check "seek body repeats SeekPositionTicks" \
  '{"Command": "Seek", "SeekPositionTicks": 1300000000}' \
  "$(cat "$WORK/seen-body.txt" 2>/dev/null)"
run "seek clamps short of the runtime" '"ok": true' "{\"url\":\"$U\",\"token\":\"$GOOD_TOKEN\"}" control sess-end fwd30
check "near-end seek stops one second short" \
  "/emby/Sessions/sess-end/Playing/Seek?SeekPositionTicks=5990000000" \
  "$(cat "$WORK/seen-path.txt" 2>/dev/null)"
rm -f "$ENDPOINT"
run "public_url defaults to web_base" '"endpoint":"public"' "{\"url\":\"$DEAD\",\"token\":\"$GOOD_TOKEN\",\"web_base\":\"$UT\"}"
rm -f "$ENDPOINT"
run "LAN alive is reported as lan"  '"endpoint":"lan"' "{\"url\":\"$U\",\"token\":\"$GOOD_TOKEN\",\"public_url\":\"$DEAD\"}"
run "no public_url: LAN dead is still unreachable" '"error":"unreachable"' "{\"url\":\"$DEAD\",\"token\":\"$GOOD_TOKEN\"}"
run "public_url set to empty never leaves the LAN" '"error":"unreachable"' "{\"url\":\"$DEAD\",\"token\":\"$GOOD_TOKEN\",\"web_base\":\"$U\",\"public_url\":\"\"}"
# A wrong token must never fail over: retrying bad credentials against a public
# edge is how you get banned by your own rate limiter.
run "a wrong token does not fail over" '"error":"auth failed"' "{\"url\":\"$U\",\"token\":\"nope\",\"public_url\":\"$DEAD\"}"

echo "public address safety:"
rm -f "$ENDPOINT"
run "an http:// public_url is refused" '"error":"public_url must be https"' "{\"url\":\"$DEAD\",\"token\":\"$GOOD_TOKEN\",\"public_url\":\"$U\"}"
if [ ! -e "$WORK/seen-token.txt" ]; then
  pass=$((pass + 1)); echo "  ok    the token was never sent to the plain-HTTP public address"
else
  fail=$((fail + 1)); echo "  FAIL  the token reached a plain-HTTP public address"
fi
rm -f "$ENDPOINT" "$CATCH_LOG"
run "a redirect is refused, not followed" '"error":"http 302"' "{\"url\":\"$UR\",\"token\":\"$GOOD_TOKEN\"}"
run "a control refuses a redirect too" '"error": "http 302"' "{\"url\":\"$UR\",\"token\":\"$GOOD_TOKEN\"}" control sess1 playpause
if [ ! -e "$CATCH_LOG" ]; then
  pass=$((pass + 1)); echo "  ok    the redirect target never received the token"
else
  fail=$((fail + 1)); echo "  FAIL  the redirect target received the token: '$(cat "$CATCH_LOG")'"
fi
rm -f "$ENDPOINT"
run "an oversized response is refused" '"error":"response too large"' "{\"url\":\"$UB\",\"token\":\"$GOOD_TOKEN\"}"

echo "synthetic /Sessions fixture:"
FLAT=$(python3 "$PLUGIN/flatten.py" "https://web.example" "https://lan.example/emby" "lan" \
  < "$PLUGIN/fixtures/sessions.synthetic.json") || FLAT=""
check "fixture exit produced JSON" "0" "$([ -n "$FLAT" ] && echo 0 || echo 1)"
for needle in \
  '"title":"Placeholder Series \u2014 S01E01 Placeholder Episode"' \
  '"title":"Placeholder Film"' \
  'https://lan.example/emby/Items/synthetic-series/Images/Primary?Tag=synthetic-series-tag&MaxHeight=180' \
  'https://lan.example/emby/Items/synthetic-item-film/Images/Primary?Tag=synthetic-film-tag&MaxHeight=180' \
  'https://web.example/web/index.html#!/item?id=synthetic-item-episode&serverId=synthetic-server' \
  '"hw_accel":"placeholder-hw"' \
  '"video_range":"SDR"' \
  '"controllable":true' \
  '"controllable":false' \
  'Placeholder Web cannot be controlled remotely' \
  '"endpoint":"lan"'
do
  if [[ "$FLAT" == *"$needle"* ]]; then
    pass=$((pass + 1)); printf '  ok    fixture contains %s\n' "$needle"
  else
    fail=$((fail + 1)); printf '  FAIL  fixture missing %s\n' "$needle"
  fi
done
if [[ "$FLAT" != *"api_key="* && "$FLAT" != *"X-Emby-Token"* && "$FLAT" != *"$GOOD_TOKEN"* ]]; then
  pass=$((pass + 1)); echo "  ok    fixture poster and links carry no token"
else
  fail=$((fail + 1)); echo "  FAIL  fixture output contains a credential"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "backend config: all $pass assertions passed"
else
  echo "backend config: $fail of $((pass + fail)) failed"
  printf '%s\n' "$FLAT" | head -c 2000; echo
fi
[ "$fail" -eq 0 ]
