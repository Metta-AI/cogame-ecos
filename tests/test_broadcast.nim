## tests/test_broadcast.nim — the chrome frame.
##
## The broadcast chrome is a JSON object smuggled as the label of sprite 4090
## and read by `client/chrome_common.js`. Its shape is a contract with that
## file: `teams` keyed by the ROLE's colour, a `lead` series of
## `[tick, green, yellow, red]` rows, `over` on the terminal frame.

import std/[json, sets, strutils]
import helpers
import bitworld/spriteprotocol
import ../src/ecos/[broadcast, global]

proc chromeOf(sim: SimServer, withLead: bool): JsonNode =
  var input = ChromeInput(
    tick: sim.tick,
    maxTick: sim.config.generations * sim.config.ticksPerGeneration,
    generation: sim.generation,
    generations: sim.config.generations,
    ticksPerGeneration: sim.config.ticksPerGeneration,
    playing: true,
    speed: 1.0,
    transportEnabled: true,
    over: sim.done,
    reason: sim.reason,
    ending: sim.ending,
    fieldW: sim.config.fieldW,
    fieldH: sim.config.fieldH,
    events: newJArray()
  )
  for species in Species:
    let index = ord(species)
    input.pop[index] = sim.population(species)
    input.bio[index] = sim.biomass(species)
    input.cap[index] = sim.capOf(species)
    input.scores[index] = sim.scores[species]
    input.alarmed[index] = sim.alarmed[species]
  for slot in 0 .. 2:
    input.aliases[slot] = sim.names[slot]
    input.policyNames[slot] = sim.policyNames[slot]
    input.roleOfSlot[slot] = ord(sim.roleOf[slot])
  for event in sim.events:
    if event.tick == sim.tick:
      input.events.add(eventToJson(event))
  if withLead:
    var pts = newJArray()
    for index, row in sim.seriesPop:
      var point = newJArray()
      point.add(%index)
      for species in Species:
        point.add(%(row[ord(species)] * 1000 div sim.capOf(species)))
      pts.add(point)
    input.leadPts = pts
  parseJson(buildStateJson(input))

when isMainModule:
  # ---- teams are keyed by the ROLE, under every rotation --------------------
  for offset in 0 .. 2:
    var config = standardConfig(6)
    config.roleOffset = offset
    let sim = newSim(config)
    let state = chromeOf(sim, false)
    var keys: HashSet[string]
    for key, _ in state{"teams"}.pairs:
      keys.incl(key)
    doAssert keys == ["green", "yellow", "red"].toHashSet(),
      "chrome team keys are " & $keys
    doAssert state{"teams"}{"green"}{"role"}.getStr() == "grass",
      "green is always grass, whatever the rotation"
    doAssert state{"teams"}{"yellow"}{"role"}.getStr() == "grazers"
    doAssert state{"teams"}{"red"}{"role"}.getStr() == "predators"
    # Plate numbers ARE the populations, and the headline is the POLICY name
    # of the seat that happens to hold that role this episode.
    for species in Species:
      let team = state{"teams"}{RoleTeamKey[species]}
      doAssert team{"pop"}.getInt() == sim.population(species),
        "plate number for " & RoleNames[species]
      doAssert team{"cap"}.getInt() == sim.capOf(species)
      let slot = sim.seatOf[species]
      doAssert team{"policies"}[0].getStr() == sim.policyNames[slot]
      doAssert team{"alias"}.getStr() == sim.names[slot]
      doAssert team{"slot"}.getInt() == slot
    # The roster carries the same mapping, for the feed.
    doAssert state{"roster"}.len == 3
    for row in state{"roster"}:
      let slot = row{"s"}.getInt()
      doAssert row{"team"}.getStr() == RoleTeamKey[sim.roleOf[slot]]
    doAssert state{"pov"}.getInt() == -1, "Ecos has no POV lens"
    doAssert state{"bs"}.getInt() == boardRenderScaleFor(config.fieldW,
      config.fieldH)

  # ---- the population strip: [tick, green, yellow, red] rows ---------------
  block:
    let sim = stewardEpisode(standardConfig(7))
    let state = chromeOf(sim, true)
    doAssert state.hasKey("lead")
    var teams: seq[string]
    for name in state{"lead"}{"teams"}:
      teams.add(name.getStr())
    doAssert teams == @["green", "yellow", "red"],
      "lead.teams must match the vals order chrome_common expects"
    let pts = state{"lead"}{"pts"}
    doAssert pts.len == sim.frames.len
    for row in pts:
      doAssert row.len == 4,
        "a lead row is [tick, g, h, p]; saw " & $row.len & " values"
      for index in 1 .. 3:
        doAssert row[index].getInt() >= 0 and row[index].getInt() <= 1000,
          "the strip is normalised by each species' own cap (permille)"
    doAssert pts[0][0].getInt() == 0
    doAssert pts[pts.len - 1][0].getInt() == sim.frames.len - 1

    # ---- `over` is present on the terminal frame, with the ending ----------
    doAssert sim.done
    doAssert state{"ph"}.getStr() == "gameover"
    doAssert state.hasKey("over")
    doAssert state{"over"}{"ending"}.getStr() == sim.ending
    doAssert state{"over"}{"reason"}.getStr() == sim.reason
    doAssert state{"over"}{"winner"}.getStr() in ["green", "yellow", "red"]
    for species in Species:
      doAssert state{"over"}{"teams"}{RoleTeamKey[species]}{"score"}
        .getFloat() == sim.scores[species]

  # ---- feed rows: doctrine, alarm and collapse are well formed -------------
  block:
    let sim = newSim(standardConfig(8))
    sim.applyDoctrine(spPredators, [300, 180, 260, 40], dsLlm, false,
      "thin the herd", "predators at 11 and rising", 830)
    let state = chromeOf(sim, false)
    var sawDoctrine = false
    for event in state{"events"}:
      if event{"k"}.getStr() != "doctrine": continue
      sawDoctrine = true
      doAssert event{"sp"}.getStr() == "predators"
      doAssert event{"seat"}.getInt() == sim.seatOf[spPredators]
      doAssert event{"source"}.getStr() == "llm"
      doAssert event{"say"}.getStr().len <= MaxSayLen * 4
      doAssert event{"notes"}.getStr().len <= MaxNotesLen * 4
      let fields = event{"fields"}
      for name in DoctrineFieldNames[spPredators]:
        doAssert fields.hasKey(name),
          "the feed row needs " & name & " to letter itself"
      doAssert fields{"hunt_range"}.getInt() == 180
    doAssert sawDoctrine

  # ---- alarm and collapse rows survive a real crash ------------------------
  block:
    # A greedy predator wrecks the field; the replay must still describe it.
    let picker = fixedPicker([StewardDoctrine[spGrass],
      StewardDoctrine[spGrazers], [200, 400, 480, 40]])
    var crashed: SimServer = nil
    for seed in 1 .. 6:
      let sim = runEpisode(standardConfig(seed), picker)
      if sim.ending.startsWith("collapse_"):
        crashed = sim
        break
    doAssert crashed != nil, "a greedy predator must be able to crash a field"
    var sawAlarm = false
    var sawCollapse = false
    var lastTick = 0
    for event in crashed.events:
      # Every recorded row belongs to the frame it stamps, and `events[]` is
      # sorted by `t` — the replay cursor and the live event walk both assume
      # it, and an alarm stamped a tick late pushes the collapse row and the
      # banner into the next tick's slice.
      doAssert event.tick >= lastTick,
        "events must be non-decreasing in t; " & $event.kind & " at " &
        $event.tick & " follows " & $lastTick
      lastTick = event.tick
      case event.kind
      of ekAlarm:
        sawAlarm = true
        let node = eventToJson(event)
        doAssert node{"pop"}.getInt() * 100 <
          AlarmFraction * node{"cap"}.getInt()
        doAssert node{"sp"}.getStr() in ["grass", "grazers", "predators"]
        doAssert event.population ==
          crashed.seriesPop[event.tick][ord(event.species)],
          "the alarm at tick " & $event.tick & " reports " &
          $event.population & " where that frame recorded " &
          $crashed.seriesPop[event.tick][ord(event.species)]
      of ekCollapse:
        sawCollapse = true
        doAssert eventToJson(event){"sp"}.getStr().len > 0
      else: discard
    doAssert sawAlarm, "a crash must raise an alarm for the desaturation"
    doAssert sawCollapse
    let state = chromeOf(crashed, false)
    doAssert state{"over"}{"ending"}.getStr().startsWith("collapse_")

  # ---- the wire constants the chrome reads ---------------------------------
  doAssert "window.CTF_WIRE={" in WireConstantsJs
  doAssert "speeds:[0.5,1,2,3,4,8,16]" in WireConstantsJs,
    "the wire speeds must lead with the replay-only 0.5x"
  doAssert "chromeSpriteId:" & $BroadcastChromeSpriteId in WireConstantsJs
  doAssert "fps:24" in WireConstantsJs

  # ---- a real board packet carries the chrome as sprite 4090's label -------
  block:
    let sim = newSim(standardConfig(2))
    var viewer = initGlobalViewerState()
    let chrome = buildStateJson(ChromeInput(
      tick: 0, maxTick: 600, generations: 10, ticksPerGeneration: 60,
      fieldW: sim.config.fieldW, fieldH: sim.config.fieldH))
    var frame: BoardFrame
    frame.fieldW = sim.config.fieldW
    frame.fieldH = sim.config.fieldH
    for species in Species:
      for body in sim.bodies[species]:
        frame.bodies[ord(species)].add(
          BoardBody(x: body.x, y: body.y, energy: body.energy))
    let packet = buildBoardPacket(viewer, frame, @[], 0, chrome)
    doAssert packet.len > 0
    var sawChrome = false
    var objects = 0
    for message in packet.parseSpritePacket():
      case message.kind
      of spkSprite:
        if message.sprite.id == BroadcastChromeSpriteId:
          sawChrome = true
          doAssert message.sprite.width == 1 and message.sprite.height == 1
          doAssert parseJson(message.sprite.label){"teams"}.len == 3
      of spkObject: inc objects
      of spkViewport:
        doAssert message.viewport.width == sim.config.fieldW
        doAssert message.viewport.height == sim.config.fieldH
      else: discard
    doAssert sawChrome, "the chrome must ride as sprite 4090's label"
    doAssert objects >= sim.population(spGrass), "bodies must be drawn"
    # The transport command channel the chrome drives.
    viewer.applyGlobalViewerMessage(blobFromSpriteChat("s:120"))
    doAssert viewer.replaySeekTick == 120
    viewer.applyGlobalViewerMessage(blobFromSpriteChat(" "))
    doAssert not viewer.playing
    viewer.applyGlobalViewerMessage(blobFromSpriteChat("4"))
    doAssert viewer.speed == 4

  echo "test_broadcast: ok"
