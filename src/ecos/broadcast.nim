## Ecos broadcast chrome — the parallel JSON `TextMessage` the viewer reads
## to draw the scorebug, the clock, the doctrine feed, the transport and the
## population strip.
##
## Forked from paintbot's `src/ctf/broadcast.nim`: `BroadcastTracker` and
## `buildStateJson` keep their shape, teams become the three ROLES (so green
## is always grass whatever the role rotation) and `lead` becomes the
## population strip series. The binary sprite stream stays the board
## renderer; this is the chrome channel, smuggled as the label of sprite
## 4090 (see `global.nim`).

import std/json
import sim_types, global

type
  BroadcastTracker* = object
    ## Per-viewer state: the full-episode series ships ONCE (paintbot's
    ## `lead` trick) so the strip draws its full width on frame 1.
    leadSent*: bool

  ChromeInput* = object
    tick*, maxTick*, startTick*: int
    generation*, generations*, ticksPerGeneration*: int
    playing*: bool
    speed*: float
      ## The speed the chrome shows: 0.5 while the replay-only 1/2x
      ## (ReplayHalfSpeed) is selected, else the integer multiplier.
    looping*, skipLulls*, fastForward*, transportEnabled*: bool
    over*: bool
    reason*, ending*: string
    fieldW*, fieldH*: int
    pop*, bio*, cap*: array[3, int]
    scores*: array[3, float]        ## by SPECIES index
    policyNames*: array[3, string]  ## by SLOT
    aliases*: array[3, string]      ## by SLOT
    roleOfSlot*: array[3, int]      ## slot -> species index
    alarmed*: array[3, bool]
    events*: JsonNode
    leadPts*: JsonNode              ## nil once shipped

proc initBroadcastTracker*(): BroadcastTracker = BroadcastTracker()

proc slotOfRole(input: ChromeInput, speciesIndex: int): int =
  for slot in 0 .. 2:
    if input.roleOfSlot[slot] == speciesIndex:
      return slot
  0

proc teamsJson(input: ChromeInput): JsonNode =
  ## Keyed by the ROLE's chrome team key, so the board and the strip always
  ## read green = grass, yellow = grazers, red = predators.
  result = newJObject()
  for speciesIndex in 0 .. 2:
    let slot = input.slotOfRole(speciesIndex)
    result[RoleTeamKey[Species(speciesIndex)]] = %*{
      "role": RoleNames[Species(speciesIndex)],
      "alias": input.aliases[slot],
      "slot": slot,
      "pop": input.pop[speciesIndex],
      "bio": input.bio[speciesIndex],
      "cap": input.cap[speciesIndex],
      "score": input.scores[speciesIndex],
      "alarm": input.alarmed[speciesIndex],
      "policies": [input.policyNames[slot]],
      "lives": input.pop[speciesIndex]
    }

proc rosterJson(input: ChromeInput): JsonNode =
  result = newJArray()
  for slot in 0 .. 2:
    let speciesIndex = input.roleOfSlot[slot]
    result.add(%*{
      "s": slot,
      "name": input.policyNames[slot],
      "pol": input.policyNames[slot],
      "alias": input.aliases[slot],
      "team": RoleTeamKey[Species(speciesIndex)],
      "role": RoleNames[Species(speciesIndex)],
      "alive": input.pop[speciesIndex] > 0
    })

proc buildStateJson*(input: ChromeInput): string =
  ## The chrome frame. Board-derived STATE (populations, biomass, scores,
  ## roster, verdict) is always present, so a frame reached by a seek still
  ## hydrates the scorebug and the end-card with no events at all.
  var state = %*{
    "t": input.tick,
    "mt": input.generations * input.ticksPerGeneration,
    "ph": (if input.over: "gameover" else: "playing"),
    "lob": 0,
    "pl": input.playing,
    "sp": input.speed,
    "mx": input.maxTick,
    "st": input.startTick,
    "lp": input.looping,
    "sk": input.skipLulls,
    "ff": input.fastForward,
    "en": input.transportEnabled,
    "mm": -1,
    "bs": boardRenderScaleFor(input.fieldW, input.fieldH),
    "pov": -1,
    "gen": input.generation,
    "gens": input.generations,
    "tpg": input.ticksPerGeneration,
    "teams": input.teamsJson(),
    "roster": input.rosterJson(),
    "events": (if input.events.isNil: newJArray() else: input.events)
  }
  if not input.leadPts.isNil:
    ## The population strip: one stepped line per species, each already
    ## normalised by its own cap (permille), so `renderMomentum`'s shared
    ## 0..peak axis puts all three on the same 0..1 scale.
    state["lead"] = %*{
      "teams": [RoleTeamKey[spGrass], RoleTeamKey[spGrazers],
                RoleTeamKey[spPredators]],
      "pts": input.leadPts
    }
  if input.over:
    var overTeams = newJObject()
    for speciesIndex in 0 .. 2:
      overTeams[RoleTeamKey[Species(speciesIndex)]] = %*{
        "lives": input.pop[speciesIndex],
        "pop": input.pop[speciesIndex],
        "bio": input.bio[speciesIndex],
        "score": input.scores[speciesIndex]
      }
    var winner = ""
    var best = -1.0
    for speciesIndex in 0 .. 2:
      if input.scores[speciesIndex] > best:
        best = input.scores[speciesIndex]
        winner = RoleTeamKey[Species(speciesIndex)]
    var draws = 0
    for speciesIndex in 0 .. 2:
      if input.scores[speciesIndex] == best: inc draws
    state["over"] = %*{
      "winner": winner,
      "draw": draws > 1,
      "timeLimit": input.ending == "ten_generations",
      "reason": input.reason,
      "ending": input.ending,
      "teams": overTeams
    }
  $state
