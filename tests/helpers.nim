## Shared test scaffolding: run a headless Ecos episode with a fixed doctrine
## policy and hand back the finished sim. Kept dependency-free so every test
## file can run standalone under `nim r tests/<file>.nim`.

import ../src/ecos/[sim, sim_types, sim_config, scripted, events]

export sim, sim_types, sim_config, scripted, events

type DoctrinePicker* = proc(s: SimServer, species: Species): Doctrine {.closure.}

proc standardConfig*(seed: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.roleOffset = 0
  result.tokens = @["t0", "t1", "t2"]
  result.players = @[
    PlayerConfig(name: "ecos-keeper"),
    PlayerConfig(name: "ecos-steward"),
    PlayerConfig(name: "ecos-bloom")
  ]

proc harshSpringConfig*(seed: int): GameConfig =
  ## The shipped `harsh-spring` variant. These are the values gate (a)
  ## accepted after the design note's repair rule (initGrass 120 -> 140 ->
  ## 160, then grassGain 4 -> 5) was applied in that order.
  result = standardConfig(seed)
  result.variant = "harsh-spring"
  result.initGrass = 160
  result.grassGain = 5
  result.initGrazers = 32
  result.initPredators = 8

proc scriptedPicker*(kind: ScriptKind): DoctrinePicker =
  proc pick(s: SimServer, species: Species): Doctrine {.closure.} =
    scriptedDoctrine(s, species, kind)
  pick

proc fixedPicker*(overrides: array[Species, Doctrine]): DoctrinePicker =
  proc pick(s: SimServer, species: Species): Doctrine {.closure.} =
    discard s
    clampDoctrine(species, overrides[species]).fields
  pick

proc runEpisode*(config: GameConfig, pick: DoctrinePicker): SimServer =
  ## Plays a whole episode, submitting one doctrine per seat per generation
  ## exactly the way the server does.
  result = newSim(config)
  while not result.done:
    for species in Species:
      result.applyDoctrine(species, pick(result, species), dsScripted, false,
        "", "", 0)
    result.runGeneration()

proc stewardEpisode*(config: GameConfig): SimServer =
  runEpisode(config, scriptedPicker(skSteward))
