"""Export complete Ecos candidates and join each decision to its executed generation."""

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORTER = Path(sys.argv[1]).resolve()
OUTPUT = Path(tempfile.mkdtemp(prefix="ecos-source-export-"))
revision = subprocess.check_output(
    ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
).strip()
for variant in ("standard", "harsh-spring"):
    output = OUTPUT / variant
    subprocess.run(
        [str(EXPORTER), str(output), "10", "1", variant],
        cwd=ROOT,
        check=True,
        timeout=600,
    )
    manifest = json.loads((output / "manifest.json").read_text())
    assert manifest["source_revision"] == revision and len(manifest["runs"]) == 10
    assert (
        not (output / "train.jsonl").exists()
        and not (output / "validation.jsonl").exists()
    )
    episodes, decisions, executions = {}, {}, {}
    for filename in ("manifest.json", "trajectories.jsonl", "execution.jsonl"):
        assert (output / filename).stat().st_mode & 0o777 == 0o600
    with (output / "trajectories.jsonl").open() as stream:
        for line in stream:
            row = json.loads(line)
            assert row["source_revision"] == revision
            episode = row["episode_id"]
            if row["event_type"] == "episode":
                episodes[episode] = row
                continue
            decisions.setdefault(episode, []).append(row)
            assert row["visibility"] == "private" and row["action_status"] == "accepted"
            assert row["fallback_origin"] is None
            (attempt,) = row["attempts"]
            assert row["selected_attempt_id"] == attempt["attempt_id"]
            assert attempt["origin"] == "teacher" and attempt["request"] is None
            assert (
                attempt["platform_call_id"] is None
                and attempt["behavior_logprobs"] is None
            )
            assert (
                attempt["parsed_action"]
                == json.loads(attempt["response"])
                == row["executed_action"]
            )
            view = row["observation"].copy()
            metadata = view.pop("prompt_template")
            assert (
                metadata["bank"] == "ecos-player-v1"
                and metadata["variant"] == "canonical"
            )
            assert row["prompt"] == attempt["prompt"]
            for message in row["prompt"]:
                assert (
                    metadata[message["role"] + "_sha256"].lower()
                    == hashlib.sha256(message["content"].encode()).hexdigest()
                )
            user = row["prompt"][1]["content"]
            assert (
                json.loads(user.split("\n", 1)[1].split("\n\nOperator guidance:", 1)[0])
                == view
            )
            assert not ({"seed", "bodies", "policyNames"} & set(view))
            assert all(
                not ({"doctrine", "notes", "say"} & set(other))
                for other in view["species"]
            )
    with (output / "execution.jsonl").open() as stream:
        for line in stream:
            row = json.loads(line)
            executions.setdefault(row["episode_id"], []).append(row)
            assert row["visibility"] == "private" and row["source_revision"] == revision
    assert len(episodes) == 10 and set(episodes) == set(decisions) == set(executions)
    for episode, outcome in episodes.items():
        rows, generations = decisions[episode], executions[episode]
        assert (
            outcome["status"] == "completed"
            and outcome["outcome"]["reason"] == "complete"
        )
        assert len(rows) == 30 and len(generations) == 10
        assert sum(row["terminal"] for row in rows) == 1 and rows[-1]["terminal"]
        assert {row["observation"]["role"] for row in rows} == {
            "grass",
            "grazers",
            "predators",
        }
        for seat in range(3):
            assert (
                outcome["participant_outcomes"][str(seat)]["score"]
                == outcome["outcome"]["scores"][seat]
            )
        for index, generation in enumerate(generations):
            batch = rows[3 * index : 3 * index + 3]
            assert generation["decision_ids"] == [row["decision_id"] for row in batch]
            assert (
                generation["start_tick"] == index * 60
                and generation["end_tick"] == (index + 1) * 60
            )
            assert (
                generation["terminal"] == (index == 9)
                and len(generation["frames"]) == 60
            )
            assert [frame["t"] for frame in generation["frames"]] == list(
                range(index * 60 + 1, (index + 1) * 60 + 1)
            )
            for seat, (row, event) in enumerate(
                zip(batch, generation["installed_doctrines"], strict=True)
            ):
                assert (
                    event["k"] == "doctrine"
                    and event["source"] == "scripted"
                    and event["seat"] == seat
                )
                assert row["observation"]["tick"] == index * 60
                assert event["fields"] == list(
                    row["executed_action"]["doctrine"].values()
                )
                assert not event["clamped"]
    assert {row["seed_family"] for row in episodes.values()} == {
        f"ecos-{seed}" for seed in range(1, 11)
    }
    print(
        variant,
        "10 complete exports; private prompts, doctrine execution, frames and outcomes PASS",
        flush=True,
    )
print("Evidence:", OUTPUT)
