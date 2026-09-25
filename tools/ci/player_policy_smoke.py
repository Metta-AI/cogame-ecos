#!/usr/bin/env python3
"""Run one native mixed Ecos episode with stub player-side model endpoints."""

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

GAME, PLAYER = sys.argv[1:3]
requests = {"jev": 0, "prompt": 0}


class Stub(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path.endswith("/v1/systemone"):
            requests["jev"] += 1
            assert self.headers["x-coworld-player-slot"] == "0"
            answers = {}
            for name, question in body["questions"].items():
                criteria = question["criteria"]
                chosen = next(iter(criteria))
                answers[name] = {"type": "choice", "probabilities": {
                    key: 1.0 if key == chosen else 0.0 for key in criteria
                }}
            reply = {"answers": answers}
        else:
            requests["prompt"] += 1
            assert self.headers["x-coworld-player-slot"] == "1"
            reply = {"content": [{"type": "text", "text": json.dumps({
                "doctrine": {"birth_threshold": 110, "bite": 8,
                             "flee_range": 90, "herd": 55},
                "say": "keeping balance", "notes": "stub reply"
            })}], "stop_reason": "end_turn"}
        encoded = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *_args):
        pass


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


model = ThreadingHTTPServer(("127.0.0.1", free_port()), Stub)
threading.Thread(target=model.serve_forever, daemon=True).start()
port = free_port()
with tempfile.TemporaryDirectory(prefix="ecos-policy-") as scratch:
    root = Path(scratch)
    config = {"tokens": ["token-0", "token-1", "token-2"],
              "players": [{"name": name} for name in ("Sedge", "Bramble", "Quill")],
              "num_agents": 3, "seed": 7, "roleOffset": 0,
              "generations": 2, "ticksPerGeneration": 10,
              "actionTimeoutSeconds": 5, "minTurnSeconds": 0,
              "playerConnectTimeoutSeconds": 10, "shutdownGraceSeconds": 0}
    (root / "config.json").write_text(json.dumps(config))
    game_env = os.environ.copy()
    game_env.update({"COGAME_HOST": "127.0.0.1", "COGAME_PORT": str(port),
                     "COGAME_CONFIG_URI": (root / "config.json").as_uri(),
                     "COGAME_RESULTS_URI": (root / "results.json").as_uri(),
                     "COGAME_SAVE_REPLAY_URI": (root / "replay.json").as_uri()})
    game = subprocess.Popen([GAME], env=game_env, stdout=(root / "game.log").open("w"),
                            stderr=subprocess.STDOUT)
    players = []
    try:
        for _ in range(100):
            if game.poll() is not None:
                raise AssertionError((root / "game.log").read_text())
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", port)) == 0:
                    break
            time.sleep(0.05)
        else:
            raise AssertionError("game health unavailable")
        for slot, settings in enumerate((
            {"PLAYER_POLICY_KIND": "jev"},
            {"PLAYER_PROMPT": "Keep the ecosystem balanced."},
            {"PLAYER_SCRIPTED": "steward"},
        )):
            env = os.environ.copy()
            env.update(settings)
            env.update({"COWORLD_PLAYER_WS_URL":
                        f"ws://127.0.0.1:{port}/player?slot={slot}&token=token-{slot}",
                        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME":
                        f"http://127.0.0.1:{model.server_port}"})
            players.append(subprocess.Popen([PLAYER], env=env,
                           stdout=(root / f"player-{slot}.log").open("w"),
                           stderr=subprocess.STDOUT))
        assert game.wait(timeout=35) == 0, (root / "game.log").read_text()
        for slot, player in enumerate(players):
            assert player.wait(timeout=5) == 0, (root / f"player-{slot}.log").read_text()
        results = json.loads((root / "results.json").read_text())
        replay = json.loads((root / "replay.json").read_text())
        assert requests == {"jev": 2, "prompt": 2}, requests
        events = replay["events"]
        doctrines = [event for event in events if event["k"] == "doctrine"]
        sources = [event["source"] for event in doctrines]
        assert sources.count("llm") == 4, sources
        assert sources.count("scripted") == 2, sources
        assert sources.count("fallback") == 0, sources
        assert results["reason"] == "complete", results
        print("ecos player smoke: 2 Jev choices, 2 prompt replies, 2 scripted actions, zero fallback")
    finally:
        for process in [*players, game]:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        model.shutdown()
