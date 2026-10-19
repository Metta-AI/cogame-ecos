# Ecos prompt diversity and training

Live players, the text bridge, and teacher exports share `playerPrompts`.
The previous exporter used a different, longer prompt than the player.
Canonical now means the unchanged live-player system and user text.
The separate legacy training prompt builder has been removed.

`promptVariant` selects `canonical`, `plain`, `numbered`, `questions`, or
`reordered` for training. `mixed` selects one of those five using
`promptSeed mod 5`; it requires an explicit nonnegative seed. The selection
stays fixed throughout an episode and does not consume simulation randomness.
`heldout-briefing` and `heldout-reference` are evaluation-only.

The host carries `prompt_config` beside the private decision view. It is not
simulation state or public replay metadata. Rebuild and publish the game and
reference player together: the player consumes this required decision field. Wordings preserve the controlled
species, four-integer doctrine, generation cadence, integrated-biomass objective,
food-chain constraint, and JSON output format. Private observations, operator
strategy, doctrine ranges, and inference budgets stay unchanged.

## Complete text actions

```bash
nim c -d:release --path:src -o:/tmp/ecos-bridge tools/train_bridge.nim
/tmp/ecos-bridge coworld_manifest_template.json standard text
```

The JSONL bridge accepts `reset`, `teacher`, and `step`. Reset includes three
players, a scenario `seed`, `promptVariant`, `promptSeed`, and a split of
`train`, `validation`, or `test`. Training rejects held-out wordings.

Text actions contain the complete role-specific `doctrine`, spectator `say`,
and private `notes`. The real player parser rounds numeric inputs, clamps
ranges, and truncates text at rune boundaries. Accepted actions report the
normalized result. All three observations and submissions precede installation
of any doctrine. The original numeric interface keeps its 204 observations and
four masked action heads of widths 251, 361, 401, and 101.

## Teacher exports and validation

```bash
nim c -d:release --path:src -o:/tmp/ecos-export tools/export_posttrain.nim
/tmp/ecos-export /tmp/ecos-examples 10 1 standard mixed 0
python3 tools/test_export_posttrain.py /tmp/ecos-export
python3 tools/test_prompt_games.py /tmp/ecos-bridge
```

Exports require clean, committed source and a new private output directory.
They retain the original `train.jsonl`, `validation.jsonl`, and
`manifest.json` format. Mixed selection advances once per game.
Each row records the actual player messages and wording metadata.
All role observations are frozen before any doctrine is installed.

Seed families exclude variant and wording; multiples of five enter validation.
Held-out wording is rejected. The steward teacher's doctrines pass the real
parser and must remain unclamped. Each game runs to its actual end, including
early extinction.

The existing native player workflow checks the selected system prompt at a
local model endpoint, then verifies installed model and scripted actions:

```bash
python3 tools/ci/player_policy_smoke.py /tmp/ecos-game /tmp/ecos-player
```

That smoke uses its existing two-generation fixture. Complete bridge and
export checks use published variants and normal game budgets. Neither measures
live provider quality.

Compare frozen base, canonical-trained, and mixed-trained checkpoints using
matched scenario seeds, opponents, and all three role rotations. Report biomass
scores, extinction rates, invalid/clamped actions, inference failures, and
held-out wording performance separately. Local parity checks do not demonstrate
improved learning or resistance to policy collapse.

## Numeric reinforcement learning

```bash
python3 tools/test_train_bridge.py /tmp/ecos-bridge
```

Use `recipes.external.coworld.train` or `recipes.external.coworld_metta_rl.train`
with the absolute bridge/manifest paths, a published variant, `players=3`, and a
training timestep limit. The steward supplies opponents and teacher labels.
