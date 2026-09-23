"""Exercise both certified variants through the training bridge's JSONL protocol."""

import json
import subprocess
import sys
from pathlib import Path


manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
for variant in ("standard", "harsh-spring"):
    with subprocess.Popen(
        [sys.argv[1], str(manifest), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as bridge:
        assert bridge.stdin is not None and bridge.stdout is not None

        def request(payload):
            bridge.stdin.write(json.dumps(payload) + "\n")
            bridge.stdin.flush()
            return json.loads(bridge.stdout.readline())

        observation = request({"kind": "reset", "seed": "bridge-test", "players": 3})
        decisions = 0
        while observation["kind"] == "decision":
            encoded = request({"kind": "encode"})
            assert encoded["decision_id"] == observation["decision_id"]
            assert len(encoded["values"]) == 204
            assert [len(head["choices"]) for head in encoded["action_heads"]] == [251, 361, 401, 101]
            response = request({"kind": "teacher"})["response"]
            action = json.loads(response)
            for head in encoded["action_heads"]:
                assert action[head["name"]] in head["choices"]
            result = request({"kind": "step", "decision_id": observation["decision_id"], "response": response})
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
        assert decisions == 30 and set(observation["scores"]) == {"0", "1", "2"}
        bridge.stdin.close()
        assert bridge.wait() == 0
    print(f"{variant}: {decisions} decisions")
