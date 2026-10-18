"""Published Ecos episodes with real players and a closed inference endpoint."""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import time
from pathlib import Path


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / "coworld_manifest_template.json").read_text())
    variants = {entry["id"]: entry["game_config"] for entry in manifest["variants"]}
    cases = [(name, "canonical") for name in variants]
    cases += [
        ("standard", wording)
        for wording in (
            "plain",
            "numbered",
            "questions",
            "reordered",
            "heldout-briefing",
            "heldout-reference",
            "mixed",
        )
    ]
    if args.smoke:
        cases = [("standard", "canonical"), ("harsh-spring", "canonical")]
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    for variant, wording in cases:
        work = args.output / f"{variant}-{wording}"
        work.mkdir(mode=0o700)
        config = dict(variants[variant])
        seats = config["num_agents"]
        config.update(
            seed=7,
            promptVariant=wording,
            promptSeed=4,
            tokens=[f"t{seat}" for seat in range(seats)],
            players=[{"name": f"policy-{seat}"} for seat in range(seats)],
        )
        (work / "config.json").write_text(json.dumps(config))
        port, closed_port = free_port(), free_port()
        env = os.environ.copy()
        for key in (
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_API_KEY_URI",
            "AWS_BEARER_TOKEN_BEDROCK",
            "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
            "PLAYER_SCRIPTED",
        ):
            env.pop(key, None)
        env.update(
            COGAME_HOST="127.0.0.1",
            COGAME_PORT=str(port),
            COGAME_CONFIG_URI=(work / "config.json").as_uri(),
            COGAME_RESULTS_URI=(work / "results.json").as_uri(),
            COGAME_SAVE_REPLAY_URI=(work / "episode.replay").as_uri(),
            COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{closed_port}",
            ECOS_HOST_TRACE_PATH=str(work / "host.jsonl"),
            ECOS_ATTEMPT_TRACE_DIR=str(work / "attempts"),
            ECOS_PLAYER_TRACE_DIR=str(work / "submissions"),
            ECOS_SOURCE_REVISION="uncommitted-ecos-validation",
        )
        processes, logs = [], []
        try:
            log = (work / "game.log").open("w")
            logs.append(log)
            game = subprocess.Popen(
                [str(args.game)],
                cwd=root,
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            processes.append(game)
            for _ in range(200):
                assert game.poll() is None, work
                with socket.socket() as probe:
                    ready = probe.connect_ex(("127.0.0.1", port)) == 0
                if ready:
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError(f"host did not start: {work}")
            for seat in range(seats):
                player_env = dict(
                    env,
                    COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                    PLAYER_PROMPT=(
                        f"PRIVATE-STRATEGY-{seat}: Cooperate using only the information available to your role."
                    ),
                )
                log = (work / f"player-{seat}.log").open("w")
                logs.append(log)
                processes.append(
                    subprocess.Popen(
                        [str(args.player)],
                        cwd=root,
                        env=player_env,
                        stdout=log,
                        stderr=subprocess.STDOUT,
                    )
                )
            assert game.wait(timeout=manifest["episode_timeout_minutes"] * 60 + 30) == 0
            for player in processes[1:]:
                assert player.wait(timeout=15) == 0
            results = json.loads((work / "results.json").read_text())
            assert (
                results["reason"] == "complete"
                and results["ending"] == "ten_generations"
            ), results
            assert results["generations"] == 10 and len(results["scores"]) == 3
            records = [
                json.loads(line)
                for line in (work / "host.jsonl").read_text().splitlines()
            ]
            assert records[0]["event_type"] == "host_started"
            assert (
                records[-1]["event_type"] == "host_finished"
                and records[-1]["results"] == results
            )
            observations = [
                row for row in records if row["event_type"] == "host_observation"
            ]
            decisions = [row for row in records if row["event_type"] == "host_decision"]
            generations = [
                row for row in records if row["event_type"] == "host_generation"
            ]
            assert len(observations) == len(decisions) == 30 and len(generations) == 10
            starts, finishes, submissions = {}, {}, {}
            for path in (work / "attempts").glob("*.jsonl"):
                assert path.stat().st_mode & 0o777 == 0o600
                start, finish = [
                    json.loads(line) for line in path.read_text().splitlines()
                ]
                assert start["attempt_id"] == finish["attempt_id"]
                starts[start["attempt_id"]] = start
                finishes[finish["attempt_id"]] = finish
            for path in (work / "submissions").glob("*.json"):
                assert path.stat().st_mode & 0o777 == 0o600
                row = json.loads(path.read_text())
                submissions[row["attempt_id"]] = row
            assert len(starts) == 30 and set(starts) == set(finishes) == set(
                submissions
            )
            for index, (observation, row) in enumerate(
                zip(observations, decisions, strict=True)
            ):
                generation, seat = index // 3 + 1, index % 3
                assert (
                    row["generation"] == generation
                    and row["seat"] == seat
                    and row["received"]
                )
                assert (
                    row["tick"] == (generation - 1) * 60 and row["source"] == "fallback"
                )
                identity = f"{generation}-{seat}"
                start, finish, submission = (
                    starts[identity],
                    finishes[identity],
                    submissions[identity],
                )
                assert (
                    not finish["succeeded"]
                    and finish["phase"] == "request"
                    and submission["failure"]
                )
                assert (
                    finish["parsed_action"] is None
                    and finish["normalized_action"] is None
                )
                assert (
                    finish["platform_call_id"] is None
                    and finish["behavior_logprobs"] is None
                )
                assert start["observation"] == observation["observation"]
                action = submission["action"]
                assert action["source"] == "fallback"
                assert {
                    key: action[key] for key in ("doctrine", "say", "notes")
                } == row["executed_action"]
                system, user = (message["content"] for message in start["prompt"])
                assert f"PRIVATE-STRATEGY-{seat}" in user
                assert all(
                    f"PRIVATE-STRATEGY-{other}" not in user
                    for other in range(3)
                    if other != seat
                )
                body = start["request"]["body"]
                assert (
                    body["system"] == system and body["messages"] == start["prompt"][1:]
                )
                assert start["request"]["model"] == body["model"]
                metadata = start["prompt_template"]
                assert metadata["variant"] == (
                    "reordered" if wording == "mixed" else wording
                )
                for role, text in (("system", system), ("user", user)):
                    assert (
                        metadata[f"{role}_sha256"].lower()
                        == hashlib.sha256(text.encode()).hexdigest()
                    )
                view = start["observation"]
                assert not ({"seed", "bodies", "policyNames"} & set(view))
                assert all(
                    not ({"doctrine", "notes", "say"} & set(other))
                    for other in view["species"]
                )
            replay = json.loads((work / "episode.replay").read_text())
            assert replay["results"] == results and len(replay["frames"]) == 601
            for index, generation in enumerate(generations):
                assert (
                    generation["generation"] == index + 1
                    and generation["start_tick"] == index * 60
                )
                assert generation["end_tick"] == (index + 1) * 60
                assert (
                    generation["frames"]
                    == replay["frames"][index * 60 + 1 : (index + 1) * 60 + 1]
                )
            installed = [
                event for event in replay["events"] if event["k"] == "doctrine"
            ]
            assert installed == [row["installed"] for row in decisions]
            public = (work / "episode.replay").read_text()
            assert "PRIVATE-STRATEGY-" not in public and "prompt_template" not in public
            assert (work / "host.jsonl").stat().st_mode & 0o777 == 0o600
            print(
                work.name,
                "600 ticks; 30 actual failed attempts; 30 fallback doctrines; three real players PASS",
                flush=True,
            )
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
            for log in logs:
                log.close()


if __name__ == "__main__":
    main()
