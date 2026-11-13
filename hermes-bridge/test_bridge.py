"""Bridge tests. `python3 -m unittest` runs against a fake Telegram and a fake Hermes.

Set AG_LIVE_HERMES_HOME (and optionally AG_LIVE_API) to also run the same client against a real
Hermes home: the fake Telegram stays, everything behind the bridge is real.
"""
import base64
import json
import os
import re
import stat
import tempfile
import threading
import time
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import bridge as B

FIX = Path(__file__).parent / "fixtures"
KEY = bytes(range(32))
USER = 4242


def serve(handler):
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


class FakeTelegram:
    """Just enough of the Bot API: updates in, messages/edits/deletes/documents out."""

    def __init__(self):
        self.updates, self.messages, self.files, self.deleted = [], {}, {}, []
        self.next_id, self.cond = 100, threading.Condition()
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):  # file download
                data = fake.files.get(self.path.rsplit("/", 1)[-1], b"")
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                method = self.path.rsplit("/", 1)[-1]
                if method == "sendDocument":
                    boundary = self.headers["Content-Type"].split("boundary=")[1].encode()
                    fields = {}
                    for part in body.split(b"--" + boundary)[1:-1]:
                        head, _, value = part.partition(b"\r\n\r\n")
                        name = re.search(rb'name="([^"]+)"', head)[1].decode()
                        fields[name] = value[:-2]
                        if b"filename=" in head:
                            fields["file_name"] = re.search(rb'filename="([^"]+)"', head)[1].decode()
                    result = fake.add(caption=fields["caption"].decode(), data=fields["document"],
                                      file_name=fields["file_name"])
                else:
                    result = getattr(fake, method)(**json.loads(body))
                out = json.dumps({"ok": True, "result": result}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)

        self.server, self.url = serve(Handler)

    def add(self, **message):
        with self.cond:
            self.next_id += 1
            self.messages[self.next_id] = message
            self.cond.notify_all()
            return {"message_id": self.next_id}

    def getUpdates(self, offset=0, timeout=0, **_):
        with self.cond:
            self.cond.wait_for(lambda: any(u["update_id"] >= offset for u in self.updates), timeout=1)
            return [u for u in self.updates if u["update_id"] >= offset]

    def sendMessage(self, chat_id, text, **_):
        assert len(text) <= 4096, "Telegram would reject this message"
        return self.add(text=text)

    def editMessageText(self, chat_id, message_id, text):
        assert len(text) <= 4096
        with self.cond:
            self.messages[message_id]["text"] = text
            self.cond.notify_all()
        return True

    def deleteMessage(self, chat_id, message_id):
        self.deleted.append(message_id)
        return True

    def getFile(self, file_id):
        return {"file_path": file_id}

    def push(self, sender=USER, **message):
        with self.cond:
            self.next_id += 1
            self.updates.append({"update_id": self.next_id, "message": {
                "message_id": self.next_id, "from": {"id": sender},
                "chat": {"id": sender, "type": "private"}, **message}})
            self.cond.notify_all()
            return self.next_id

    def frames(self, key=KEY):
        """Every decodable frame the bot has sent, with its message."""
        out = []
        with self.cond:
            items = list(self.messages.items())
        for mid, m in items:
            try:
                raw = B.from_text(m.get("text") or m.get("caption") or "") if (m.get("text") or m.get("caption")) else m["data"]
                out.append((mid, B.unseal(key, raw), m))
            except Exception:
                pass
        return out


class Client:
    def __init__(self, tg, key=KEY):
        self.tg, self.key = tg, key

    def send(self, op, args=None, **message):
        rid = uuid.uuid4().hex
        frame = B.to_text(B.seal(self.key, {"v": 1, "id": rid, "ts": time.time(), "op": op, "args": args or {}}))
        key = "caption" if "document" in message else "text"
        return rid, self.tg.push(**{key: frame}, **message)

    def wait(self, rid, timeout=20):
        deadline = time.time() + timeout
        while time.time() < deadline:
            for _, frame, m in self.tg.frames(self.key):
                if frame.get("re") == rid and "ok" in frame:
                    return frame, m
            time.sleep(0.05)
        raise AssertionError("no reply")

    def call(self, op, args=None, timeout=20, **message):
        rid, _ = self.send(op, args, **message)
        frame, _ = self.wait(rid, timeout)
        if not frame["ok"]:
            raise AssertionError(frame["error"])
        return frame["data"]

    def streams(self, rid):
        return [f["stream"] for _, f, _ in self.tg.frames(self.key) if f.get("re") == rid and "stream" in f]


def assemble(streams, who=None):
    """What the app does: later segments overwrite the text from their offset."""
    text = ""
    for s in sorted((s for s in streams if who in (None, s["who"])), key=lambda s: s["off"]):
        text = text[:s["off"]] + s["text"]
    return text


class FakeHermes:
    """Replays the SSE captured from a real gateway (fixtures/) behind the same auth rules."""

    def __init__(self, key):
        self.key, self.requests, self.replies = key, [], {}
        # The default profile's jobs as a real gateway listed them; other profiles start empty.
        self.jobs = {"default": {j["id"]: j for j in json.loads((FIX / "jobs_list.json").read_text())["jobs"]}}
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def respond(self, code, obj):
                out = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)

            def handle_any(self):
                if self.path == "/health":
                    return self.respond(200, {"status": "ok"})
                if self.headers.get("Authorization") != f"Bearer {fake.key}":
                    return self.respond(401, {"error": {"message": "Invalid gateway API key"}})
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length)) if length else None
                profile = self.path.split("/")[2] if self.path.startswith("/p/") else "default"
                path = re.sub(r"^/p/[^/]+", "", self.path)
                fake.requests.append((profile, self.command, path, body))
                if path == "/v1/runs":
                    run = "run_" + uuid.uuid4().hex
                    fake.replies[run] = fake.answer(profile, body["input"])
                    return self.respond(202, {"run_id": run, "status": "started"})
                m = re.match(r"^/v1/runs/(run_\w+)(/events)?$", path)
                if m and m[2]:
                    self.send_response(200)
                    self.end_headers()
                    sse = fake.replies[m[1]]
                    self.wfile.write(sse if isinstance(sse, bytes) else fake.sse(m[1], sse))
                    return
                if m:
                    reply = fake.replies[m[1]]
                    return self.respond(200, {"status": "completed", "session_id": "sess_1",
                                              "output": "" if isinstance(reply, bytes) else reply})
                m = re.match(r"^/api/jobs(?:/([a-f0-9]{12}))?(?:/(pause|resume|run))?(?:\?.*)?$", path)
                if m:
                    return self.respond(*fake.jobs_api(profile, self.command, m[1], m[2], body or {}))
                self.respond(200, {"ok": True})

            do_GET = do_POST = do_PATCH = do_DELETE = handle_any

        self.server, self.url = serve(Handler)

    def jobs_api(self, profile, method, job_id, action, body):
        """/api/jobs with the status codes and bodies of the real handlers (api_server.py)."""
        jobs = self.jobs.setdefault(profile, {})

        def schedule(text):
            m = re.match(r"^(?:every )?(\d+)([mh])$", text)
            if m:
                minutes = int(m[1]) * (60 if m[2] == "h" else 1)
                return {"kind": "interval", "minutes": minutes, "display": f"every {minutes}m"}
            if len(text.split()) == 5:
                return {"kind": "cron", "expr": text, "display": text}
            raise ValueError(f"Invalid schedule '{text}'. Use:\n  - Interval: '30m'")

        try:
            if job_id is None and method == "GET":
                return 200, {"jobs": list(jobs.values())}
            if job_id is None:
                if not body.get("name"):
                    return 400, {"error": "Name is required"}
                job = json.loads((FIX / "job_create.json").read_text())["job"]
                paused = bool(body.get("paused"))
                job.update(id=uuid.uuid4().hex[:12], name=body["name"], prompt=body.get("prompt", ""),
                           deliver=body.get("deliver", "local"), schedule=schedule(body["schedule"]),
                           enabled=not paused, state="paused" if paused else "scheduled")
                job["schedule_display"] = job["schedule"]["display"]
                jobs[job["id"]] = job
                return 200, {"job": job}
            job = jobs.get(job_id)
            if job is None:
                return 404, {"error": "Job not found"}
            if method == "DELETE":
                del jobs[job_id]
                return 200, {"ok": True}
            if method == "PATCH":
                if "schedule" in body:
                    body = dict(body, schedule=schedule(body["schedule"]))
                    job["schedule_display"] = body["schedule"]["display"]
                job.update(body)
            elif action == "pause":
                job.update(enabled=False, state="paused")
            elif action == "resume":
                job.update(enabled=True, state="scheduled", next_run_at="2026-11-13T11:08:24.071459+00:00")
            return 200, {"job": job}
        except ValueError as e:
            return 400, {"error": str(e)}

    def answer(self, profile, text):
        return (FIX / "run_approval.sse").read_bytes() if "approval" in text else (FIX / "run_events.sse").read_bytes()

    @staticmethod
    def sse(run, output):
        events = [{"event": "message.delta", "delta": output}, {"event": "run.completed", "output": output}]
        return "".join(f"id: {i}\ndata: {json.dumps(e)}\n\n" for i, e in enumerate(events)).encode()


def start_bridge(tg, home, api, hermes_bin="hermes", state=None):
    bridge = B.Bridge({
        "AG_KEY": base64.b64encode(KEY).decode(), "AG_USER_ID": str(USER), "AG_BOT_TOKEN": "1:test",
        "AG_TG_API": tg.url, "HERMES_HOME": str(home), "HERMES_API": api, "HERMES_BIN": hermes_bin,
        "AG_STATE": str(state or Path(home) / "agentgram-bridge"), "AG_POLL_SECONDS": "1"})
    threading.Thread(target=bridge.run, daemon=True).start()
    return bridge


class PureTests(unittest.TestCase):
    def test_frame_roundtrip_and_rejects_tampering(self):
        raw = B.seal(KEY, {"op": "hello", "text": "héllo 你好"})
        self.assertEqual(B.unseal(KEY, B.from_text(B.to_text(raw)))["text"], "héllo 你好")
        with self.assertRaises(Exception):
            B.unseal(KEY, raw[:-1] + bytes([raw[-1] ^ 1]))
        with self.assertRaises(Exception):
            B.unseal(bytes(32), raw)

    def test_known_vector_shared_with_swift(self):
        # Core/Tests/AgentCoreTests/BridgeTests.swift opens this same frame.
        frame = "AG1.AAECAwQFBgcICQoL8tl-IhMmiWLF5h3JunxsAOtckIg6VpfNlOJKuGsE0LCwLE9ZOZKkie593fY"
        self.assertEqual(B.unseal(KEY, B.from_text(frame)), {"v": 1, "re": "abc", "ok": True})

    def test_replay(self):
        r = B.Replay()
        r.check({"id": "a", "ts": 1000}, now=1000)
        with self.assertRaises(B.BridgeError):
            r.check({"id": "a", "ts": 1000}, now=1001)
        with self.assertRaises(B.BridgeError):
            r.check({"id": "b", "ts": 1000}, now=1000 + B.MAX_SKEW + 1)
        with self.assertRaises(B.BridgeError):
            r.check({"id": "", "ts": 1000}, now=1000)
        restarted = B.Replay(started=2000)   # a frame captured before a restart is not replayable
        with self.assertRaises(B.BridgeError):
            restarted.check({"id": "c", "ts": 1999}, now=2001)
        restarted.check({"id": "c", "ts": 2000.5}, now=2001)

    def test_routing(self):
        members = ["team-ceo", "team-cro", "team-qa"]
        self.assertEqual(B.mentions("ask @team-cro and @TEAM-QA, not @nobody or @team-cro", members), ["team-cro", "team-qa"])
        self.assertEqual(B.route("hi all", members, "all"), members)
        self.assertEqual(B.route("hi all", members, "lead"), ["team-ceo"])
        self.assertEqual(B.route("@team-qa check", members, "all"), ["team-qa"])

    def test_group_prompt_only_carries_unseen_lines(self):
        group = {"name": "team", "members": ["a", "b"], "seen": {"a": 1},
                 "transcript": [{"who": "user", "text": "old"}, {"who": "b", "text": "new"}]}
        prompt = B.group_prompt(group, "a")
        self.assertIn("[b]: new", prompt)
        self.assertNotIn("old", prompt)

    def test_profile_list_from_this_host(self):
        rows = B.parse_profile_list((FIX / "profile_list.txt").read_text())
        self.assertEqual(rows[0], {"name": "default", "model": "claude-sonnet-5-5", "gateway": "running", "default": True})
        self.assertIn("team-chief-researcher", [r["name"] for r in rows])
        self.assertEqual(len(rows), 17)

    def test_profile_model_from_config(self):
        config = "other:\n  default: no\nmodel:\n  provider: bedrock\n  default: \"global.anthropic.claude-haiku-5-5\"  # x\nz: 1\n"
        self.assertEqual(B.profile_model(config), "global.anthropic.claude-haiku-5-5")
        self.assertEqual(B.profile_model("model:\n  default: claude-sonnet-5-5"), "claude-sonnet-5-5")
        self.assertIsNone(B.profile_model("terminal:\n  default: x\n"))

    def test_job_envelope_matches_the_fixture_the_swift_tests_decode(self):
        raw = json.loads((FIX / "jobs_list.json").read_text())["jobs"]
        self.assertEqual([B._job("default", j) for j in raw], json.loads((FIX / "jobs_reply.json").read_text())["jobs"])

    def test_split_bytes_never_cuts_a_character(self):
        self.assertEqual(B.split_bytes("你好ab", 7), 3)
        self.assertEqual(B.split_bytes("abc", 10), 3)


class BridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        home = Path(cls.tmp.name)
        (home / "profiles" / "team-ceo").mkdir(parents=True)
        (home / "profiles" / "team-cro" / "workspace").mkdir(parents=True)
        (home / "profiles" / "team-cro" / "workspace" / "report.md").write_text("# report")
        (home / "profiles" / "team-cro" / ".env").write_text("LITELLM_API_KEY=never-leaves\n")
        (home / ".env").write_text("API_SERVER_KEY=k\n")
        cli = home / "hermes"
        cli.write_text(f"""#!/bin/sh
case "$*" in
  "profile list") cat {FIX}/profile_list.txt ;;
  "kanban list --json") cat {FIX}/kanban_list.json ;;
  "kanban --board command list --json") echo '[]' ;;
  "kanban show t_534e27fa --json") cat {FIX}/kanban_show.json ;;
  "kanban boards list --json") cat {FIX}/kanban_boards.json ;;
  "--version") echo "Hermes Agent v0.22.4" ;;
  *) echo "unexpected: $*" >&2; exit 2 ;;
esac
""")
        cli.chmod(cli.stat().st_mode | stat.S_IEXEC)
        cls.home, cls.tg = home, FakeTelegram()
        cls.hermes = FakeHermes("k")
        # Named profiles get their own key on first use; the fake accepts whatever is on disk.
        cls.bridge = start_bridge(cls.tg, home, cls.hermes.url, str(cli))
        cls.bridge.api_key = lambda profile: "k"
        cls.c = Client(cls.tg)

    @classmethod
    def tearDownClass(cls):
        cls.bridge.stopping = True
        cls.tmp.cleanup()

    def test_hello_and_request_is_deleted(self):
        rid, mid = self.c.send("hello")
        frame, _ = self.c.wait(rid)
        self.assertEqual(frame["data"], {"bridge": B.VERSION, "hermes": "Hermes Agent v0.22.4", "api": True})
        time.sleep(0.3)
        self.assertIn(mid, self.tg.deleted)

    def test_strangers_forgeries_and_replays_get_no_answer(self):
        before = len(self.tg.messages)
        good = B.to_text(B.seal(KEY, {"v": 1, "id": "x1", "ts": time.time(), "op": "hello"}))
        self.tg.push(sender=999, text=good)                                   # not the allow-listed user
        self.tg.push(text=B.to_text(B.seal(bytes(32), {"v": 1, "id": "x2", "ts": time.time(), "op": "hello"})))
        self.tg.push(text=B.to_text(B.seal(KEY, {"v": 1, "id": "x3", "ts": time.time() - 3600, "op": "hello"})))
        self.tg.push(text="hello bot")
        rid, _ = self.c.send("hello")
        self.c.wait(rid)
        time.sleep(0.5)
        self.assertEqual(len(self.tg.messages), before + 1)

    def test_profiles_and_kanban_read_real_fixtures(self):
        profiles = self.c.call("profiles.list")["profiles"]
        self.assertEqual(len(profiles), 17)
        tasks = self.c.call("kanban.list")["tasks"]
        self.assertEqual(tasks[0]["status"], "done")
        self.assertEqual(self.c.call("kanban.list", {"board": "command"})["tasks"], [])
        shown = self.c.call("kanban.show", {"id": "t_534e27fa"})   # too big for a message: document
        self.assertEqual(len(shown["comments"]), 3)
        self.assertEqual([b["slug"] for b in self.c.call("kanban.boards")["boards"]][:2], ["default", "command"])

    def test_chat_stream_then_final(self):
        rid, _ = self.c.send("chat.send", {"profile": "team-ceo", "session": "agentgram:team-ceo:1", "text": "hi"})
        frame, _ = self.c.wait(rid)
        self.assertEqual(frame["data"]["output"], "hello-from-hermes")
        self.assertEqual(frame["data"]["session"], "sess_1")
        streams = self.c.streams(rid)
        self.assertEqual(assemble(streams).strip(), "hello-from-hermes")
        self.assertEqual(streams[-1]["tools"][0]["state"], "done")
        profile, _, path, body = next(r for r in self.hermes.requests if r[2] == "/v1/runs" and r[3]["input"] == "hi")
        self.assertEqual((profile, path), ("team-ceo", "/v1/runs"))

    def test_approval_request_reaches_the_app_and_answer_reaches_hermes(self):
        rid, _ = self.c.send("chat.send", {"profile": "team-ceo", "text": "approval please"})
        self.c.wait(rid)
        data = self.c.call("approval.respond", {"profile": "team-ceo", "run": "run_" + "a" * 32,
                                                "request_id": "p1", "generation": 2, "choice": "deny"})
        self.assertTrue(data["ok"])
        sent = next(r for r in self.hermes.requests if r[2].endswith("/approval"))
        self.assertEqual(sent[3], {"request_id": "p1", "execution_generation": 2, "choice": "deny"})
        with self.assertRaises(AssertionError):
            self.c.call("approval.respond", {"profile": "team-ceo", "run": "../x", "choice": "once"})

    def test_long_output_is_split_into_self_contained_segments(self):
        long = "数据" * 3000 + " end"
        self.hermes.answer = lambda profile, text: long
        try:
            rid, _ = self.c.send("chat.send", {"profile": "team-ceo", "text": "long"})
            frame, message = self.c.wait(rid)
        finally:
            del self.hermes.answer
        self.assertIn("data", message)  # final reply did not fit a message, went as ag1.bin
        self.assertEqual(frame["data"]["output"], long)
        self.assertGreater(len({s["off"] for s in self.c.streams(rid)}), 3)
        self.assertEqual(assemble(self.c.streams(rid)), long)

    def test_stream_frames_always_fit_a_telegram_message(self):
        # Worst case found in review: a full CJK segment plus five long tool previews and an approval.
        stream = B.Stream(B.Ctx(self.bridge, USER, "r-fit", None), "team-ceo")
        stream.text = "数据" * 4000
        stream.tools = [{"id": str(i), "tool": "terminal", "preview": "预览" * 40, "state": "running"} for i in range(8)]
        stream.approval = {"request_id": "p", "generation": 1, "command": "命令" * 150, "description": "说明" * 100,
                           "choices": ["once", "session", "always", "deny"]}
        stream.push(force=True)   # the fake Telegram asserts len(text) <= 4096 on every send and edit
        frames = Client(self.tg).streams("r-fit")
        self.assertEqual(assemble(frames), stream.text)
        self.assertTrue(all(f["approval"] for f in frames))

    def test_group_gets_attached_files(self):
        group = self.c.call("groups.save", {"name": "files", "members": ["team-ceo"], "mode": "all"})
        self.c.call("group.send", {"id": group["id"], "text": "", "files": ["/inbox/a.csv"]})
        prompt = [r[3]["input"] for r in self.hermes.requests if r[2] == "/v1/runs"][-1]
        self.assertIn("/inbox/a.csv", prompt)
        self.c.call("groups.delete", {"id": group["id"]})

    def test_group_relay_is_bounded(self):
        group = self.c.call("groups.save", {"name": "risk", "members": ["team-ceo", "team-cro"], "mode": "lead"})
        # Each member always hands over to the other: without the hop budget this never ends.
        self.hermes.answer = lambda profile, text: f"over to @{'team-cro' if profile == 'team-ceo' else 'team-ceo'}"
        try:
            replies = self.c.call("group.send", {"id": group["id"], "text": "go"})["replies"]
        finally:
            del self.hermes.answer
        self.assertEqual([r["who"] for r in replies], ["team-ceo", "team-cro", "team-ceo", "team-cro", "team-ceo"])
        self.assertEqual(len(replies), 1 + B.MAX_HOPS)
        history = self.c.call("group.history", {"id": group["id"]})["messages"]
        self.assertEqual(len(history), 2 + B.MAX_HOPS)
        prompts = [r[3]["input"] for r in self.hermes.requests if r[2] == "/v1/runs" and r[0] == "team-cro"]
        self.assertIn("[team-ceo]: over to @team-cro", prompts[-2])
        self.c.call("groups.delete", {"id": group["id"]})
        self.assertEqual(self.c.call("groups.list")["groups"], [])

    def test_files_stay_inside_the_workspace(self):
        files = self.c.call("files.list", {"profile": "team-cro"})["files"]
        self.assertEqual([f["name"] for f in files], ["report.md"])
        rid, _ = self.c.send("files.get", {"profile": "team-cro", "path": files[0]["path"]})
        frame, message = self.c.wait(rid)
        self.assertEqual((frame["data"]["name"], message["data"]), ("report.md", b"# report"))
        for path in (str(self.home / "profiles" / "team-cro" / ".env"), "/etc/passwd"):
            with self.assertRaisesRegex(AssertionError, "outside"):
                self.c.call("files.get", {"profile": "team-cro", "path": path})

    def test_library_lists_every_profile_in_one_request(self):
        work = self.home / "profiles" / "team-cro" / "workspace"
        for hidden in (".git/config", "node_modules/pkg/index.js", ".secret"):
            (work / hidden).parent.mkdir(parents=True, exist_ok=True)
            (work / hidden).write_text("x")
        board = self.home / "kanban" / "workspaces" / "t_1"
        board.mkdir(parents=True, exist_ok=True)
        (board / "result.csv").write_text("a,b")
        files = self.c.call("files.list")["files"]
        found = {(f["profile"], f["source"], f["name"]) for f in files}
        self.assertLessEqual({("team-cro", "workspace", "report.md"), ("default", "board", "result.csv")}, found)
        self.assertFalse({"config", "index.js", ".secret"} & {f["name"] for f in files})
        # What it lists it can also fetch: the board workspace belongs to the default profile.
        item = next(f for f in files if f["name"] == "result.csv")
        rid, _ = self.c.send("files.get", {"profile": item["profile"], "path": item["path"]})
        self.assertEqual(self.c.wait(rid)[1]["data"], b"a,b")

    def test_jobs_list_normalises_real_jobs(self):
        (self.home / "cron").mkdir(exist_ok=True)
        (self.home / "cron" / "jobs.json").write_text("{}")
        (self.home / "profiles" / "team-ceo" / "config.yaml").write_text("timezone: Asia/Shanghai\n")
        data = self.c.call("jobs.list")
        jobs = {j["id"]: j for j in data["jobs"]}
        daily = jobs["42e312f2c0d4"]
        self.assertEqual((daily["profile"], daily["kind"], daily["expr"], daily["enabled"], daily["state"]),
                         ("default", "cron", "0 2 * * *", True, "scheduled"))
        self.assertEqual(daily["next_run"], 1794621600.0)   # 2026-11-14T02:00:00+00:00
        self.assertEqual((jobs["96868102c566"]["kind"], jobs["96868102c566"]["minutes"]), ("interval", 30))
        self.assertEqual((jobs["2606b6b03fc2"]["enabled"], jobs["2606b6b03fc2"]["no_agent"]), (False, True))
        self.assertNotIn("origin", daily)   # chat ids stay on the host
        self.assertEqual(data["offsets"]["team-ceo"], 8 * 3600)
        self.assertEqual(data["errors"], [])

    def test_job_lifecycle_goes_to_the_profiles_own_store(self):
        job = self.c.call("jobs.create", {"profile": "team-cro", "name": "nightly", "schedule": "0 1 * * *",
                                          "prompt": "secret plan", "deliver": "local", "paused": True})
        self.assertEqual((job["profile"], job["expr"], job["enabled"], job["prompt"]), ("team-cro", "0 1 * * *", False, "secret plan"))
        ref = {"profile": "team-cro", "id": job["id"]}
        self.assertEqual(self.c.call("jobs.update", dict(ref, schedule="every 2h", name="often"))["minutes"], 120)
        self.assertTrue(self.c.call("jobs.resume", ref)["enabled"])
        self.assertEqual(self.c.call("jobs.pause", ref)["state"], "paused")
        self.assertEqual(self.c.call("jobs.run", ref)["id"], job["id"])
        self.assertEqual(self.c.call("jobs.delete", ref), {})
        with self.assertRaisesRegex(AssertionError, "Job not found"):
            self.c.call("jobs.pause", ref)
        calls = [(p, m, path) for p, m, path, _ in self.hermes.requests if path.startswith("/api/jobs")]
        self.assertIn(("team-cro", "POST", "/api/jobs"), calls)
        self.assertIn(("team-cro", "PATCH", f"/api/jobs/{job['id']}"), calls)
        self.assertIn(("team-cro", "POST", f"/api/jobs/{job['id']}/run"), calls)
        self.assertIn(("team-cro", "DELETE", f"/api/jobs/{job['id']}"), calls)
        audit = (self.home / "agentgram-bridge" / "audit.log").read_text()
        self.assertIn("jobs.create", audit)
        self.assertNotIn("secret plan", audit)

    def test_job_requests_are_validated(self):
        for args, error in (({"profile": "team-cro", "id": "../x"}, "invalid job id"),
                            ({"profile": "../x", "id": "0123456789ab"}, "invalid profile")):
            with self.assertRaisesRegex(AssertionError, error):
                self.c.call("jobs.delete", args)
        with self.assertRaisesRegex(AssertionError, "needs a name"):
            self.c.call("jobs.create", {"profile": "team-cro", "schedule": "every 1h"})
        with self.assertRaisesRegex(AssertionError, "invalid delivery"):
            self.c.call("jobs.create", {"profile": "team-cro", "name": "x", "schedule": "every 1h", "deliver": "a b;c"})
        with self.assertRaisesRegex(AssertionError, "Invalid schedule"):   # Hermes' own message comes through
            self.c.call("jobs.create", {"profile": "team-cro", "name": "x", "schedule": "nonsense words"})

    def test_job_output_is_the_response_of_the_newest_run(self):
        folder = self.home / "profiles" / "team-cro" / "cron" / "output" / "0123456789ab"
        folder.mkdir(parents=True)
        (folder / "2026-11-12_02-01-08.md").write_text("# Cron Job: x\n\n## Prompt\n\nold\n\n## Response\n\nold answer\n")
        (folder / "2026-11-13_02-01-08.md").write_text("# Cron Job: x\n\n## Prompt\n\ndo it\n\n## Response\n\nAll good.\n")
        out = self.c.call("jobs.output", {"profile": "team-cro", "id": "0123456789ab"})
        self.assertEqual((out["text"], out["file"], out["runs"]), ("All good.", "2026-11-13_02-01-08.md", 2))
        self.assertEqual(self.c.call("jobs.output", {"profile": "team-cro", "id": "ba9876543210"})["text"], "")

    def test_upload_lands_in_the_inbox(self):
        self.tg.files["f1"] = b"payload"
        data = self.c.call("file.put", {"profile": "team-cro", "name": "../../evil name.txt"},
                           document={"file_id": "f1", "file_name": "evil name.txt", "file_size": 7})
        path = Path(data["path"])
        self.assertEqual(path.read_bytes(), b"payload")
        self.assertEqual(path.parent, self.home / "agentgram-bridge" / "inbox" / "team-cro")

    def test_bad_names_and_default_delete_are_refused_and_audited(self):
        for args in ({"name": "../x"}, {"name": "default"}, {"name": "Bad Name"}):
            with self.assertRaises(AssertionError):
                self.c.call("profile.delete", args)
        with self.assertRaisesRegex(AssertionError, "lowercase"):
            self.c.call("profile.create", {"name": "No Good"})
        log = (self.home / "agentgram-bridge" / "audit.log").read_text()
        self.assertIn('"op": "profile.delete"', log)
        self.assertIn('"ok": false', log)

    def test_audit_never_holds_message_text(self):
        self.c.call("chat.send", {"profile": "team-ceo", "text": "TOP-SECRET-PROMPT"})
        self.assertNotIn("TOP-SECRET-PROMPT", (self.home / "agentgram-bridge" / "audit.log").read_text())

    def test_sweep_deletes_old_messages(self):
        with self.bridge.lock:
            self.bridge.sent.append((time.time() - B.SWEEP_AFTER - 1, 77777))
        self.bridge.sweep(USER)
        self.assertIn(77777, self.tg.deleted)


class ApiKeyTests(unittest.TestCase):
    def test_named_profile_gets_its_own_key_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / "profiles" / "p1").mkdir(parents=True)
            (home / "profiles" / "p1" / ".env").write_text("OTHER=1")
            b = B.Bridge({"AG_KEY": base64.b64encode(KEY).decode(), "AG_USER_ID": "1", "AG_BOT_TOKEN": "t",
                          "HERMES_HOME": tmp})
            key = b.api_key("p1")
            self.assertEqual(len(key), 64)
            self.assertEqual(b.api_key("p1"), key)
            env = home / "profiles" / "p1" / ".env"
            self.assertEqual(env.read_text(), f"OTHER=1\nAPI_SERVER_KEY={key}\n")
            with self.assertRaisesRegex(B.BridgeError, "not enabled"):
                b.api_key("default")
            with self.assertRaises(B.BridgeError):
                b.api_key("../p1")


@unittest.skipUnless(os.environ.get("AG_LIVE_HERMES_HOME"), "set AG_LIVE_HERMES_HOME for the live run")
class LiveTests(unittest.TestCase):
    """Real `hermes` CLI and real API server behind the bridge; only Telegram is faked."""

    @classmethod
    def setUpClass(cls):
        cls.tg = FakeTelegram()
        cls.state = tempfile.TemporaryDirectory()
        cls.bridge = start_bridge(cls.tg, os.environ["AG_LIVE_HERMES_HOME"],
                                  os.environ.get("AG_LIVE_API", "http://127.0.0.1:8642"), state=cls.state.name)
        cls.c = Client(cls.tg)
        cls.name = "agtest-" + uuid.uuid4().hex[:6]

    @classmethod
    def tearDownClass(cls):
        try:
            cls.c.call("profile.delete", {"name": cls.name}, timeout=120)
        except AssertionError:
            pass
        cls.bridge.stopping = True
        cls.state.cleanup()

    def test_1_hello_models_toolsets(self):
        self.assertTrue(self.c.call("hello", timeout=60)["api"])
        self.assertTrue(self.c.call("models.list", timeout=60)["models"])
        self.assertIn("terminal", [t["name"] for t in self.c.call("toolsets.list")["toolsets"]])

    def test_2_create_chat_approve_history(self):
        c, name = self.c, self.name
        c.call("profile.create", {"name": name, "soul": "You are a terse test bot.", "description": "throwaway",
                                  "toolsets": ["terminal", "file"]}, timeout=300)
        self.assertIn(name, [p["name"] for p in c.call("profiles.list", timeout=60)["profiles"]])
        session = f"agentgram:{name}:1"
        out = c.call("chat.send", {"profile": name, "session": session, "text": "Reply with exactly: pong"}, timeout=180)
        self.assertEqual(out["status"], "completed")
        self.assertIn("pong", out["output"].lower())

        victim = tempfile.mkdtemp(prefix="agtest-victim-", dir="/tmp")
        rid, _ = c.send("chat.send", {"profile": name, "session": session,
                                      "text": f"Run exactly this in the terminal: rm -rf {victim}"})
        deadline, approval = time.time() + 120, None
        while time.time() < deadline and approval is None:
            approval = next((s["approval"] for s in c.streams(rid) if s["approval"]), None)
            run = next((s["run"] for s in c.streams(rid) if s["run"]), "")
            time.sleep(0.2)
        self.assertIsNotNone(approval, "no approval request arrived")
        self.assertIn("rm -rf", approval["command"])
        c.call("approval.respond", {"profile": name, "run": run, "request_id": approval["request_id"],
                                    "generation": approval["generation"], "choice": "deny"}, timeout=60)
        frame, _ = c.wait(rid, timeout=180)
        self.assertTrue(frame["ok"])
        self.assertTrue(os.path.isdir(victim), "denied command must not have run")
        os.rmdir(victim)

        messages = c.call("session.messages", {"profile": name, "session": frame["data"]["session"]}, timeout=60)["messages"]
        self.assertEqual(messages[0]["role"], "user")
        self.assertIn("pong", messages[1]["text"].lower())
        self.assertTrue(c.call("sessions.list", {"profile": name}, timeout=60)["sessions"])
        self.assertEqual(c.call("activity", {"profile": name}, timeout=60)["gateway"], "running")

    def test_3_group_and_kanban(self):
        c, name = self.c, self.name
        group = c.call("groups.save", {"name": "pair", "members": ["default", name], "mode": "lead"})
        # Only `default` is addressed; the second member must be reached by the relay.
        replies = c.call("group.send", {"id": group["id"], "text":
                         "Reply with exactly one line: an at-sign immediately followed by "
                         f"the word {name}, then the words: say hi"}, timeout=300)["replies"]
        self.assertEqual([r["status"] for r in replies][:2], ["completed", "completed"])
        self.assertEqual([r["who"] for r in replies][:2], ["default", name])

    def test_4_kanban_writes(self):
        c, name = self.c, "default"
        task = c.call("kanban.create", {"title": "agentgram live test", "body": "throwaway"}, timeout=60)
        tid = task["id"]
        c.call("kanban.comment", {"id": tid, "text": "a comment"}, timeout=60)
        c.call("kanban.block", {"id": tid, "text": "waiting"}, timeout=60)
        self.assertEqual(c.call("kanban.show", {"id": tid}, timeout=60)["task"]["status"], "blocked")
        c.call("kanban.unblock", {"id": tid}, timeout=60)
        c.call("kanban.assign", {"id": tid, "assignee": name}, timeout=60)
        c.call("kanban.assign", {"id": tid}, timeout=60)
        c.call("kanban.complete", {"id": tid, "text": "done"}, timeout=60)
        shown = c.call("kanban.show", {"id": tid}, timeout=60)
        self.assertEqual(shown["task"]["status"], "done")
        self.assertIn("a comment", [m["body"] for m in shown["comments"]])


if __name__ == "__main__":
    unittest.main()
