# Ecos training

Ecos has a deterministic local simulator and hosted text players. Export
complete episodes for Metta post-training with the hosted per-seat prompts and
reply parser:

```bash
nimby sync nimby.lock
nim r --path:src tools/export_posttrain.nim /tmp/ecos-standard 10 1 standard
nim r --path:src tools/export_posttrain.nim /tmp/ecos-harsh 10 1 harsh-spring
```

The exporter reads each certified `game_config` from
`coworld_manifest_template.json`, runs seeded episodes with the published
steward baseline, and writes `train.jsonl`, `validation.jsonl`, and
`manifest.json`. Seeds divisible by five go to validation, keeping each
episode in one split. Each doctrine passes the hosted parser before the native
simulator applies it. The exporter refuses an existing output directory.

Train the text policy with Metta's post-training CLI:

```bash
uv run python -m metta_posttrain.train --dataset /tmp/ecos-standard \
  --output /tmp/ecos-model --model Qwen/Qwen2.5-0.5B-Instruct \
  --max-steps 100 --max-length 4096
```

The dataset imitates scripted play; its loss does not measure policy quality.

For native PufferLib reinforcement learning, compile the persistent decision
bridge and pass it to Metta's `recipes.external.coworld.train` recipe:

```bash
nim c -d:release --path:src -o:ecos-train-bridge tools/train_bridge.nim
uv run ./tools/run.py recipes.external.coworld.train \
  'command=["/absolute/path/to/ecos-train-bridge","/absolute/path/to/coworld_manifest_template.json","standard"]' \
  players=3 total_timesteps=100000
```

Replace `standard` with `harsh-spring` for that certified variant. The bridge
uses player-visible state only. It exposes 204 numeric observations and four
masked action heads for the exact native doctrine fields. Head widths are
251, 361, 401, and 101 for every seat. The steward provides opponent play and
optional teacher labels. Metta recipe support is in PR #24679, stacked on
#24573.
