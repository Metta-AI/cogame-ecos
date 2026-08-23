## Ecos entrypoint: reads the Coworld runtime contract and starts the episode
## server. Forked from paintbot's `src/ctf.nim` — the seed is randomised
## BEFORE `config.update`'s successor draws anything, because every
## seed-derived value (the opening placement and the role rotation) must
## follow the final seed.

import std/[json, strutils, sysrand]
import bitworld/runtime
import ecos/[server, sim_config, sim_state, sim_types]

proc randomSeed(): int =
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(EcosError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc seedPinned(configJson: string): bool =
  if configJson.strip().len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed")
  except CatchableError:
    false

when isMainModule:
  let runtimeConfig = readRuntimeConfig()

  if runtimeConfig.replayMode:
    ## Ecos ships a STATIC wasm replay bundle; it never declares a
    ## `/client/replay` pod, so replay mode is never scheduled. Exit cleanly
    ## rather than pretending to serve one.
    logLine("ecos: replay mode is not used — Ecos ships a static replay " &
      "bundle (replay_viewer.bundle = static-replay-viewer)")
    quit(0)

  var config = defaultGameConfig()
  config.update(runtimeConfig.config)
  if not seedPinned(runtimeConfig.config):
    ## An unpinned seed is randomised so the role rotation and the opening
    ## placement are not precomputable.
    config.seed = randomSeed()
    logLine("ecos: seed not pinned; randomized to " & $config.seed)
  if config.tokens.len == 0:
    config.tokens = @["token-0", "token-1", "token-2"]
  while config.players.len < config.tokens.len:
    config.players.add(PlayerConfig(name: SeatAliases[config.players.len]))
  config.validate()
  logLine("ecos: seats=" & $config.players.len &
    " generations=" & $config.generations &
    " ticksPerGeneration=" & $config.ticksPerGeneration &
    " variant=" & config.variant &
    " seed=" & $config.seed)
  runGameServer(config, runtimeConfig)
