## The Ecos replay file (`ecos.replay.v1`) — writer and reader.
##
## Ecos records **state**, not inputs, so playback never re-simulates: a seek
## is an array index, the wasm module decodes and draws, and there is no
## native/wasm divergence to chase. Strict UTF-8 JSON, one document.
##
## The writer builds the bulk (frames, series) with a string buffer because
## `%*` over ~700 000 integers is needlessly slow; the reader uses jsony,
## which fills `seq[int]` directly instead of allocating a JsonNode per
## integer (that alone is the difference between a viewer that loads in a
## second and one that thrashes wasm32's address space).

import std/[json, strutils]
import jsony
import sim_types, sim_config, sim, events

type
  ReplayFrame* = object
    t*: int
    g*, h*, p*: seq[int]

  ReplaySeries* = object
    pop*, bio*: seq[seq[int]]

  ReplayConfigDoc* = object
    fieldW*, fieldH*: int
    generations*, ticksPerGeneration*: int
    capGrass*, capGrazers*, capPredators*: int
    references*: seq[int]
    grassGain*, shadeRadius*: int
    initGrass*, initGrazers*, initPredators*: int
    variant*: string

  ReplayDoc* = object
    protocol*, game*, gameVersion*: string
    seed*, roleOffset*: int
    names*, policyNames*, roles*: seq[string]
    config*: ReplayConfigDoc
    frames*: seq[ReplayFrame]
    series*: ReplaySeries
    events*: seq[JsonNode]
    results*: JsonNode

proc addIntArray(buffer: var string, values: openArray[int]) =
  buffer.add('[')
  for i, value in values:
    if i > 0: buffer.add(',')
    buffer.addInt(value)
  buffer.add(']')

proc replayBytes*(sim: SimServer, results: JsonNode): string =
  ## The whole replay, as the bytes the platform stores. Everything the
  ## viewer needs is here: names, policy names, roles, config, seed, per-tick
  ## state, events, results. No server is contacted except S3 for the file.
  result = newStringOfCap(4_000_000)
  result.add("{\"protocol\":" & escapeJson(ReplayProtocol))
  result.add(",\"game\":\"ecos\"")
  result.add(",\"gameVersion\":" & escapeJson(GameVersion))
  result.add(",\"seed\":" & $sim.config.seed)
  result.add(",\"roleOffset\":" & $sim.roleOffset)
  result.add(",\"names\":[")
  for slot in 0 .. 2:
    if slot > 0: result.add(',')
    result.add(escapeJson(sim.names[slot]))
  result.add("],\"policyNames\":[")
  for slot in 0 .. 2:
    if slot > 0: result.add(',')
    result.add(escapeJson(sim.policyNames[slot]))
  result.add("],\"roles\":[")
  for slot in 0 .. 2:
    if slot > 0: result.add(',')
    result.add(escapeJson(RoleNames[sim.roleOf[slot]]))
  result.add("],\"config\":" & $sim.config.configJson())
  result.add(",\"frames\":[")
  for index, frame in sim.frames:
    if index > 0: result.add(',')
    result.add("{\"t\":")
    result.addInt(index)
    result.add(",\"g\":")
    result.addIntArray(frame.g)
    result.add(",\"h\":")
    result.addIntArray(frame.h)
    result.add(",\"p\":")
    result.addIntArray(frame.p)
    result.add('}')
  result.add("],\"series\":{\"pop\":[")
  for index, row in sim.seriesPop:
    if index > 0: result.add(',')
    result.addIntArray([index, row[0], row[1], row[2]])
  result.add("],\"bio\":[")
  for index, row in sim.seriesBio:
    if index > 0: result.add(',')
    result.addIntArray([index, row[0], row[1], row[2]])
  result.add("]},\"events\":[")
  for index, event in sim.events:
    if index > 0: result.add(',')
    result.add($eventToJson(event))
  result.add("],\"results\":" & $results & "}")

proc parseReplayBytes*(data: string): ReplayDoc =
  ## Reads a recorded replay. Raises on anything that is not this protocol —
  ## the viewer reports the message rather than drawing a blank board.
  if data.len == 0:
    raise newException(EcosError, "replay is empty")
  result = data.fromJson(ReplayDoc)
  if result.protocol != ReplayProtocol:
    raise newException(EcosError,
      "not an " & ReplayProtocol & " replay: " & result.protocol)
  if result.frames.len == 0:
    raise newException(EcosError, "replay carries no frames")
  if result.names.len != 3 or result.roles.len != 3:
    raise newException(EcosError, "replay must name exactly three seats")

proc capOf*(doc: ReplayDoc, index: int): int =
  case index
  of 0: doc.config.capGrass
  of 1: doc.config.capGrazers
  else: doc.config.capPredators

proc bodyCount*(frame: ReplayFrame, index: int): int =
  case index
  of 0: frame.g.len div 3
  of 1: frame.h.len div 3
  else: frame.p.len div 3

proc bodyAt*(frame: ReplayFrame, index, i: int): tuple[x, y, e: int] =
  let flat =
    case index
    of 0: unsafeAddr frame.g
    of 1: unsafeAddr frame.h
    else: unsafeAddr frame.p
  (flat[][i * 3], flat[][i * 3 + 1], flat[][i * 3 + 2])

# ---- playback ----------------------------------------------------------------

import global, broadcast

type
  ReplayPlayer* = object
    ## Playback over recorded STATE: a seek is an array index, so there is no
    ## re-simulation and no native/wasm divergence to chase.
    doc*: ReplayDoc
    tick*: int
    accumulated*: int
    desat*: seq[int]                  ## per-tick silent-spring ramp, 0..DesatTicks
    scoreAt*: seq[array[3, float]]    ## running per-species score, by tick
    eventStart*: seq[int]             ## first event index at each tick
    tracker*: BroadcastTracker

proc precompute(player: var ReplayPlayer) =
  let doc = addr player.doc
  let ticks = doc[].frames.len
  player.desat = newSeq[int](ticks)
  player.scoreAt = newSeq[array[3, float]](ticks)
  var alarmed: array[3, bool]
  var ramp: array[3, int]
  var accum: array[3, int]
  var score: array[3, float]
  let perGeneration = max(1, doc[].config.ticksPerGeneration)
  for tick in 0 ..< ticks:
    let row =
      if tick < doc[].series.pop.len and doc[].series.pop[tick].len >= 4:
        doc[].series.pop[tick]
      else:
        @[tick, 0, 0, 0]
    let bioRow =
      if tick < doc[].series.bio.len and doc[].series.bio[tick].len >= 4:
        doc[].series.bio[tick]
      else:
        @[tick, 0, 0, 0]
    var worst = 0
    for index in 0 .. 2:
      let cap = max(1, doc[].capOf(index))
      let pop = row[index + 1]
      if not alarmed[index] and pop * 100 < AlarmFraction * cap:
        alarmed[index] = true
      elif alarmed[index] and pop * 100 >= RecoverFraction * cap:
        alarmed[index] = false
      ramp[index] =
        if alarmed[index]: min(DesatTicks, ramp[index] + 1)
        else: max(0, ramp[index] - 1)
      if ramp[index] > worst: worst = ramp[index]
      if tick > 0:
        accum[index] += bioRow[index + 1]
      ## Flushed on a generation boundary AND on the last recorded tick: an
      ## episode that ends mid-generation (a collapse) has its partial window
      ## closed and scored by the sim against the FULL denominator
      ## (`sim.nim`'s `step` → `closeGeneration`), so a viewer that dropped
      ## the residue would sit below `results.scores` on every collapse.
      if tick > 0 and (tick mod perGeneration == 0 or tick == ticks - 1):
        let reference =
          if index < doc[].config.references.len: doc[].config.references[index]
          else: 1
        let generation = float(accum[index]) /
          float(perGeneration * max(1, reference))
        score[index] += min(generation, GenerationScoreCap)
        accum[index] = 0
    player.desat[tick] = desaturationStage(worst)
    player.scoreAt[tick] = score
  player.eventStart = newSeq[int](ticks + 2)
  var cursor = 0
  for tick in 0 .. ticks:
    while cursor < doc[].events.len and
        doc[].events[cursor]{"t"}.getInt() < tick:
      inc cursor
    player.eventStart[tick] = cursor
  player.eventStart[ticks + 1] = doc[].events.len

proc initReplayPlayer*(doc: ReplayDoc): ReplayPlayer =
  result.doc = doc
  result.tick = 0
  result.precompute()

proc lastTick*(player: ReplayPlayer): int = player.doc.frames.len - 1

proc boardFrame*(player: ReplayPlayer): BoardFrame =
  let frame = player.doc.frames[clampInt(player.tick, 0, player.lastTick)]
  result.tick = player.tick
  result.fieldW = player.doc.config.fieldW
  result.fieldH = player.doc.config.fieldH
  for index in 0 .. 2:
    let count = frame.bodyCount(index)
    result.bodies[index] = newSeq[BoardBody](count)
    for i in 0 ..< count:
      let body = frame.bodyAt(index, i)
      result.bodies[index][i] =
        BoardBody(x: body.x, y: body.y, energy: body.e)

proc eventsIn*(player: ReplayPlayer, fromTick, toTick: int): seq[JsonNode] =
  let lo = clampInt(fromTick, 0, player.eventStart.high)
  let hi = clampInt(toTick + 1, 0, player.eventStart.high)
  for index in player.eventStart[lo] ..< player.eventStart[hi]:
    result.add(player.doc.events[index])

proc chromeFrame*(player: var ReplayPlayer, view: GlobalViewerState,
    stepped: seq[JsonNode]): string =
  let doc = addr player.doc
  let tick = clampInt(player.tick, 0, player.lastTick)
  var input = ChromeInput(
    tick: tick,
    maxTick: player.lastTick,
    startTick: 0,
    generation: min(doc[].config.generations,
      tick div max(1, doc[].config.ticksPerGeneration) + 1),
    generations: doc[].config.generations,
    ticksPerGeneration: doc[].config.ticksPerGeneration,
    playing: view.playing,
    speed: view.speed,
    looping: view.looping,
    transportEnabled: true,
    over: tick >= player.lastTick,
    fieldW: doc[].config.fieldW,
    fieldH: doc[].config.fieldH,
    events: newJArray()
  )
  for node in stepped:
    input.events.add(node)
  let popRow =
    if tick < doc[].series.pop.len: doc[].series.pop[tick] else: @[tick, 0, 0, 0]
  let bioRow =
    if tick < doc[].series.bio.len: doc[].series.bio[tick] else: @[tick, 0, 0, 0]
  for index in 0 .. 2:
    input.pop[index] = popRow[index + 1]
    input.bio[index] = bioRow[index + 1]
    input.cap[index] = doc[].capOf(index)
    input.scores[index] = player.scoreAt[tick][index]
    input.alarmed[index] =
      input.pop[index] * 100 < AlarmFraction * max(1, input.cap[index])
  for slot in 0 .. 2:
    input.aliases[slot] =
      if slot < doc[].names.len: doc[].names[slot] else: SeatAliases[slot]
    input.policyNames[slot] =
      if slot < doc[].policyNames.len and doc[].policyNames[slot].len > 0:
        doc[].policyNames[slot]
      else:
        input.aliases[slot]
    input.roleOfSlot[slot] =
      if slot < doc[].roles.len: ord(speciesFromName(doc[].roles[slot]))
      else: slot
  if input.over:
    input.reason = doc[].results{"reason"}.getStr("complete")
    input.ending = doc[].results{"ending"}.getStr("ten_generations")
  if not player.tracker.leadSent:
    player.tracker.leadSent = true
    var pts = newJArray()
    for row in doc[].series.pop:
      if row.len < 4: continue
      var point = newJArray()
      point.add(%row[0])
      for index in 0 .. 2:
        point.add(%(row[index + 1] * 1000 div max(1, doc[].capOf(index))))
      pts.add(point)
    input.leadPts = pts
  buildStateJson(input)

proc advanceReplayFrame*(
  player: var ReplayPlayer,
  view: var GlobalViewerState
): tuple[frame: BoardFrame, fx: seq[FxItem], desat: int, chrome: string] =
  ## One playback frame: apply the transport commands, move the playhead,
  ## and hand back everything the board and the chrome need.
  let last = player.lastTick
  var previous = player.tick
  var jumped = false
  if view.restart:
    view.restart = false
    player.tick = 0
    jumped = true
  if view.replaySeekTick >= 0:
    player.tick = clampInt(view.replaySeekTick, 0, last)
    view.replaySeekTick = -1
    jumped = true
  if view.stepBack:
    view.stepBack = false
    player.tick = max(0, player.tick - 1)
    jumped = true
  if view.skipForward:
    view.skipForward = false
    player.tick = min(last, player.tick + 5 * TargetFps)
    jumped = true
  if view.jumpEnd:
    view.jumpEnd = false
    player.tick = last
    jumped = true
  if not jumped and view.playing:
    if player.tick >= last:
      if view.looping:
        player.tick = 0
        jumped = true
      else:
        view.playing = false
    else:
      player.tick = min(last, player.tick + max(1, view.speed))
  if jumped:
    previous = player.tick
  let stepped =
    if jumped: player.eventsIn(player.tick, player.tick)
    else: player.eventsIn(previous + 1, player.tick)
  result.frame = player.boardFrame()
  result.fx = collectFx(
    player.eventsIn(max(0, player.tick - FadeTicks), player.tick), player.tick)
  result.desat = player.desat[clampInt(player.tick, 0, last)]
  result.chrome = player.chromeFrame(view, stepped)
