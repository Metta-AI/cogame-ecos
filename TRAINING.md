# Ecos prompt diversity and training

Live players, the text bridge, and candidate exports share `playerPrompts`.
The previous exporter used a different, longer prompt than the player.
Canonical now means the unchanged live-player system and user text.
The separate legacy training prompt builder has been removed.

`promptVariant` selects `canonical`, `plain`, `numbered`, `questions`, or
`reordered` for training. `mixed` selects one of those five using
`promptSeed mod 5`; it requires an explicit nonnegative seed. The selection
stays fixed throughout an episode and does not consume simulation randomness.
`heldout-briefing` and `heldout-reference` are evaluation-only.

The host carries `prompt_config` beside the private decision view. It is not
simulation state or public replay metadata. Wordings preserve the controlled
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

## Private candidates and review

```bash
nim c -d:release --path:src -o:/tmp/ecos-export tools/export_posttrain.nim
/tmp/ecos-export /tmp/ecos-candidates 10 1 standard mixed 4
python3 tools/test_export_posttrain.py /tmp/ecos-export
```

Export requires committed, clean source and a new output directory. It uses
published variant settings, completes each episode, and writes private files
with mode 0600:

- `trajectories.jsonl`: frozen player observations, exact messages and hashes,
  teacher proposals, normalized installed doctrines, and final outcomes.
- `execution.jsonl`: decision IDs joined to installed-doctrine events and the
  actual state frames produced by each generation, including early extinction.
- `manifest.json`: source revision, prompt-bank version, selection, and runs.

These are candidate labels. No automatic train/validation files are produced.
Pass trajectories through the shared Coworld SDK and Metta importer. Independent
review must admit labels before training. Group all variants and wordings of a
scenario by `ecos-SEED`, so related episodes cannot cross dataset splits.
Teacher rows explicitly identify scripted origin and have no inference request,
platform call ID, or behavior log probabilities. Engine-normalized proposals
are not treated as accepted labels.

Execution evidence records the doctrine installed for the species and resulting
state frames. It does not claim that the model chose individual body movements.

## Native evidence and matched evaluation

Set `ECOS_HOST_TRACE_PATH` on the host and `ECOS_ATTEMPT_TRACE_DIR` plus
`ECOS_PLAYER_TRACE_DIR` on reference players. Set `ECOS_SOURCE_REVISION` to the
qualified revision. Each evidence path must be new. These optional artifacts
are private; never publish them with spectator replays.

Attempt records capture the actual request body, model, messages, hashes,
response, parse phase, and normalization. Submission records distinguish a
failed request from the fallback action sent afterward. Host records prove
which doctrine was installed and join it to replay events and state frames.
Public replay retains its existing spectator notes and event semantics.

```bash
nim c -d:release --path:src -o:/tmp/ecos-game src/ecos.nim
nim c -d:release --path:src -o:/tmp/ecos-player src/ecos_player.nim
python3 tools/test_native_prompts.py /tmp/ecos-game /tmp/ecos-player /tmp/ecos-native
```

The native panel runs both published variants and all seven additional wording
selections with three real players and a closed inference endpoint. `--smoke`
covers both canonical variants. Published timeouts, turn floors, generation
counts, and simulation ticks remain unchanged. This verifies failures and
fallbacks; it does not establish successful provider inference.

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
