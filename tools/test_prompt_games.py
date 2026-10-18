"""Play complete published Ecos games through both bridge modes and role rotations."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRIDGE = Path(sys.argv[1]).resolve()
ORIGINAL = Path(sys.argv[2]).resolve()
WORDINGS = (
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
)
OPERATOR = (
    "Keep all three species alive while maximizing your integrated biomass score."
)


def play(
    variant, seed, wording="canonical", prompt_seed=0, normalize=False, original=False
):
    command = [
        str(ORIGINAL if original else BRIDGE),
        str(ROOT / "coworld_manifest_template.json"),
        variant,
    ]
    if not original:
        command.append("text")
    with subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
    ) as process:
        assert process.stdin is not None and process.stdout is not None

        def request(value):
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        observation = request(
            {
                "kind": "reset",
                "players": 3,
                "seed": seed,
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "test",
            }
        )
        trace, systems, roles = [], {}, {}
        while observation["kind"] == "decision":
            seat = observation["seat"]
            assert seat == len(trace) % 3 and observation["decision_id"] == len(trace)
            view = observation["semantic_view"].copy()
            role = view["role"]
            roles[seat] = role
            proposal = json.loads(request({"kind": "teacher"})["response"])
            if not original:
                metadata = view.pop("prompt_template")
                messages = observation["messages"]
                selected = WORDINGS[prompt_seed] if wording == "mixed" else wording
                assert (metadata["bank"], metadata["variant"]) == (
                    "ecos-player-v1",
                    selected,
                )
                for message in messages:
                    assert (
                        metadata[message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
                assert (
                    systems.setdefault(seat, messages[0]["content"])
                    == messages[0]["content"]
                )
                if selected == "canonical":
                    assert messages[0]["content"] == (
                        f"You control the {role} species in Ecos. Choose its four-integer doctrine for the next "
                        "generation. Your goal is integrated biomass without collapsing the "
                        "food chain. Reply with ONLY one JSON object."
                    )
                prefix = "Private observation and visible rules:\n"
                serialized, tail = messages[1]["content"][len(prefix) :].split(
                    "\n\nOperator guidance:\n", 1
                )
                assert (
                    messages[1]["content"].startswith(prefix)
                    and json.loads(serialized) == view
                )
                assert tail.startswith(OPERATOR + "\n\nReturn ")
                assert not (
                    {"seed", "bodies", "policyNames", "prompt_template"} & set(view)
                )
                for other in view["species"]:
                    assert not ({"doctrine", "notes", "say"} & set(other))
                if normalize:
                    marker = ("雪", "森", "海")[seat]
                    for other in set(("雪", "森", "海")) - {marker}:
                        assert other not in messages[1]["content"]
                    if view["generation"] > 1:
                        assert view["notes"] == marker * 399 + "…"
                    proposal["say"] = marker * 90
                    proposal["notes"] = marker * 430
                    proposal["doctrine"] = {
                        key: str(value) for key, value in proposal["doctrine"].items()
                    }
            if clamp:
                limits = observation["action_schema"]["properties"]["doctrine"][
                    "properties"
                ]
                proposal["doctrine"] = {
                    key: bounds["maximum"] + 999 for key, bounds in limits.items()
                }
            accepted = request(
                {
                    "kind": "step",
                    "decision_id": observation["decision_id"],
                    "response": json.dumps(proposal),
                }
            )
            assert accepted["kind"] == "accepted"
            action = accepted["action"]
            if normalize:
                assert (
                    action["say"] == marker * 63 + "…"
                    and action["notes"] == marker * 399 + "…"
                )
                assert action["doctrine"] == {
                    key: int(value) for key, value in proposal["doctrine"].items()
                }
            else:
                assert action == proposal
            if original:
                fields = tuple(action[f"field{i}"] for i in range(4))
            else:
                fields = tuple(action["doctrine"].values())
            trace.append((view, fields))
            observation = accepted["observation"]
            assert len(trace) <= 30
        process.stdin.close()
        assert process.wait(timeout=30) == 0
        assert observation["kind"] == "terminal" and 3 <= len(trace) <= 30
        if not clamp:
            assert len(trace) == 30
        assert set(roles.values()) == {"grass", "grazers", "predators"}
        return trace, observation, systems


for variant in ("standard", "harsh-spring"):
    rotations = set()
    for seed in ("17", "18", "23"):
        baseline, outcome, _ = play(variant, seed, original=True)
        rotations.add(baseline[0][0]["role"])
        rendered = set()
        selected_systems = {}
        for wording, prompt_seed in [
            *((name, 0) for name in WORDINGS),
            *(("mixed", i) for i in range(5)),
        ]:
            trace, result, systems = play(variant, seed, wording, prompt_seed)
            assert (trace, result) == (baseline, outcome)
            selected = WORDINGS[prompt_seed] if wording == "mixed" else wording
            assert selected_systems.setdefault(selected, systems) == systems
            rendered.add(systems[0])
        assert len(rendered) == 7
        _, normalized_result, _ = play(variant, seed, normalize=True)
        assert normalized_result == outcome
        print(
            variant,
            seed,
            "13 text games and original numeric trajectory PASS",
            flush=True,
        )
    assert len(rotations) == 3
    play(variant, "17", clamp=True)
    for wording in WORDINGS[5:]:
        rejected = subprocess.run(
            [
                str(BRIDGE),
                str(ROOT / "coworld_manifest_template.json"),
                variant,
                "text",
            ],
            input=json.dumps(
                {
                    "kind": "reset",
                    "players": 3,
                    "seed": "17",
                    "promptVariant": wording,
                    "split": "train",
                }
            )
            + "\n",
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert rejected.returncode != 0 and "evaluation-only" in rejected.stderr
