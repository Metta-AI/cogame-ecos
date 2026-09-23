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
Ecos's four bounded integer doctrine fields could support a factorized
discrete reinforcement learning codec, but the current Metta RL and PufferLib
bridges do not expose its action and observation.
