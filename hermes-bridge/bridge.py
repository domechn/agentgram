#!/usr/bin/env python3
"""hermes-bridge: one Telegram bot that multiplexes every Hermes profile for AgentGram.

Outbound long polling only (no listening socket). Every message is a sealed frame, see
docs/DESIGN.md "Wire protocol". Config comes from the environment:

  AG_BOT_TOKEN   bot token from @BotFather            (required)
  AG_USER_ID     the only Telegram user id obeyed      (required)
  AG_KEY         base64 of the 32-byte shared key      (required)
  HERMES_HOME    default ~/.hermes
  HERMES_BIN     default "hermes"
  HERMES_API     default http://127.0.0.1:8642
  AG_STATE       default $HERMES_HOME/agentgram-bridge
  AG_TG_API      default https://api.telegram.org      (tests point this at a fake)
  AG_SOURCE      the git checkout install.sh ran from; enables bridge.update
"""
import base64
import json
import os
import queue
import re
import secrets
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

VERSION = "0.3.0"
PREFIX = "AG1."
AAD = b"AG1"
TEXT_LIMIT = 4096        # Telegram message length
SEGMENT_BYTES = 2000     # stream text per message; leaves room for tools/approval in the frame
MAX_SKEW = 300           # seconds a request timestamp may be off
SWEEP_AFTER = 600        # delete our own messages after this many seconds
MAX_HOPS = 4             # member-to-member relays per user message in a group
MAX_FILE = 45 * 1024 * 1024
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,40}$")
JOB_RE = re.compile(r"^[a-f0-9]{12}$")   # Hermes cron job ids
SKIP_DIRS = {"node_modules", "__pycache__"}
WALK_LIMIT = 5000        # files looked at per folder tree when listing
# bridge.update pulls only from here: the same place the manual update gets its code from.
SOURCE_URLS = {"https://github.com/domechn/agentgram", "https://github.com/domechn/agentgram.git"}


class BridgeError(Exception):
    pass


# ---------------------------------------------------------------- frames

def seal(key: bytes, obj) -> bytes:
    nonce = os.urandom(12)
    body = json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode()
    return nonce + ChaCha20Poly1305(key).encrypt(nonce, body, AAD)


def unseal(key: bytes, raw: bytes):
    return json.loads(ChaCha20Poly1305(key).decrypt(raw[:12], raw[12:], AAD))


def to_text(raw: bytes) -> str:
    return PREFIX + base64.urlsafe_b64encode(raw).decode().rstrip("=")


def from_text(text: str) -> bytes:
    body = text[len(PREFIX):]
    return base64.urlsafe_b64decode(body + "=" * (-len(body) % 4))


class Replay:
    """Rejects stale timestamps and request ids already seen inside the skew window."""

    def __init__(self, started=0.0):
        self.seen, self.started = {}, started

    def check(self, req, now=None):
        now = time.time() if now is None else now
        ts, rid = req.get("ts"), req.get("id")
        # `seen` is in memory only, so nothing stamped before this process started is accepted:
        # otherwise a captured frame could be replayed right after a restart.
        if not isinstance(ts, (int, float)) or abs(now - ts) > MAX_SKEW or ts < self.started:
            raise BridgeError("stale request")
        if not isinstance(rid, str) or not rid or rid in self.seen:
            raise BridgeError("replayed request")
        self.seen = {k: v for k, v in self.seen.items() if now - v <= 2 * MAX_SKEW}
        self.seen[rid] = now


# ---------------------------------------------------------------- group routing (pure)

def mentions(text: str, members: list) -> list:
    """Members @mentioned in text, in order of first mention."""
    out = []
    for name in re.findall(r"@([a-z0-9][a-z0-9-]*)", text.lower()):
        if name in members and name not in out:
            out.append(name)
    return out


def route(text: str, members: list, mode: str) -> list:
    """Who answers a user message: the mentioned members, else everyone (all) or the first."""
    return mentions(text, members) or (list(members) if mode == "all" else members[:1])


def group_prompt(group: dict, member: str) -> str:
    seen = group.get("seen", {}).get(member, 0)
    lines = [f"[{m['who']}]: {m['text']}" for m in group["transcript"][seen:]]
    others = ", ".join(m for m in group["members"] if m != member) or "nobody else"
    return (f"You are '{member}' in the group chat '{group['name']}' with the user and: {others}. "
            "To hand the turn to another member, @mention their name; otherwise just answer.\n"
            "Messages since your last turn:\n" + "\n".join(lines))


def parse_profile_list(text: str) -> list:
    """Rows of `hermes profile list`: name, model, gateway state."""
    out = []
    for line in text.splitlines():
        m = re.match(r"^\s*(◆)?\s*([a-z0-9][a-z0-9-]*)\s+(\S+)\s+(running|stopped)\b", line)
        if m:
            out.append({"name": m[2], "model": m[3], "gateway": m[4], "default": m[2] == "default"})
    return out


def split_bytes(text: str, limit: int) -> int:
    """Length (in characters) of the longest prefix of text that fits in `limit` UTF-8 bytes."""
    used = 0
    for i, ch in enumerate(text):
        used += len(ch.encode())
        if used > limit:
            return i
    return len(text)


# ---------------------------------------------------------------- Telegram

class Telegram:
    def __init__(self, token: str, base: str):
        self.base = f"{base}/bot{token}"
        self.file_base = f"{base}/file/bot{token}"

    def call(self, method: str, http_timeout=60, **params):
        body = json.dumps(params).encode()
        return self._send(urllib.request.Request(
            f"{self.base}/{method}", body, {"Content-Type": "application/json"}), http_timeout)

    def _send(self, req, timeout):
        for _ in range(5):
            try:
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    return json.load(resp)["result"]
            except urllib.error.HTTPError as e:
                info = json.loads(e.read() or b"{}")
                wait = (info.get("parameters") or {}).get("retry_after")
                if e.code == 429 and wait:
                    time.sleep(min(float(wait), 30) + 0.5)
                    continue
                # Never echo the URL: it contains the bot token.
                raise BridgeError(f"telegram {e.code}: {info.get('description', '')}") from None
            except urllib.error.URLError as e:
                raise BridgeError(f"telegram unreachable: {e.reason}") from None
        raise BridgeError("telegram rate limit")

    def upload(self, chat_id, name: str, data: bytes, caption=""):
        boundary = uuid.uuid4().hex
        parts = b""
        for field, value in (("chat_id", str(chat_id)), ("caption", caption), ("disable_notification", "true"),
                             ("disable_content_type_detection", "true")):  # a GIF must stay a document
            parts += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{field}\"\r\n\r\n"
                      f"{value}\r\n").encode()
        safe = name.replace('"', "_").replace("\r", "_").replace("\n", "_")
        parts += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"document\"; "
                  f"filename=\"{safe}\"\r\nContent-Type: application/octet-stream\r\n\r\n").encode()
        parts += data + f"\r\n--{boundary}--\r\n".encode()
        return self._send(urllib.request.Request(
            f"{self.base}/sendDocument", parts,
            {"Content-Type": f"multipart/form-data; boundary={boundary}"}), 300)

    def download(self, file_id: str) -> bytes:
        path = self.call("getFile", file_id=file_id)["file_path"]
        try:
            with urllib.request.urlopen(f"{self.file_base}/{path}", timeout=300) as resp:
                return resp.read()
        except urllib.error.URLError:
            raise BridgeError("telegram file download failed") from None


# ---------------------------------------------------------------- bridge

class Bridge:
    def __init__(self, env=os.environ):
        self.key = base64.b64decode(env["AG_KEY"])
        if len(self.key) != 32:
            raise SystemExit("AG_KEY must be base64 of 32 bytes")
        self.user = int(env["AG_USER_ID"])
        self.tg = Telegram(env["AG_BOT_TOKEN"], env.get("AG_TG_API", "https://api.telegram.org"))
        self.home = Path(env.get("HERMES_HOME") or Path.home() / ".hermes")
        self.hermes_bin = env.get("HERMES_BIN", "hermes")
        self.api = env.get("HERMES_API", "http://127.0.0.1:8642").rstrip("/")
        self.state = Path(env.get("AG_STATE") or self.home / "agentgram-bridge")
        self.state.mkdir(parents=True, exist_ok=True)
        os.chmod(self.state, 0o700)
        self.replay = Replay(time.time())
        self.lock = threading.Lock()
        self.sent = []    # (time, message id) of our own messages, for the sweep
        self.runs = {}    # run id -> profile, for profile.stop
        self.stopping = False
        self.poll = int(env.get("AG_POLL_SECONDS", "50"))
        self.source = env.get("AG_SOURCE", "")   # the checkout install.sh ran from, if it was one
        self.path = Path(__file__).resolve()     # the installed copy bridge.update replaces
        self.exit = os._exit                     # under systemd (Restart=always) this is a restart

    # -- plumbing

    def audit(self, op, args, ok, error=""):
        # Message text, prompts and file contents are never written here.
        clean = {k: (v if k not in ("text", "soul", "body", "prompt") else f"<{len(str(v))} chars>")
                 for k, v in (args or {}).items()}
        line = json.dumps({"ts": int(time.time()), "op": op, "args": clean, "ok": ok, "error": error})
        with self.lock, open(self.state / "audit.log", "a") as f:
            f.write(line + "\n")

    def profile_dir(self, profile: str) -> Path:
        if profile != "default" and not NAME_RE.match(profile or ""):
            raise BridgeError("invalid profile name")
        path = self.home if profile == "default" else self.home / "profiles" / profile
        if not path.is_dir():
            raise BridgeError(f"no such profile: {profile}")
        return path

    def hermes(self, *args, profile=None, timeout=120, check=True) -> str:
        cmd = [self.hermes_bin] + (["-p", profile] if profile and profile != "default" else []) + list(args)
        env = dict(os.environ, HERMES_HOME=str(self.home), NO_COLOR="1")
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env,
                               stdin=subprocess.DEVNULL, cwd=str(self.home))
        except subprocess.TimeoutExpired:
            raise BridgeError(f"hermes {args[0]} timed out") from None
        if check and p.returncode != 0:
            raise BridgeError((p.stderr or p.stdout).strip()[-600:] or f"hermes {args[0]} failed")
        return p.stdout

    def api_key(self, profile: str) -> str:
        """The profile's API_SERVER_KEY; created on first use for named profiles."""
        env_path = self.profile_dir(profile) / ".env"
        if env_path.exists():
            for line in env_path.read_text().splitlines():
                if line.startswith("API_SERVER_KEY="):
                    value = line.split("=", 1)[1].strip().strip("'\"")
                    if value:
                        return value
        if profile == "default":
            raise BridgeError("Hermes API server is not enabled (run install.sh --enable-api)")
        value = secrets.token_hex(32)
        with self.lock:
            existing = env_path.read_text() if env_path.exists() else ""
            fd = os.open(env_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write(existing + ("" if existing.endswith("\n") or not existing else "\n")
                        + f"API_SERVER_KEY={value}\n")
        self.audit("profile.enable_api", {"profile": profile}, True)
        return value

    def http(self, profile, method, path, body=None, headers=None, timeout=60, stream=False):
        prefix = "" if profile == "default" else f"/p/{profile}"
        h = {"Authorization": f"Bearer {self.api_key(profile)}", **(headers or {})}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            h["Content-Type"] = "application/json"
        req = urllib.request.Request(self.api + prefix + path, data, h, method=method)
        try:
            resp = urllib.request.urlopen(req, timeout=timeout)
        except urllib.error.HTTPError as e:
            try:
                err = json.loads(e.read())["error"]
                msg = err["message"] if isinstance(err, dict) else str(err)
            except Exception:
                msg = f"HTTP {e.code}"
            raise BridgeError(f"hermes api: {msg}") from None
        except (urllib.error.URLError, OSError):
            raise BridgeError("Hermes API server is not reachable (is it enabled? "
                              "see install.sh --enable-api)") from None
        if stream:
            return resp
        with resp:
            return json.load(resp)

    def reply(self, chat, obj):
        raw = seal(self.key, obj)
        text = to_text(raw)
        if len(text) <= TEXT_LIMIT:
            msg = self.tg.call("sendMessage", chat_id=chat, text=text, disable_notification=True)
        else:
            msg = self.tg.upload(chat, "ag1.bin", raw)
        with self.lock:
            self.sent.append((time.time(), msg["message_id"]))
        return msg["message_id"]

    def sweep(self, chat, now=None):
        now = time.time() if now is None else now
        with self.lock:
            old = [m for t, m in self.sent if now - t > SWEEP_AFTER]
            self.sent = [(t, m) for t, m in self.sent if now - t <= SWEEP_AFTER]
        for mid in old:
            try:
                self.tg.call("deleteMessage", chat_id=chat, message_id=mid)
            except BridgeError:
                pass  # already deleted by the app

    # -- main loop

    def run(self):
        offset = 0
        while not self.stopping:
            try:
                updates = self.tg.call("getUpdates", http_timeout=self.poll + 20, offset=offset,
                                       timeout=self.poll, allowed_updates=["message"])
            except BridgeError as e:
                print(f"poll failed: {e}", file=sys.stderr, flush=True)
                time.sleep(5)
                continue
            for update in updates:
                offset = update["update_id"] + 1
                msg = update.get("message") or {}
                if (msg.get("from") or {}).get("id") != self.user or (msg.get("chat") or {}).get("type") != "private":
                    continue  # sole principal; everything else is ignored silently
                threading.Thread(target=self.handle, args=(msg,), daemon=True).start()
            self.sweep(self.user)

    def handle(self, msg):
        chat = msg["chat"]["id"]
        doc = msg.get("document")
        try:
            frame = msg.get("text") or msg.get("caption") or ""
            if frame.startswith(PREFIX):
                req = unseal(self.key, from_text(frame))
            elif doc and doc.get("file_name") == "ag1.bin":
                req, doc = unseal(self.key, self.tg.download(doc["file_id"])), None
            else:
                return
            self.replay.check(req)
        except Exception:
            return  # not ours, forged, or replayed: say nothing
        op, args, rid = str(req.get("op")), req.get("args") or {}, req["id"]
        write, restart = op in WRITES, False
        try:
            handler = OPS.get(op)
            if handler is None:
                raise BridgeError(f"unknown op: {op}")
            data = handler(self, args, Ctx(self, chat, rid, doc))
            restart = op == "bridge.update" and data["updated"]   # even if the reply below fails
            if data is not SENT:
                self.reply(chat, {"v": 1, "re": rid, "ok": True, "data": data})
            if write:
                self.audit(op, args, True)
        except Exception as e:
            error = str(e) if isinstance(e, BridgeError) else f"{type(e).__name__}: {e}"
            if write:
                self.audit(op, args, False, error)
            try:
                self.reply(chat, {"v": 1, "re": rid, "ok": False, "error": error[:800]})
            except BridgeError as e2:
                print(f"reply failed: {e2}", file=sys.stderr, flush=True)
        finally:
            try:
                self.tg.call("deleteMessage", chat_id=chat, message_id=msg["message_id"])
            except BridgeError:
                pass
            if restart:   # bridge.update has answered; the new code starts with the restart
                self.exit(0)

    # -- self-update

    def git(self, *args, timeout=120) -> str:
        try:
            p = subprocess.run(["git", "-C", self.source, *args], capture_output=True, text=True, timeout=timeout,
                               stdin=subprocess.DEVNULL, env=dict(os.environ, GIT_TERMINAL_PROMPT="0"))
        except (OSError, subprocess.TimeoutExpired):
            raise BridgeError(f"git {args[0]} could not run or timed out") from None
        if p.returncode != 0:
            raise BridgeError((p.stderr or p.stdout).strip()[-400:] or f"git {args[0]} failed")
        return p.stdout.strip()

    def not_updatable(self) -> str:
        """Why bridge.update is refused, or "" when this install can update itself: it came from
        a git checkout of the AgentGram repository and its user may replace the installed file."""
        if not self.source or not (Path(self.source) / ".git").exists():
            return "it was not installed from a git checkout"
        if not os.access(self.path.parent, os.W_OK):
            return "its files belong to another user (run install.sh once more)"
        try:
            url = self.git("remote", "get-url", "origin", timeout=10)
        except BridgeError:
            return "the checkout has no origin"
        if url.rstrip("/") not in SOURCE_URLS:
            return "the checkout's origin is not the AgentGram repository"
        return ""

    # -- agent turns

    def turn(self, profile, session_key, text, stream, session_id=""):
        """Runs one agent turn, feeding `stream`. Returns {output, status, session, run}."""
        body = {"input": text, **({"session_id": session_id} if session_id else {})}
        accepted = self.http(profile, "POST", "/v1/runs", body, {"X-Hermes-Session-Key": session_key})
        run = accepted["run_id"]
        self.runs[run] = profile
        stream.run = run
        stream.push(force=True)
        events = queue.Queue()

        def read():
            try:
                with self.http(profile, "GET", f"/v1/runs/{run}/events", timeout=900, stream=True) as resp:
                    for line in resp:
                        if line.startswith(b"data:"):
                            events.put(json.loads(line[5:]))
            except Exception:
                pass
            events.put(None)

        threading.Thread(target=read, daemon=True).start()
        final = {}
        try:
            while True:
                try:
                    ev = events.get(timeout=1)
                except queue.Empty:
                    stream.push()
                    continue
                if ev is None:
                    break
                name = ev.get("event", "")
                if name == "message.delta":
                    stream.text += ev.get("delta", "")
                    stream.approval = None
                elif name == "tool.started":
                    stream.tools.append({"id": ev.get("tool_call_id", ""), "tool": ev.get("tool", ""),
                                         "preview": (ev.get("preview") or "")[:80], "state": "running"})
                elif name == "tool.completed":
                    stream.approval = None
                    for t in stream.tools:
                        if t["id"] == ev.get("tool_call_id", "") and t["state"] == "running":
                            t["state"] = "error" if ev.get("error") else "done"
                elif name == "approval.request":
                    stream.approval = {
                        "request_id": ev.get("prompt_id", ""), "generation": ev.get("execution_generation", 0),
                        "command": (ev.get("command") or "")[:300], "description": (ev.get("description") or "")[:200],
                        "choices": ev.get("choices") or ["once", "deny"]}
                    stream.push(force=True)
                elif name in ("approval.settled", "approval.responded"):
                    stream.approval = None
                elif name.startswith("run.") and name not in ("run.steered", "run.stopping"):
                    final = ev
                stream.dirty = True
                stream.push()
        finally:
            self.runs.pop(run, None)
        status = self.http(profile, "GET", f"/v1/runs/{run}")
        state = status.get("status") or final.get("event", "run.failed")[4:]
        output = (final.get("output") or status.get("output") or stream.text).strip()
        if state != "completed" and not output:
            output = f"_Run {state}: {final.get('error') or status.get('error') or 'no output'}_"
        return {"output": output, "status": state, "session": status.get("session_id", ""), "run": run}

    # -- group state

    def groups(self) -> dict:
        try:
            return json.loads((self.state / "groups.json").read_text())
        except (OSError, ValueError):
            return {}

    def save_groups(self, groups):
        tmp = self.state / "groups.json.tmp"
        tmp.write_text(json.dumps(groups))
        tmp.replace(self.state / "groups.json")

    def profile_names(self) -> list:
        """Every profile on disk; unlike `hermes profile list` this costs no subprocess."""
        folder = self.home / "profiles"
        names = sorted(p.name for p in folder.iterdir() if p.is_dir() and NAME_RE.match(p.name)) if folder.is_dir() else []
        return ["default"] + names

    def tz_offset(self, profile) -> int:
        """Seconds east of UTC of the zone Hermes evaluates this profile's cron expressions in:
        `timezone:` in its config.yaml, else the server's local zone (hermes_time.py)."""
        try:
            text = (self.profile_dir(profile) / "config.yaml").read_text()
            m = re.search(r"(?m)^timezone:[ \t]*[\"']?([A-Za-z0-9_+/-]+)", text)
            if m:
                return int(datetime.now(ZoneInfo(m[1])).utcoffset().total_seconds())
        except Exception:
            pass  # unreadable config or unknown zone: Hermes falls back to server time too
        return int(datetime.now().astimezone().utcoffset().total_seconds())

    def file_roots(self, profile):
        return [self.state / "inbox" / profile, self.profile_dir(profile) / "workspace",
                self.home / "kanban" / "workspaces"]


class Ctx:
    def __init__(self, bridge, chat, rid, doc):
        self.bridge, self.chat, self.rid, self.doc = bridge, chat, rid, doc


class Stream:
    """One in-place edited Telegram message per text segment, at most one edit a second."""

    def __init__(self, ctx, who="", n=0):
        self.ctx, self.who, self.n = ctx, who, n   # n: which turn of this request (groups have several)
        self.text, self.off, self.seq = "", 0, 0
        self.tools, self.approval, self.run = [], None, ""
        self.msg, self.last, self.dirty = None, 0.0, True

    def frame(self, text, tools):
        self.seq += 1
        return {"v": 1, "re": self.ctx.rid, "stream": {
            "seq": self.seq, "off": self.off, "text": text, "tools": tools,
            "approval": self.approval, "run": self.run, "who": self.who, "n": self.n}}

    def push(self, force=False):
        if not self.dirty or (not force and time.time() - self.last < 1.0):
            return
        b = self.ctx.bridge
        while True:
            segment = self.text[self.off:]
            cut, tools = split_bytes(segment, SEGMENT_BYTES), self.tools[-5:]
            while True:
                body = to_text(seal(b.key, self.frame(segment[:cut], tools)))
                if len(body) <= TEXT_LIMIT:
                    break
                # Too big for one message: shed older tool lines, then text (it moves to the
                # next segment). An approval alone always fits, so this ends.
                if len(tools) > 1:
                    tools = tools[1:]
                elif cut > 256:
                    cut //= 2
                else:
                    tools = []
            try:
                if self.msg is None:
                    self.msg = b.tg.call("sendMessage", chat_id=self.ctx.chat, text=body,
                                         disable_notification=True)["message_id"]
                    with b.lock:
                        b.sent.append((time.time(), self.msg))
                else:
                    b.tg.call("editMessageText", chat_id=self.ctx.chat, message_id=self.msg, text=body)
            except BridgeError as e:
                print(f"stream update failed: {e}", file=sys.stderr, flush=True)
            if cut == len(segment):
                break
            self.off += cut   # this message is full: freeze it and continue in a new one
            self.msg = None
        self.last, self.dirty = time.time(), False


SENT = object()  # handler already replied


def _name(args, key="profile"):
    name = str(args.get(key) or "")
    if name != "default" and not NAME_RE.match(name):
        raise BridgeError(f"invalid {key}")
    return name


def _board(args):
    board = args.get("board")
    if board and not NAME_RE.match(str(board)):
        raise BridgeError("invalid board")
    return ["--board", board] if board else []


def _task(args):
    task = str(args.get("id") or "")
    if not re.match(r"^[A-Za-z0-9_-]{1,64}$", task):
        raise BridgeError("invalid task id")
    return task


def op_hello(b, args, ctx):
    try:
        with urllib.request.urlopen(b.api + "/health", timeout=5) as resp:
            api = json.load(resp).get("status") == "ok"
    except Exception:
        api = False
    version = b.hermes("--version", check=False).splitlines()
    return {"bridge": VERSION, "hermes": version[0] if version else "", "api": api,
            "source": b.source, "updatable": not b.not_updatable()}


def op_bridge_update(b, args, ctx):
    """Fast-forwards the checkout this bridge was installed from and installs its bridge.py over
    the running one. The process then exits and systemd starts the new code."""
    why = b.not_updatable()
    if why:
        raise BridgeError(f"this bridge cannot update itself: {why}")
    b.git("pull", "--ff-only")
    new = b.path.with_name(".bridge.py.new")
    new.write_bytes((Path(b.source) / "hermes-bridge" / "bridge.py").read_bytes())
    try:
        if new.read_bytes() == b.path.read_bytes():
            return {"version": VERSION, "updated": False}
        # The copy must at least start before it replaces the bridge that can still be reached.
        try:
            p = subprocess.run([sys.executable, str(new), "--version"], capture_output=True, text=True,
                               timeout=30, stdin=subprocess.DEVNULL)
            version = p.stdout.strip() if p.returncode == 0 else ""
        except (OSError, subprocess.TimeoutExpired):
            version = ""
        if not re.fullmatch(r"\d+(\.\d+){1,3}", version):
            raise BridgeError("the pulled bridge.py does not start; the running bridge was kept")
        os.chmod(new, 0o755)
        os.replace(new, b.path)
    finally:
        new.unlink(missing_ok=True)
    return {"version": version, "updated": True}   # handle() restarts once this is sent


def profile_model(config_text: str):
    """model.default from a profile's config.yaml (the list table truncates long names)."""
    m = re.search(r"(?m)^model:[ \t]*\n(?:[ \t]+.*\n)*?[ \t]+default:[ \t]*[\"']?([^\"'\n#]+)", config_text + "\n")
    return m[1].strip() if m else None


def op_profiles(b, args, ctx):
    rows = parse_profile_list(b.hermes("profile", "list"))
    for row in rows:
        row["description"] = ""
        try:
            path = b.profile_dir(row["name"])
            row["model"] = profile_model((path / "config.yaml").read_text()) or row["model"]
            m = re.search(r"^description:\s*(.*(?:\n[ \t]+.*)*)", (path / "profile.yaml").read_text(), re.M)
            desc = " ".join(m[1].split()) if m else ""
            row["description"] = desc[1:-1].replace("''", "'") if desc[:1] == "'" and desc[-1:] == "'" else desc
        except (OSError, BridgeError):
            pass
    return {"profiles": rows}


def op_models(b, args, ctx):
    models = []
    try:
        options = b.http("default", "GET", "/api/model/options")
        for p in options.get("providers", []):
            if p.get("is_current"):
                models += p.get("models") or []
        if options.get("model"):
            models.append(options["model"])
    except BridgeError:
        pass
    models += [p["model"] for p in op_profiles(b, {}, ctx)["profiles"]]
    return {"models": sorted(set(models))}


def op_toolsets(b, args, ctx):
    data = b.http("default", "GET", "/v1/toolsets").get("data", [])
    return {"toolsets": [{"name": t["name"], "label": t.get("label", t["name"]),
                          "enabled": bool(t.get("enabled"))} for t in data]}


def op_profile_create(b, args, ctx):
    name, source = str(args.get("name") or ""), _name(args, "clone_from") if args.get("clone_from") else "default"
    if not NAME_RE.match(name) or name == "default":
        raise BridgeError("name must be lowercase letters, digits and dashes")
    if (b.home / "profiles" / name).exists():
        raise BridgeError(f"profile {name} already exists")
    b.profile_dir(source)
    model = str(args.get("model") or "")
    if model and not re.match(r"^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,120}$", model):
        raise BridgeError("invalid model name")
    workdir = args.get("workdir")
    if workdir and not (os.path.isabs(workdir) and os.path.isdir(workdir)):
        raise BridgeError("working directory must be an existing absolute path on the Hermes host")
    cmd = ["profile", "create", name, "--clone-from", source, "--no-alias"]
    if args.get("description"):
        cmd += ["--description=" + str(args["description"])]
    b.hermes(*cmd, timeout=300)
    path = b.profile_dir(name)
    if args.get("soul"):
        (path / "SOUL.md").write_text(str(args["soul"]).strip() + "\n")
    if args.get("model"):
        b.hermes("config", "set", "model.default", str(args["model"]), profile=name)
    if workdir:
        b.hermes("config", "set", "terminal.cwd", workdir, profile=name)
    if isinstance(args.get("toolsets"), list):
        known = {t["name"] for t in op_toolsets(b, {}, ctx)["toolsets"]}
        on = [t for t in args["toolsets"] if t in known]
        off = sorted(known - set(on))
        if on:
            b.hermes("tools", "enable", "--platform", "api_server", *on, profile=name)
        if off:
            b.hermes("tools", "disable", "--platform", "api_server", *off, profile=name)
    b.api_key(name)
    return {"name": name}


def op_profile_delete(b, args, ctx):
    name = _name(args, "name")
    if name == "default":
        raise BridgeError("the default profile cannot be deleted")
    b.profile_dir(name)
    op_profile_stop(b, {"name": name}, ctx)
    b.hermes("profile", "delete", name, "-y", timeout=300)
    groups = b.groups()
    for g in groups.values():
        g["members"] = [m for m in g["members"] if m != name]
    b.save_groups(groups)
    return {"name": name}


def op_profile_stop(b, args, ctx):
    name = _name(args, "name")
    stopped = 0
    for run, profile in list(b.runs.items()):
        if profile == name:
            try:
                b.http(profile, "POST", f"/v1/runs/{run}/stop", {})
                stopped += 1
            except BridgeError:
                pass
    return {"stopped": stopped}


def op_gateway_restart(b, args, ctx):
    # One gateway serves every profile, so this interrupts all of them.
    out = b.hermes("gateway", "restart", "-y", timeout=180)
    return {"output": out.strip()[-500:]}


def _text_with_files(args) -> str:
    text = str(args.get("text") or "").strip()
    files = [str(f) for f in args.get("files") or []]
    if files:
        text += "\n\nAttached files (paths on this host):\n" + "\n".join(files)
    if not text.strip():
        raise BridgeError("empty message")
    return text


def op_chat_send(b, args, ctx):
    profile, text = _name(args), _text_with_files(args)
    session = str(args.get("session") or f"agentgram:{profile}")
    session_id = str(args.get("session_id") or "")
    if session_id and not re.match(r"^[A-Za-z0-9_.:-]{1,256}$", session_id):
        raise BridgeError("invalid session")
    stream = Stream(ctx, profile)
    result = b.turn(profile, session, text, stream, session_id)
    stream.push(force=True)
    return result


def op_run_stop(b, args, ctx):
    return b.http(_name(args), "POST", f"/v1/runs/{_run(args)}/stop", {})


def op_run_steer(b, args, ctx):
    return b.http(_name(args), "POST", f"/v1/runs/{_run(args)}/steer", {"text": str(args.get("text") or "")})


def op_approval(b, args, ctx):
    choice = str(args.get("choice"))
    if choice not in ("once", "session", "always", "deny"):
        raise BridgeError("invalid choice")
    return b.http(_name(args), "POST", f"/v1/runs/{_run(args)}/approval", {
        "request_id": str(args.get("request_id")), "execution_generation": int(args.get("generation") or 0),
        "choice": choice})


def _run(args):
    run = str(args.get("run") or "")
    if not re.match(r"^run_[0-9a-f]{8,64}$", run):
        raise BridgeError("invalid run id")
    return run


def op_sessions(b, args, ctx):
    data = b.http(_name(args), "GET", "/api/sessions?limit=30").get("data", [])
    return {"sessions": [{"id": s["id"], "title": s.get("title") or s.get("preview") or s["id"],
                          "last_active": s.get("last_active") or 0, "messages": s.get("message_count", 0)}
                         for s in data]}


def op_session_messages(b, args, ctx):
    session = str(args.get("session") or "")
    if not re.match(r"^[A-Za-z0-9_.:-]{1,256}$", session):
        raise BridgeError("invalid session")
    data = b.http(_name(args), "GET", f"/api/sessions/{session}/messages").get("data", [])
    out = []
    for m in data:
        content = m.get("content")
        if m.get("role") in ("user", "assistant") and isinstance(content, str) and content.strip():
            out.append({"role": m["role"], "text": content[:20000], "ts": float(m.get("timestamp") or 0)})
    return {"messages": out[-100:]}


def _kanban_json(b, args, *cmd):
    return json.loads(b.hermes("kanban", *_board(args), *cmd, "--json") or "null")


def op_kanban_boards(b, args, ctx):
    boards = json.loads(b.hermes("kanban", "boards", "list", "--json") or "[]")
    return {"boards": [{"slug": x["slug"], "name": x.get("name") or x["slug"], "total": x.get("total", 0),
                        "current": bool(x.get("is_current"))} for x in boards]}


def op_kanban_list(b, args, ctx):
    tasks = _kanban_json(b, args, "list") or []
    keep = ("id", "title", "assignee", "status", "priority", "created_at", "completed_at")
    return {"tasks": [{k: t.get(k) for k in keep} for t in tasks]}


def op_kanban_show(b, args, ctx):
    return _kanban_json(b, args, "show", _task(args))


def op_kanban_create(b, args, ctx):
    title = str(args.get("title") or "").strip()
    if not title:
        raise BridgeError("title is required")
    cmd = ["create", "--created-by", "agentgram"]
    if args.get("body"):
        cmd += ["--body=" + str(args["body"])]   # "=" form: the value may start with a dash
    if args.get("assignee"):
        cmd += ["--assignee", _name(args, "assignee")]
    for parent in args.get("parents") or []:
        cmd += ["--parent", _task({"id": parent})]
    # "--" so a title starting with a dash is not read as an option.
    return json.loads(b.hermes("kanban", *_board(args), *cmd, "--json", "--", title) or "null")


def _kanban_do(command):
    def op(b, args, ctx):
        out = b.hermes("kanban", *_board(args), *command(args))
        return {"output": out.strip()[-300:]}
    return op


op_kanban_assign = _kanban_do(lambda a: ["assign", _task(a), _name(a, "assignee") if a.get("assignee") else "none"])
op_kanban_comment = _kanban_do(lambda a: ["comment", "--author", "user", "--", _task(a), str(a.get("text") or "")])
op_kanban_complete = _kanban_do(lambda a: ["complete", _task(a)] + (["--result=" + str(a["text"])] if a.get("text") else []))
op_kanban_block = _kanban_do(lambda a: ["block", "--", _task(a)] + ([str(a["text"])] if a.get("text") else []))
op_kanban_unblock = _kanban_do(lambda a: ["unblock", _task(a)])


def op_groups(b, args, ctx):
    return {"groups": [{k: g[k] for k in ("id", "name", "members", "mode")} for g in b.groups().values()]}


def op_group_save(b, args, ctx):
    members = [_name({"profile": m}) for m in args.get("members") or []]
    name = str(args.get("name") or "").strip()[:80]
    if not name or not members:
        raise BridgeError("a group needs a name and at least one member")
    for m in members:
        b.profile_dir(m)
    with b.lock:
        groups = b.groups()
        gid = str(args.get("id") or "") or "g" + secrets.token_hex(4)
        old = groups.get(gid, {})
        groups[gid] = {"id": gid, "name": name, "members": members,
                       "mode": "lead" if args.get("mode") == "lead" else "all",
                       "transcript": old.get("transcript", []), "seen": old.get("seen", {})}
        b.save_groups(groups)
    return {k: groups[gid][k] for k in ("id", "name", "members", "mode")}


def op_group_delete(b, args, ctx):
    with b.lock:
        groups = b.groups()
        if groups.pop(str(args.get("id")), None) is None:
            raise BridgeError("no such group")
        b.save_groups(groups)
    return {}


def op_group_history(b, args, ctx):
    group = b.groups().get(str(args.get("id")))
    if group is None:
        raise BridgeError("no such group")
    return {"messages": group["transcript"][-200:]}


def op_group_send(b, args, ctx):
    gid, text = str(args.get("id")), _text_with_files(args)

    def update(change):
        with b.lock:
            groups = b.groups()
            if gid not in groups:
                raise BridgeError("no such group")
            change(groups[gid])
            b.save_groups(groups)
            return groups[gid]

    group = update(lambda g: g["transcript"].append({"who": "user", "text": text, "ts": time.time()}))
    todo, hops, replies = route(text, group["members"], group["mode"]), 0, []
    while todo:
        member = todo.pop(0)
        if member not in group["members"]:
            continue
        stream = Stream(ctx, member, len(replies))
        try:
            result = b.turn(member, f"agentgram:group:{gid}:{member}", group_prompt(group, member), stream)
        except BridgeError as e:
            result = {"output": f"_{member} failed: {e}_", "status": "failed"}
        stream.dirty = True
        stream.push(force=True)

        def record(g, member=member, output=result["output"]):
            g["transcript"].append({"who": member, "text": output, "ts": time.time()})
            g["seen"][member] = len(g["transcript"])
        group = update(record)
        replies.append({"who": member, "text": result["output"], "status": result["status"]})
        # Relay to members the reply mentions; the hop budget is the loop guard.
        for other in mentions(result["output"], group["members"]):
            if other != member and other not in todo and hops < MAX_HOPS and result["status"] == "completed":
                todo.append(other)
                hops += 1
    return {"replies": replies}


def op_file_put(b, args, ctx):
    if not ctx.doc:
        raise BridgeError("file.put needs a document")
    if ctx.doc.get("file_size", 0) > 20 * 1024 * 1024:
        raise BridgeError("file too large (bots can fetch at most 20 MB)")
    profile = _name(args)
    name = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(str(args.get("name") or "file")))[:120] or "file"
    folder = b.state / "inbox" / profile
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f"{int(time.time())}-{name}"
    path.write_bytes(b.tg.download(ctx.doc["file_id"]))
    return {"path": str(path)}


def _walk(root: Path):
    """Regular, non-hidden files under root. Hidden and dependency folders are not entered."""
    seen = 0
    for folder, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in SKIP_DIRS]
        for name in names:
            path = Path(folder) / name
            if name.startswith(".") or path.is_symlink() or not path.is_file():
                continue
            seen += 1
            if seen > WALK_LIMIT:
                return  # shortcut: a huge tree is cut off, not sorted first; page it if this bites
            yield path


def op_files_list(b, args, ctx):
    """One profile's files, or (no `profile`) every profile's plus the kanban workspaces: the
    Library asks once instead of once per profile."""
    if args.get("profile"):
        roots = [(_name(args), source, root) for source, root in zip(("sent", "workspace"), b.file_roots(_name(args)))]
    else:
        roots = [(p, source, root) for p in b.profile_names()
                 for source, root in zip(("sent", "workspace"), b.file_roots(p))]
        roots.append(("default", "board", b.home / "kanban" / "workspaces"))
    files = []
    for profile, source, root in roots:
        for path in _walk(root) if root.is_dir() else []:
            st = path.stat()
            files.append({"path": str(path), "name": path.name, "size": st.st_size, "mtime": int(st.st_mtime),
                          "profile": profile, "source": source})
    files.sort(key=lambda f: -f["mtime"])
    return {"files": files[:500 if not args.get("profile") else 200]}


def op_files_get(b, args, ctx):
    path = Path(str(args.get("path") or "")).resolve()
    roots = [r.resolve() for r in b.file_roots(_name(args))]
    if not any(path.is_relative_to(r) for r in roots) or not path.is_file():
        raise BridgeError("file is outside this bot's workspace")
    if path.stat().st_size > MAX_FILE:
        raise BridgeError("file too large to send over Telegram")
    caption = to_text(seal(b.key, {"v": 1, "re": ctx.rid, "ok": True, "data": {"name": path.name}}))
    msg = b.tg.upload(ctx.chat, path.name, path.read_bytes(), caption)
    with b.lock:
        b.sent.append((time.time(), msg["message_id"]))
    return SENT


def op_activity(b, args, ctx):
    profile = _name(args)
    row = next((p for p in op_profiles(b, {}, ctx)["profiles"] if p["name"] == profile), {})
    try:
        tasks = json.loads(b.hermes("kanban", "list", "--assignee", profile, "--status", "running", "--json") or "[]")
    except (BridgeError, ValueError):
        tasks = []
    log = ""
    log_path = b.profile_dir(profile) / "logs" / "agent.log"
    if log_path.is_file():
        with open(log_path, "rb") as f:
            f.seek(max(0, log_path.stat().st_size - 6000))
            log = "\n".join(f.read().decode(errors="replace").splitlines()[1:][-40:])
    return {"gateway": row.get("gateway", "unknown"), "model": row.get("model", ""),
            "runs": [r for r, p in b.runs.items() if p == profile],
            "tasks": [{"id": t["id"], "title": t["title"]} for t in tasks], "log": log}


# -- scheduled jobs (Hermes cron; each profile has its own job store behind /p/<profile>/api/jobs)

def _epoch(iso):
    try:
        return datetime.fromisoformat(iso).timestamp() if iso else None
    except (TypeError, ValueError):
        return None


def _job(profile, j):
    """The part of a Hermes job the app shows; origin (chat ids) and internals stay on the host."""
    s = j.get("schedule") or {}
    deliver = j.get("deliver")
    return {"id": j["id"], "profile": profile, "name": j.get("name") or j["id"], "prompt": j.get("prompt") or "",
            "kind": s.get("kind") or "", "expr": s.get("expr") or "", "minutes": int(s.get("minutes") or 0),
            "display": j.get("schedule_display") or s.get("display") or "",
            "enabled": bool(j.get("enabled")), "state": j.get("state") or "",
            "next_run": _epoch(j.get("next_run_at")), "last_run": _epoch(j.get("last_run_at")),
            "last_status": j.get("last_status") or "", "last_error": j.get("last_error") or "",
            "deliver": ",".join(map(str, deliver)) if isinstance(deliver, list) else str(deliver or "local"),
            "script": j.get("script") or "", "no_agent": bool(j.get("no_agent"))}


def _job_id(args):
    job = str(args.get("id") or "")
    if not JOB_RE.match(job):
        raise BridgeError("invalid job id")
    return job


def _job_fields(args, required=False):
    """name / schedule / prompt / deliver as the jobs API takes them."""
    body = {}
    for key, limit in (("name", 200), ("schedule", 200), ("prompt", 5000), ("deliver", 200)):
        if key in args:
            value = str(args[key]).strip()
            if len(value) > limit:
                raise BridgeError(f"{key} is too long (max {limit} characters)")
            body[key] = value
    if required and not (body.get("name") and body.get("schedule")):
        raise BridgeError("a schedule needs a name and a schedule")
    if "deliver" in body and not re.match(r"^[A-Za-z0-9_:,@.-]{1,200}$", body["deliver"]):
        raise BridgeError("invalid delivery target")
    return body


def op_jobs_list(b, args, ctx):
    jobs, errors = [], []
    for profile in b.profile_names():
        # A profile that never had a job has no store; skipping it also avoids minting API keys.
        if not (b.profile_dir(profile) / "cron" / "jobs.json").is_file():
            continue
        try:
            data = b.http(profile, "GET", "/api/jobs?include_disabled=true")
            jobs += [_job(profile, j) for j in data.get("jobs") or []]
        except BridgeError as e:
            errors.append(f"{profile}: {e}")
    return {"jobs": jobs, "errors": errors, "offsets": {p: b.tz_offset(p) for p in b.profile_names()}}


def op_jobs_create(b, args, ctx):
    profile, body = _name(args), _job_fields(args, required=True)
    body.setdefault("deliver", "local")
    if args.get("paused"):
        body["paused"] = True
    return _job(profile, b.http(profile, "POST", "/api/jobs", body)["job"])


def op_jobs_update(b, args, ctx):
    profile, job, body = _name(args), _job_id(args), _job_fields(args)
    if not body:
        raise BridgeError("nothing to change")
    return _job(profile, b.http(profile, "PATCH", f"/api/jobs/{job}", body)["job"])


def op_jobs_delete(b, args, ctx):
    b.http(_name(args), "DELETE", f"/api/jobs/{_job_id(args)}")
    return {}


def _job_action(action):
    def op(b, args, ctx):
        profile = _name(args)
        return _job(profile, b.http(profile, "POST", f"/api/jobs/{_job_id(args)}/{action}", {})["job"])
    return op


def op_jobs_output(b, args, ctx):
    """The newest saved run of a job (cron/output/<id>/<time>.md): the response part of it."""
    folder = b.profile_dir(_name(args)) / "cron" / "output" / _job_id(args)
    runs = sorted(p for p in folder.glob("*.md") if p.is_file()) if folder.is_dir() else []
    if not runs:
        return {"file": "", "ts": None, "text": ""}
    text = runs[-1].read_text(errors="replace")
    _, found, response = text.partition("\n## Response\n")
    text = response.strip() if found else text
    return {"file": runs[-1].name, "ts": runs[-1].stat().st_mtime, "runs": len(runs),
            "text": text if len(text) <= 20000 else "…" + text[-20000:]}


OPS = {
    "hello": op_hello, "profiles.list": op_profiles, "models.list": op_models, "toolsets.list": op_toolsets,
    "profile.create": op_profile_create, "profile.clone": op_profile_create, "profile.delete": op_profile_delete,
    "profile.stop": op_profile_stop, "gateway.restart": op_gateway_restart,
    "chat.send": op_chat_send, "run.stop": op_run_stop, "run.steer": op_run_steer, "approval.respond": op_approval,
    "sessions.list": op_sessions, "session.messages": op_session_messages,
    "kanban.boards": op_kanban_boards, "kanban.list": op_kanban_list, "kanban.show": op_kanban_show,
    "kanban.create": op_kanban_create, "kanban.assign": op_kanban_assign, "kanban.comment": op_kanban_comment,
    "kanban.complete": op_kanban_complete, "kanban.block": op_kanban_block, "kanban.unblock": op_kanban_unblock,
    "groups.list": op_groups, "groups.save": op_group_save, "groups.delete": op_group_delete,
    "group.send": op_group_send, "group.history": op_group_history,
    "file.put": op_file_put, "files.list": op_files_list, "files.get": op_files_get, "activity": op_activity,
    "jobs.list": op_jobs_list, "jobs.create": op_jobs_create, "jobs.update": op_jobs_update,
    "jobs.delete": op_jobs_delete, "jobs.pause": _job_action("pause"), "jobs.resume": _job_action("resume"),
    "jobs.run": _job_action("run"), "jobs.output": op_jobs_output,
    "bridge.update": op_bridge_update,
}
WRITES = {"profile.create", "profile.clone", "profile.delete", "profile.stop", "gateway.restart",
          "run.stop", "run.steer", "approval.respond", "kanban.create", "kanban.assign", "kanban.comment",
          "kanban.complete", "kanban.block", "kanban.unblock", "groups.save", "groups.delete", "file.put",
          "chat.send", "group.send",
          "jobs.create", "jobs.update", "jobs.delete", "jobs.pause", "jobs.resume", "jobs.run",
          "bridge.update"}


if __name__ == "__main__":
    if sys.argv[1:] == ["--version"]:
        print(VERSION)
        raise SystemExit(0)
    missing = [k for k in ("AG_BOT_TOKEN", "AG_USER_ID", "AG_KEY") if not os.environ.get(k)]
    if missing:
        raise SystemExit("missing environment: " + ", ".join(missing))
    Bridge().run()
