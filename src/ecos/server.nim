## Ecos game server: the Coworld game contract.
##
## Forked from paintbot's `src/ctf/server.nim` route/artifact/shutdown
## skeleton, with bullwhip's JSON player protocol. Hosted certification's
## episode runner probes exactly these routes BEFORE the player pods start,
## and pings the `/global` websocket AFTER they do (LEARNINGS 2026-08-23
## lantern), which is why `/healthz` and `/global` keep answering for
## `shutdownGraceSeconds` after the artifacts are written.
##
##   GET /healthz                       200 ok
##   GET /client/player?slot=N&token=T  the seat's page (view only)
##   GET /client/global                 the broadcast client
##   GET /client/<asset>                the chrome scripts and art
##   WS  /player?slot=N&token=T         the seat socket
##   WS  /global                        live spectator: sprite protocol +
##                                      the chrome TextMessage
##
## `ecos.player.v2` frames, JSON text:
##   game -> player: welcome, state, decision (private view), final
##   player -> game: action (complete four-field doctrine, say, notes)

import std/[json, locks, os, sets, strutils, tables, times]
import bitworld/runtime
import curly
import mummy
import mummy/routers
import sim_types, sim_config, sim, sim_state, events, scripted, decision,
  replays, global, broadcast

type
  GameState = object
    config: GameConfig
    sim: SimServer
    pendingGeneration: int
    decisions: seq[Decision]
    actionReceived: seq[bool]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    viewers: Table[WebSocket, GlobalViewerState]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server

initLock(stateLock)

const
  GlobalPage = staticRead("../../client/replay_broadcast.html")
  PlayerPage = staticRead("../../client/player.html")
  BroadcastCoreJs = staticRead("../../client/broadcast_core.js")
  ChromeCommonJs = staticRead("../../client/chrome_common.js")
  BoardFontTtf = staticRead("../../data/font.ttf")

proc globalPageHtml(): string =
  ## The same page the static bundle ships, spliced for live serving: the
  ## wire constants inline, the chrome library and the live board renderer as
  ## RELATIVE script tags (the page is served from three different prefixes;
  ## a leading slash is only correct at one of them).
  result = spliceWireConstants(GlobalPage)
  result = result.replace("<!-- CHROME_COMMON -->",
    "<script src=\"./chrome_common.js\"></script>")
  result = result.replace("<!-- BROADCAST_CORE -->",
    "<script src=\"./broadcast_core.js\"></script>")

# ---- board frames ------------------------------------------------------------

proc boardFrameOf(sim: SimServer): BoardFrame =
  result.tick = sim.tick
  result.fieldW = sim.config.fieldW
  result.fieldH = sim.config.fieldH
  for species in Species:
    let index = ord(species)
    result.bodies[index] = newSeq[BoardBody](sim.bodies[species].len)
    for i, body in sim.bodies[species]:
      result.bodies[index][i] =
        BoardBody(x: body.x, y: body.y, energy: body.energy)

proc recentEventsJson(sim: SimServer, fromTick: int): seq[JsonNode] =
  for i in countdown(sim.events.high, 0):
    if sim.events[i].tick < fromTick:
      break
    result.insert(eventToJson(sim.events[i]), 0)

proc chromeInputOf(gs: GameState, viewer: GlobalViewerState,
    stepped: seq[JsonNode]): ChromeInput =
  let sim = gs.sim
  result = ChromeInput(
    tick: sim.tick,
    maxTick: gs.config.generations * gs.config.ticksPerGeneration,
    startTick: 0,
    generation: sim.generation,
    generations: gs.config.generations,
    ticksPerGeneration: gs.config.ticksPerGeneration,
    playing: true,
    speed: 1.0,
    looping: false,
    transportEnabled: false,
    over: sim.done,
    reason: sim.reason,
    ending: sim.ending,
    fieldW: gs.config.fieldW,
    fieldH: gs.config.fieldH,
    events: newJArray()
  )
  discard viewer
  for node in stepped:
    result.events.add(node)
  for species in Species:
    let index = ord(species)
    result.pop[index] = sim.population(species)
    result.bio[index] = sim.biomass(species)
    result.cap[index] = sim.capOf(species)
    result.scores[index] = sim.scores[species]
    result.alarmed[index] = sim.alarmed[species]
  for slot in 0 .. 2:
    result.aliases[slot] = sim.names[slot]
    result.policyNames[slot] = sim.policyNames[slot]
    result.roleOfSlot[slot] = ord(sim.roleOf[slot])
  ## No `lead` series on the LIVE path. `chrome_common.js` latches the first
  ## series it is sent and then stops accumulating (`ingestLeadSeries` ->
  ## `recordMomentum`), so shipping the one row a spectator who connects at
  ## tick 0 has would freeze the population strip at a single point for the
  ## whole episode. Fed frame by frame instead — paintbot's lives series —
  ## the strip grows as it plays. The ship-once trick belongs to the RECORDED
  ## replay, where the whole series exists up front (`replays.nim`).

proc sendBoard(gs: var GameState, socket: WebSocket,
    stepped: seq[JsonNode]) =
  var viewer = gs.viewers.getOrDefault(socket, initGlobalViewerState())
  let chrome = buildStateJson(gs.chromeInputOf(viewer, stepped))
  let packet = buildBoardPacket(viewer, boardFrameOf(gs.sim), @[], 0, chrome)
  gs.viewers[socket] = viewer
  for chunk in chunkSpritePacket(packet, 400_000):
    socket.send(cast[string](chunk), BinaryMessage)

proc broadcastLocked(gs: var GameState, fromTick: int) =
  ## Callers hold stateLock.
  let stepped = gs.sim.recentEventsJson(fromTick)
  for socket in gs.globalSockets:
    gs.sendBoard(socket, stepped)
  for slot, socket in gs.playerSockets:
    socket.send($gs.sim.observationJson(slot))

# ---- artifacts ---------------------------------------------------------------

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  var grace = 20
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    grace = state.config.shutdownGraceSeconds
    if not state.sim.done:
      state.sim.endEarly()
    results = state.sim.resultsJson()
    replayData = replayBytes(state.sim, results)

    ## Final frames go out BEFORE the artifacts are written: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection. Players get the
    ## ALIASES; `results.names` carries the policy names for the platform.
    var aliases = newJArray()
    for slot in 0 .. 2:
      aliases.add(%state.sim.names[slot])
    var roles = newJArray()
    for slot in 0 .. 2:
      roles.add(%RoleNames[state.sim.roleOf[slot]])
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "roles": roles,
      "names": aliases,
      "generations": state.sim.generationsPlayed,
      "reason": results["reason"],
      "ending": results["ending"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked(max(0, state.sim.tick))

  sleep(500)
  logLine("ecos: writing results and replay (" & $replayData.len & " bytes)")
  writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD")
  writeArtifact(runtimeConfig.replayUri, replayData, "application/json",
    "COGAME_SAVE_REPLAY_METHOD")
  if runtimeConfig.logUri.len > 0:
    try:
      writeArtifact(runtimeConfig.logUri, gameLogText(), "text/plain",
        "COGAME_LOG_METHOD")
    except CatchableError as error:
      logLine("ecos: log artifact failed: " & error.msg)

  ## Lantern's grace: hosted certification pings the global websocket AFTER
  ## the pods start, and a fast scripted episode has already exited by then.
  ## The runner waits on process exit anyway, so the grace is free.
  logLine("ecos: artifacts written; holding /healthz and /global for " &
    $grace & "s")
  sleep(grace * 1000)
  logLine("ecos: episode complete, shutting down")
  quit(0)

# ---- the generation loop -----------------------------------------------------

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let connectDeadline = gameStart +
      float(config.playerConnectTimeoutSeconds)

    while epochTime() < connectDeadline:
      var connected = 0
      withLock stateLock:
        connected = state.playerSockets.len
      if connected >= config.tokens.len:
        break
      sleep(200)

    var anyConnected = false
    withLock stateLock:
      state.started = true
      anyConnected = state.playerSockets.len > 0
      logLine("ecos: starting with " & $state.playerSockets.len & "/" &
        $config.tokens.len & " seats connected")
      state.broadcastLocked(0)

    if not anyConnected and config.tokens.len > 0:
      logLine("ecos: no seat connected within " &
        $config.playerConnectTimeoutSeconds & "s; forfeiting")
      withLock stateLock:
        state.sim.forfeit()
      finishEpisode(runtimeConfig)
      return

    ## The platform kills an episode that outruns its timeout and keeps
    ## nothing, and the game container is NOT given the timeout — only the
    ## worker sidecar is. Assume the configured default when the env is
    ## silent and settle inside 60% of it.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = float(config.episodeTimeoutSeconds)
    let playDeadline = gameStart + timeoutSeconds * PlayBudgetFraction
    ## What starting one more generation commits to: a batch, a retry batch,
    ## a generation of simulation and up to `minTurnSeconds` of floor sleep.
    ## The deadline is checked BETWEEN generations only (the note's rule), so
    ## it has to be met with that reserve in hand or the settle lands outside
    ## the 60 % play budget it is meant to fit inside.
    let generationReserve =
      float(config.actionTimeoutSeconds + config.minTurnSeconds)
    logLine("ecos: episode timeout " & $int(timeoutSeconds) & "s (" &
      (if hostedTimeout.len > 0: "from env" else: "assumed") &
      "); playing until " & $int(timeoutSeconds * PlayBudgetFraction) &
      "s, last generation started by " &
      $int(timeoutSeconds * PlayBudgetFraction - generationReserve) & "s")

    while true:
      let seats = @[0, 1, 2]
      withLock stateLock:
        if state.sim.done:
          break
        if epochTime() + generationReserve > playDeadline:
          logLine("ecos: play deadline reached after " &
            $state.sim.generationsPlayed & "/" & $config.generations &
            " generations; ending early")
          state.sim.endEarly()
          state.broadcastLocked(state.sim.tick)
          break
        state.pendingGeneration = state.sim.generation
        state.actionReceived = newSeq[bool](seats.len)
        for slot, socket in state.playerSockets:
          socket.send($ %*{
            "type": "decision",
            "protocol": PlayerProtocol,
            "generation": state.pendingGeneration,
            "timeout_ms": config.actionTimeoutSeconds * 1000,
            "view": state.sim.observationJson(slot)
          })

      ## All seats receive the same boundary before any doctrine is applied.
      let batchStart = epochTime()
      let decisionDeadline = batchStart + float(config.actionTimeoutSeconds)
      while epochTime() < decisionDeadline:
        var complete = true
        withLock stateLock:
          for slot in seats:
            if state.playerSockets.hasKey(slot) and
                not state.actionReceived[slot]:
              complete = false
        if complete:
          break
        sleep(20)

      var fromTick = 0
      withLock stateLock:
        fromTick = state.sim.tick
        for slot in seats:
          let decision =
            if state.actionReceived[slot]: state.decisions[slot]
            else: scriptedDecision(state.sim, state.sim.roleOf[slot], skNone)
          let species = state.sim.roleOf[slot]
          logLine("ecos: gen " & $state.sim.generation & " " &
            state.sim.names[slot] & " (" & RoleNames[species] & ") " &
            $decision.fields & " via " & $decision.source &
            (if decision.say.len > 0: " says \"" & decision.say & "\"" else: ""))
          state.sim.applyDoctrine(species, decision.fields, decision.source,
            decision.clamped, decision.say, decision.notes, decision.latencyMs)
        state.sim.runGeneration()
        logLine("ecos: " & state.sim.summaryLine())
        state.broadcastLocked(fromTick)

      ## Floor the spacing between generation starts for sidecar rate limits.
      let elapsed = epochTime() - batchStart
      let floorSeconds = float(config.minTurnSeconds)
      if elapsed < floorSeconds:
        sleep(int((floorSeconds - elapsed) * 1000.0))

    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

# ---- routes ------------------------------------------------------------------

proc respondText(request: Request, body, contentType: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = contentType
  request.respond(200, headers, body)

proc healthzHandler(request: Request) {.gcsafe.} =
  respondText(request, """{"ok": true}""", "application/json")

proc globalPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    respondText(request, globalPageHtml(), "text/html; charset=utf-8")

proc playerPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    respondText(request, PlayerPage, "text/html; charset=utf-8")

proc broadcastCoreHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    respondText(request, BroadcastCoreJs,
      "application/javascript; charset=utf-8")

proc chromeCommonHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    respondText(request, ChromeCommonJs,
      "application/javascript; charset=utf-8")

proc fontHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    respondText(request, BoardFontTtf, "font/ttf")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      ## A bad token is refused with a clean 401, never a hang.
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      logLine("ecos: seat " & $slot & " connected (" &
        $state.playerSockets.len & "/" & $state.config.tokens.len & ")")
      websocket.send($ %*{
        "type": "welcome",
        "protocol": PlayerProtocol,
        "slot": slot,
        "name": state.sim.names[slot],
        "role": RoleNames[state.sim.roleOf[slot]],
        "generations": state.config.generations,
        "ticksPerGeneration": state.config.ticksPerGeneration
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      state.viewers[websocket] = initGlobalViewerState()
      state.sendBoard(websocket, @[])

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
    message: Message) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering
      ## them itself, and hosted certification pings /global to check the
      ## game is alive — an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind == BinaryMessage:
        withLock stateLock:
          if websocket in state.viewers:
            var viewer = state.viewers[websocket]
            viewer.applyGlobalViewerMessage(message.data)
            state.viewers[websocket] = viewer
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "action":
          let generation = payload["generation"].getInt()
          var decision = parseDecision(state.sim.roleOf[slot], payload)
          case payload{"source"}.getStr()
          of "scripted": decision.source = dsScripted
          of "fallback": decision.source = dsFallback
          of "llm": decision.source = dsLlm
          else: raise newException(EcosError, "unknown action source")
          decision.latencyMs = payload{"latency_ms"}.getInt(0)
          withLock stateLock:
            if generation == state.pendingGeneration and
                not state.actionReceived[slot]:
              state.decisions[slot] = decision
              state.actionReceived[slot] = true
        else:
          logLine("ecos: ignoring frame of type " &
            payload{"type"}.getStr("?") & " from seat " & $slot)
      except CatchableError as error:
        logLine("ecos: ignoring bad player frame: " & error.msg)
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)
        state.viewers.del(websocket)

proc buildRouter(): Router =
  ## `/client/*` pages are registered BEFORE any asset route: the certifier
  ## probes them before the player pods start and a catch-all would 404 them.
  result.get("/healthz", healthzHandler)
  result.get("/client/global", globalPageHandler)
  result.get("/client/player", playerPageHandler)
  result.get("/client/broadcast_core.js", broadcastCoreHandler)
  result.get("/client/chrome_common.js", chromeCommonHandler)
  result.get("/client/font.ttf", fontHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/player", playerUpgradeHandler)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(EcosError, "tokens and players must align")
  ## Ecos is three-wide everywhere that matters — the species, the role
  ## rotation, `sim.roleOf`, and the seat vector the game loop decides over —
  ## while `numAgents` is a SEPARATE config field that can read 3 while the
  ## platform sends two tokens. Fail here, legibly, rather than on the game
  ## thread's first `actionReceived[2]`, where an IndexDefect kills the loop
  ## and the episode hangs to the platform timeout with no artifacts.
  if config.players.len != SeatAliases.len:
    raise newException(EcosError, "Ecos is a three-seat game; the platform " &
      "sent " & $config.players.len & " seats")
  state.config = config
  state.sim = newSim(config)
  state.decisions = newSeq[Decision](config.players.len)
  state.actionReceived = newSeq[bool](config.players.len)

  gameServer = newServer(buildRouter(), websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  logLine("ecos: serving on " & runtimeConfig.host & ":" &
    $runtimeConfig.port)
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
