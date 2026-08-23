## Ecos wire and sim types.
##
## Forked from paintbot's `src/ctf/sim_types.nim`: the constants the whole
## engine agrees on, the body/species records, and the doctrine vector each
## seat submits once per generation. Field order is sacred — the replay's
## flat integer triples and the wasm viewer both read positionally.
##
## EVERY quantity here is an integer. Positions are whole world units,
## headings are brads (0..255) resolved through a 256-entry integer sine
## table, and the RNG is a seeded integer stream, so one seed reproduces one
## replay bit-exactly on any host (tests/test_sim.nim depends on it).

import std/[json, strutils]

type
  EcosError* = object of CatchableError

  Species* = enum
    spGrass = "grass"
    spGrazers = "grazers"
    spPredators = "predators"

  Body* = object
    ## One organism. Same layout for all three species; unused fields stay 0.
    x*, y*: int
    energy*: int
    age*: int
    heading*: int      ## brads, 0..255
    cooldown*: int     ## predators only: ticks until the next kill is allowed

  Doctrine* = array[4, int]
    ## The four integers a seat submits per generation. Their meaning is
    ## role-dependent — see `DoctrineFieldNames` / `doctrineRange`.

  PlayerConfig* = object
    name*: string

const
  GameVersion* = "1"
    ## Bumped whenever the recorded state-frame layout changes.
  ReplayProtocol* = "ecos.replay.v1"
  PlayerProtocol* = "ecos.player.v1"

  # ---- field and clock -----------------------------------------------------
  DefaultFieldW* = 1000
  DefaultFieldH* = 562
  BorderMargin* = 20        ## opening bodies are placed this far inside the edge

  # ---- caps and ceilings ---------------------------------------------------
  GrassEMax* = 200
  GrazerEMax* = 260
  PredatorEMax* = 480

  # ---- rule 1: photosynthesis ----------------------------------------------
  ShadeRadius* = 55
  GrassMetabolism* = 1

  # ---- rules 2..4: grazers -------------------------------------------------
  CrowdRadius* = 60
  BiteRadius* = 16
  GrazerMetabolism* = 1
  GrazerFleeMetabolism* = 2
  GrazerSpeed* = 6
  GrazerFleeSpeed* = 9
  GrazerManyEyesSpeed* = 11 ## flee speed when crowd >= ManyEyesCrowd
  ManyEyesCrowd* = 4
  HerdRadius* = 200
  ConversionPercentNum* = 4 ## grazer keeps (bite * 4) div 5 of what it bites
  ConversionPercentDen* = 5

  # ---- rules 5..6: predators -----------------------------------------------
  PredatorIdle* = 1
  PredatorChase* = 3
  PredatorRoam* = 2
  PredatorChaseSpeed* = 12
  PredatorSpeed* = 7
  PredatorRoamPeriod* = 12
  KillRadius* = 16
  KillBase* = 90
  KillCap* = 180
  HuntCooldown* = 12
  SpreadRadius* = 200

  # ---- rule 9: births ------------------------------------------------------
  SplitOverhead* = 20
  SeedLoss* = 10
  ChildOffset* = 8          ## world units a grazer/predator child is born away

  # ---- scoring -------------------------------------------------------------
  ReferenceBiomass*: array[Species, int] = [20000, 4000, 3000]
  GenerationScoreCap* = 2.0 ## the anti-boom clause: min(G_i(g), 2.0)

  # ---- alarm / crash chrome ------------------------------------------------
  AlarmFraction* = 15       ## permyriad/100: a species below 0.15 x cap alarms
  RecoverFraction* = 20     ## and recovers above 0.20 x cap

  # ---- text caps (rune counts, never bytes) --------------------------------
  MaxSayLen* = 64
  MaxNotesLen* = 400
  MaxPromptLen* = 4000

  # ---- decision cadence ----------------------------------------------------
  PlayBudgetFraction* = 0.6
    ## Share of `episodeTimeoutSeconds` spent playing. The rest covers
    ## container start, player connects and writing the artifacts.

  RoleNames*: array[Species, string] = ["grass", "grazers", "predators"]
  RoleTeamKey*: array[Species, string] = ["green", "yellow", "red"]
    ## chrome team key by ROLE (not by slot), so green is always grass.
  SeatAliases*: array[3, string] = ["Sedge", "Bramble", "Quill"]

  DoctrineFieldNames*: array[Species, array[4, string]] = [
    ["seed_threshold", "seed_range", "seed_cost", "crowd_limit"],
    ["birth_threshold", "bite", "flee_range", "herd"],
    ["birth_threshold", "hunt_range", "rest_energy", "spread"]
  ]

  DoctrineMin*: array[Species, Doctrine] = [
    [60, 24, 20, 0],
    [80, 2, 0, 0],
    [150, 40, 0, 0]
  ]
  DoctrineMax*: array[Species, Doctrine] = [
    [200, 240, 80, 6],
    [240, 14, 300, 100],
    [400, 400, 400, 100]
  ]
  StewardDoctrine*: array[Species, Doctrine] = [
    [100, 90, 40, 3],
    [90, 10, 40, 20],
    [400, 140, 200, 40]
  ]
  OpportunistDoctrine*: array[Species, Doctrine] = [
    [120, 140, 30, 4],
    [100, 12, 30, 20],
    [280, 200, 300, 30]
  ]

  SpeciesEMax*: array[Species, int] = [GrassEMax, GrazerEMax, PredatorEMax]

proc clampInt*(value, lo, hi: int): int {.inline.} =
  if value < lo: lo elif value > hi: hi else: value

proc clampDoctrine*(species: Species, doctrine: Doctrine):
    tuple[fields: Doctrine, clamped: bool] =
  ## Every doctrine that reaches the sim is inside its declared range; a
  ## reply that was out of range is recorded as `"clamped": true`.
  for i in 0 .. 3:
    let v = clampInt(doctrine[i], DoctrineMin[species][i],
      DoctrineMax[species][i])
    if v != doctrine[i]:
      result.clamped = true
    result.fields[i] = v

proc doctrineJson*(species: Species, doctrine: Doctrine): JsonNode =
  result = newJObject()
  for i in 0 .. 3:
    result[DoctrineFieldNames[species][i]] = %doctrine[i]

proc speciesFromName*(name: string): Species =
  case name.strip().toLowerAscii()
  of "grass": spGrass
  of "grazers", "grazer": spGrazers
  of "predators", "predator": spPredators
  else: raise newException(EcosError, "unknown species: " & name)
