## Ecos game configuration: defaults, the runtime `config.update` overlay and
## the variant knobs the manifest's `game.config_schema` declares.
##
## Forked from paintbot's `src/ctf/sim_config.nim`. Every field here appears
## in `coworld_manifest_template.json`'s config schema and nowhere else, so
## `tests/test_manifest.nim` can check the two agree.

import std/[json, strutils]
import sim_types

type
  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    numAgents*: int
    roleOffset*: int            ## -1 = derive from the seed
    generations*: int
    ticksPerGeneration*: int
    fieldW*, fieldH*: int
    initGrass*, initGrazers*, initPredators*: int
    grassGain*: int
    capGrass*, capGrazers*, capPredators*: int
    llmTimeoutSeconds*: int
    minTurnSeconds*: int
    maxOutputTokens*: int
    model*: string
    episodeTimeoutSeconds*: int
    playerConnectTimeoutSeconds*: int
    shutdownGraceSeconds*: int
    variant*: string

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    numAgents: 3,
    roleOffset: -1,
    generations: 10,
    ticksPerGeneration: 60,
    fieldW: DefaultFieldW,
    fieldH: DefaultFieldH,
    initGrass: 160,
    initGrazers: 40,
    initPredators: 10,
    grassGain: 5,
    capGrass: 220,
    capGrazers: 140,
    capPredators: 30,
    llmTimeoutSeconds: 25,
    minTurnSeconds: 6,
    maxOutputTokens: 900,
    model: "claude-haiku-4-5",
    episodeTimeoutSeconds: 1200,
    playerConnectTimeoutSeconds: 180,
    shutdownGraceSeconds: 20,
    variant: "standard"
  )

proc capOf*(config: GameConfig, species: Species): int =
  case species
  of spGrass: config.capGrass
  of spGrazers: config.capGrazers
  of spPredators: config.capPredators

proc initialCountOf*(config: GameConfig, species: Species): int =
  case species
  of spGrass: config.initGrass
  of spGrazers: config.initGrazers
  of spPredators: config.initPredators

proc validate*(config: GameConfig) =
  if config.numAgents != 3:
    raise newException(EcosError, "Ecos is a three-seat game; num_agents must be 3")
  if config.generations < 1 or config.generations > 12:
    raise newException(EcosError, "generations must be 1..12")
  if config.ticksPerGeneration < 10 or config.ticksPerGeneration > 90:
    raise newException(EcosError, "ticksPerGeneration must be 10..90")
  if config.roleOffset < -1 or config.roleOffset > 2:
    raise newException(EcosError, "roleOffset must be -1..2")
  if config.fieldW < 200 or config.fieldH < 200:
    raise newException(EcosError, "field must be at least 200x200")
  for species in Species:
    if config.capOf(species) < 1:
      raise newException(EcosError, "caps must be positive")
    if config.initialCountOf(species) < 1:
      raise newException(EcosError, "every species must open with a body")
    if config.initialCountOf(species) > config.capOf(species):
      raise newException(EcosError,
        "opening " & RoleNames[species] & " population exceeds its cap")

proc update*(config: var GameConfig, configJson: string) =
  ## Applies the platform's runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(EcosError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player{"name"}.getStr()))
  if node.hasKey("seed"): config.seed = node["seed"].getInt()
  if node.hasKey("num_agents"): config.numAgents = node["num_agents"].getInt()
  if node.hasKey("numAgents"): config.numAgents = node["numAgents"].getInt()
  if node.hasKey("roleOffset"): config.roleOffset = node["roleOffset"].getInt()
  if node.hasKey("generations"):
    config.generations = node["generations"].getInt()
  if node.hasKey("ticksPerGeneration"):
    config.ticksPerGeneration = node["ticksPerGeneration"].getInt()
  if node.hasKey("fieldW"): config.fieldW = node["fieldW"].getInt()
  if node.hasKey("fieldH"): config.fieldH = node["fieldH"].getInt()
  if node.hasKey("initGrass"): config.initGrass = node["initGrass"].getInt()
  if node.hasKey("initGrazers"):
    config.initGrazers = node["initGrazers"].getInt()
  if node.hasKey("initPredators"):
    config.initPredators = node["initPredators"].getInt()
  if node.hasKey("grassGain"): config.grassGain = node["grassGain"].getInt()
  if node.hasKey("capGrass"): config.capGrass = node["capGrass"].getInt()
  if node.hasKey("capGrazers"): config.capGrazers = node["capGrazers"].getInt()
  if node.hasKey("capPredators"):
    config.capPredators = node["capPredators"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if node.hasKey("minTurnSeconds"):
    config.minTurnSeconds = node["minTurnSeconds"].getInt()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("model"): config.model = node["model"].getStr()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("playerConnectTimeoutSeconds"):
    config.playerConnectTimeoutSeconds =
      node["playerConnectTimeoutSeconds"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getInt()
  if node.hasKey("shutdownGraceSeconds"):
    config.shutdownGraceSeconds = node["shutdownGraceSeconds"].getInt()
  if node.hasKey("variant"): config.variant = node["variant"].getStr()
  config.validate()

proc configJson*(config: GameConfig): JsonNode =
  ## The `config` block the replay carries, so the viewer needs no server.
  %*{
    "fieldW": config.fieldW,
    "fieldH": config.fieldH,
    "generations": config.generations,
    "ticksPerGeneration": config.ticksPerGeneration,
    "capGrass": config.capGrass,
    "capGrazers": config.capGrazers,
    "capPredators": config.capPredators,
    "references": [
      ReferenceBiomass[spGrass],
      ReferenceBiomass[spGrazers],
      ReferenceBiomass[spPredators]
    ],
    "grassGain": config.grassGain,
    "shadeRadius": ShadeRadius,
    "initGrass": config.initGrass,
    "initGrazers": config.initGrazers,
    "initPredators": config.initPredators,
    "variant": config.variant
  }
