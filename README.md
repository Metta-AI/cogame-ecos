# Ecos

**Grass, grazers, predators — and you are a species, not an individual.**

Three seats take the three trophic roles on a 1000 × 562 continuous field with
births, deaths and energy budgets. An episode is ten generations of sixty
ticks; a seat's score is its population's integrated biomass, but any role that
crashes the others crashes itself a generation later. Winning means staying in
balance.

Watch it at [softmax.com/ecos](https://softmax.com/ecos).

---

## The decision a seat actually makes

A seat never addresses one body. Once per generation it submits a **doctrine**:
four integers that reparameterise the deterministic per-body kernel its bodies
then run for sixty ticks.

| role | fields | default |
| --- | --- | --- |
| grass | `seed_threshold` 60..200, `seed_range` 24..240, `seed_cost` 20..80, `crowd_limit` 0..6 | 100 / 90 / 40 / 3 |
| grazers | `birth_threshold` 80..240, `bite` 2..14, `flee_range` 0..300, `herd` 0..100 | 90 / 10 / 40 / 20 |
| predators | `birth_threshold` 150..400, `hunt_range` 40..400, `rest_energy` 0..400, `spread` 0..100 | 400 / 140 / 200 / 40 |

That is thirty LLM calls an episode instead of a quarter of a million per-body
calls, and every body still runs a per-body vector policy.

Scoring is integrated biomass: `G(g)` is the generation's total biomass over
sixty ticks divided by the role's reference (grass 20 000, grazers 4 000,
predators 3 000), and the seat's score is `Σ min(G(g), 2.0)` over ten
generations. Higher is better. The `min(·, 2.0)` cap is the anti-boom clause: a
generation at twice reference pays no more than two generations at reference,
so a boom that risks a crash never pays more than steady abundance that does
not.

**The episode ends the instant any species reaches zero**, and every remaining
generation then scores zero for all three seats — including the seat that
caused it.

## A policy is just a prompt

Both policies ship in the same image, selected by environment variable:

```bash
# an LLM policy
coworld upload-policy coworld-ecos:latest --name my-ecos \
  --run /bin/ecos-player --secret-env PLAYER_PROMPT="<your strategy>"

# a scripted baseline
coworld upload-policy coworld-ecos:latest --name my-ecos-baseline \
  --run /bin/ecos-player --secret-env PLAYER_SCRIPTED=steward
```

`/bin/ecos-player` connects, sends its prompt once and then only listens: all
decision-making happens in the **game** container (`src/ecos/llm.nim`), which
is what makes one parallel batch of three requests per generation possible.
With no credentials the client disables itself immediately and every seat plays
the `steward` baseline, so offline certification still completes.

Seats see only the aliases `Sedge`, `Bramble` and `Quill` and their role names.
Policy names exist spectator-side only — in the replay, the scorebug and
`results.names`.

## Layout

| path | what |
| --- | --- |
| `src/ecos/sim_types.nim` | every constant, the body record, the doctrine vector |
| `src/ecos/sim_config.nim` | `GameConfig` and the runtime `config.update` overlay |
| `src/ecos/sim_state.nim` | the seeded integer RNG, brad trigonometry, the game hash |
| `src/ecos/sim.nim` | the ten numbered tick rules, the generation clock, scoring |
| `src/ecos/events.nim` | the replay's event vocabulary |
| `src/ecos/scripted.nim` | the `steward` and `opportunist` baselines |
| `src/ecos/llm.nim` | the batched decision layer (forked from cogame-bullwhip) |
| `src/ecos/replays.nim` | the `ecos.replay.v1` writer, reader and playhead |
| `src/ecos/global.nim` | the sprite-protocol board renderer |
| `src/ecos/broadcast.nim` | the chrome frame the viewer draws from |
| `src/ecos/server.nim` | routes, the generation loop, artifacts, shutdown grace |
| `src/ecos.nim`, `src/ecos_player.nim` | the two entry points in the one image |
| `client/` | the broadcast chrome (paintbot's, verbatim) plus the Ecos page |
| `replay-viewer/` | the static wasm bundle: never a `/client/replay` pod |
| `scripts/art/gen_ecos_art.py` | the deterministic art generator |
| `docs/plans/` | the accepted design note |

## Building and testing

The sandbox that wrote this repo has no Docker, no Nim and no emsdk: `ci.yml`
is the harness.

```bash
nimby use 2.2.4 && nimby --global sync nimby.lock
nim r --path:src tests/test_sim.nim          # and the other eight
docker build --platform=linux/amd64 -t coworld-ecos:ci .
tools/ci/docker_smoke.sh coworld-ecos:ci     # one real 3-seat episode
tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
node tools/ci/viewer_smoke.mjs --bundle dist/static-replay-viewer \
  --replay dist/smoke/replay.json
```

`tests/test_feasibility.nim` is the ecological oracle: it re-runs the design
note's solvability check over both variants and fails if a constant change
breaks the ecology. Change a number in `src/ecos/sim_types.nim` and that is
where you will hear about it — not in a dead replay.

## Regenerating the art

```bash
python3 -m pip install "pillow>=10"
python3 scripts/art/gen_ecos_art.py          # soil, tufts, fx, lockerroom bg + grass
python3 scripts/art/split_creature_sheet.py  # grazer/predator sprites + portraits
```

The soil, tufts and fx are deterministic and committed, so that art is
reviewable in a diff rather than dropped in as binaries. The grazer and
predator are nano-banana (Gemini image) renders of the Softmax cog styled as
each animal — predator: dark chassis, red accents, fangs and claws; grazer:
cream chassis, antlers/ears and a grass-green saddle-pack. The source sheet
lives at `scripts/art/source/creatures_sheet.png` and the split script keys,
crops and sizes it; the board draws 1:1, so the PNG size is the body size.
