## Ecos simulation core — the ten numbered tick rules, the generation clock,
## the integrated-biomass score and the terminal conditions.
##
## Forked from paintbot's `src/ctf/sim.nim`: same shape (a `SimServer` that
## owns all state, a `step` that advances exactly one tick, a running hash),
## with the CTF gameplay core replaced by the Ecos rules. Every read inside a
## numbered step uses the state as it stood at the start of that step, so
## ordering inside a species never matters.

import std/[json, strutils]
import sim_types, sim_config, sim_state, events

type
  Frame* = object
    ## One recorded tick: flat integer triples `x, y, energy` per living body
    ## of that species, in sim index order. No ids — identity is not needed to
    ## draw, and births/deaths carry their own positions in `events`.
    g*, h*, p*: seq[int]

  GenerationRow* = object
    pop*, bio*, births*, starved*: array[3, int]
    eaten*: int
    score*: array[3, float]

  SimServer* = ref object
    config*: GameConfig
    rng*: EcosRng
    tick*: int
    generation*: int              ## 1-based generation currently running
    generationsPlayed*: int
    bodies*: array[Species, seq[Body]]
    doctrine*: array[Species, Doctrine]
    roleOffset*: int
    roleOf*: array[3, Species]    ## slot -> species
    seatOf*: array[Species, int]  ## species -> slot
    names*: array[3, string]      ## in-game aliases, by slot
    policyNames*: seq[string]     ## spectator-side policy names, by slot
    notes*: array[3, string]
    says*: array[3, string]
    events*: seq[EcosEvent]
    frames*: seq[Frame]
    seriesPop*: seq[array[3, int]]
    seriesBio*: seq[array[3, int]]
    history*: seq[GenerationRow]
    genAccum*: array[Species, int]
    genBirths*, genStarved*: array[Species, int]
    genEaten*: int
    scores*: array[Species, float]
    births*, starved*: array[Species, int]
    predation*: int
    biomassSum*: array[Species, int]
    lastBiomass*: array[Species, int]
    alarmed*: array[Species, bool]
    done*: bool
    reason*: string
    ending*: string
    hash*: GameHash

# ---- setup -------------------------------------------------------------------

proc capOf*(sim: SimServer, species: Species): int = sim.config.capOf(species)

proc population*(sim: SimServer, species: Species): int =
  sim.bodies[species].len

proc biomass*(sim: SimServer, species: Species): int =
  for body in sim.bodies[species]:
    result += body.energy

proc assignRoles(sim: SimServer) =
  ## `role(slot) = (slot + roleOffset) mod 3`. Roles rotate across episodes,
  ## aliases do not: `Sedge` is always slot 0.
  for slot in 0 .. 2:
    let species = Species((slot + sim.roleOffset) mod 3)
    sim.roleOf[slot] = species
    sim.seatOf[species] = slot

proc placeOpening(sim: SimServer, species: Species, count, energy: int) =
  let
    lo = BorderMargin
    hiX = sim.config.fieldW - BorderMargin
    hiY = sim.config.fieldH - BorderMargin
  for _ in 0 ..< count:
    sim.bodies[species].add(Body(
      x: lo + sim.rng.rand(max(1, hiX - lo)),
      y: lo + sim.rng.rand(max(1, hiY - lo)),
      energy: energy,
      heading: sim.rng.randBrad()
    ))

proc recordFrame(sim: SimServer)
proc closeGeneration(sim: SimServer)

proc newSim*(config: GameConfig): SimServer =
  ## A fresh episode. The seed must already be final: every seed-derived draw
  ## (the opening placement and `roleOffset`) happens here.
  config.validate()
  result = SimServer(
    config: config,
    rng: initRng(config.seed),
    tick: 0,
    generation: 1,
    hash: initGameHash()
  )
  result.roleOffset =
    if config.roleOffset >= 0: config.roleOffset
    else: ((config.seed mod 3) + 3) mod 3
  result.assignRoles()
  for slot in 0 .. 2:
    result.names[slot] = SeatAliases[slot]
  result.policyNames = newSeq[string](3)
  for slot in 0 .. 2:
    result.policyNames[slot] =
      if slot < config.players.len and config.players[slot].name.len > 0:
        config.players[slot].name
      else:
        SeatAliases[slot]
  for species in Species:
    result.doctrine[species] = StewardDoctrine[species]
  result.placeOpening(spGrass, config.initGrass, 90)
  result.placeOpening(spGrazers, config.initGrazers, 100)
  result.placeOpening(spPredators, config.initPredators, 220)
  result.recordFrame()

# ---- doctrine ----------------------------------------------------------------

proc applyDoctrine*(
  sim: SimServer,
  species: Species,
  fields: Doctrine,
  source: DoctrineSource,
  clamped: bool,
  say, notes: string,
  latencyMs: int
) =
  ## Installs one seat's doctrine for the coming generation and records it.
  ## Out-of-range values are already clamped by the caller; `clamped` says so.
  sim.doctrine[species] = fields
  let slot = sim.seatOf[species]
  sim.says[slot] = say
  if notes.len > 0:
    sim.notes[slot] = notes
  sim.events.add(EcosEvent(
    tick: sim.tick,
    kind: ekDoctrine,
    species: species,
    seat: slot,
    gen: sim.generation,
    fields: fields,
    source: source,
    clamped: clamped,
    say: say,
    notes: notes,
    latencyMs: latencyMs
  ))

# ---- one tick ----------------------------------------------------------------

type
  GrazerSense = object
    crowd, stress, nearestPredator, nearestTuft, foodTuft: int
    fleeing, grazing: bool
    herdX, herdY, herdCount: int

proc grassStep(sim: SimServer) =
  ## Rule 1 — photosynthesis, shaded by neighbours.
  let tufts = addr sim.bodies[spGrass]
  let radius2 = ShadeRadius * ShadeRadius
  let gainBase = sim.config.grassGain
  var gains = newSeq[int](tufts[].len)
  for i in 0 ..< tufts[].len:
    var neighbours = 0
    for j in 0 ..< tufts[].len:
      if i == j: continue
      if dist2(tufts[][i].x, tufts[][i].y, tufts[][j].x, tufts[][j].y) <=
          radius2:
        inc neighbours
    gains[i] = clampInt(gainBase - neighbours, 0, gainBase)
  for i in 0 ..< tufts[].len:
    var body = addr tufts[][i]
    body.energy = min(GrassEMax, body.energy + gains[i] - GrassMetabolism)

proc senseGrazers(sim: SimServer): seq[GrazerSense] =
  ## Rule 2 — crowding, predator proximity and what is in reach to eat.
  let
    grazers = addr sim.bodies[spGrazers]
    predators = addr sim.bodies[spPredators]
    tufts = addr sim.bodies[spGrass]
    fleeRange = sim.doctrine[spGrazers][2]
    bite = sim.doctrine[spGrazers][1]
    crowd2 = CrowdRadius * CrowdRadius
    herd2 = HerdRadius * HerdRadius
    bite2 = BiteRadius * BiteRadius
  result = newSeq[GrazerSense](grazers[].len)
  for i in 0 ..< grazers[].len:
    let me = grazers[][i]
    var sense = GrazerSense(nearestPredator: high(int), nearestTuft: -1,
      foodTuft: -1)
    for j in 0 ..< grazers[].len:
      if i == j: continue
      let d2 = dist2(me.x, me.y, grazers[][j].x, grazers[][j].y)
      if d2 <= crowd2:
        inc sense.crowd
      if d2 <= herd2:
        sense.herdX += grazers[][j].x
        sense.herdY += grazers[][j].y
        inc sense.herdCount
    sense.stress = min(2, sense.crowd div 6)
    for j in 0 ..< predators[].len:
      let d = dist(me.x, me.y, predators[][j].x, predators[][j].y)
      if d < sense.nearestPredator:
        sense.nearestPredator = d
    var bestAny = high(int)
    var bestFood = high(int)
    for j in 0 ..< tufts[].len:
      let d2 = dist2(me.x, me.y, tufts[][j].x, tufts[][j].y)
      if d2 < bestAny:
        bestAny = d2
        sense.nearestTuft = j
      if tufts[][j].energy >= 4 * bite and d2 < bestFood:
        bestFood = d2
        sense.foodTuft = j
    sense.fleeing = sense.nearestPredator < fleeRange
    sense.grazing = (not sense.fleeing) and sense.nearestTuft >= 0 and
      bestAny <= bite2
    result[i] = sense

proc grazeStep(sim: SimServer, sense: seq[GrazerSense]) =
  ## Rule 3 — grazing, in index order. Emits no event.
  let bite = sim.doctrine[spGrazers][1]
  for i in 0 ..< sim.bodies[spGrazers].len:
    if not sense[i].grazing: continue
    let tuftIndex = sense[i].nearestTuft
    if tuftIndex < 0 or tuftIndex >= sim.bodies[spGrass].len: continue
    var tuft = addr sim.bodies[spGrass][tuftIndex]
    let taken = min(bite, max(0, tuft.energy))
    if taken <= 0: continue
    tuft.energy -= taken
    var grazer = addr sim.bodies[spGrazers][i]
    grazer.energy = min(GrazerEMax,
      grazer.energy + (taken * ConversionPercentNum) div ConversionPercentDen)

proc moveGrazers(sim: SimServer, sense: seq[GrazerSense]) =
  ## Rule 4 — movement and metabolism.
  let
    herdWeight = sim.doctrine[spGrazers][3]
    predators = sim.bodies[spPredators]
  for i in 0 ..< sim.bodies[spGrazers].len:
    let s = sense[i]
    var body = addr sim.bodies[spGrazers][i]
    inc body.age
    if s.grazing:
      body.energy -= GrazerMetabolism + s.stress
      continue
    if s.fleeing:
      var nearest = -1
      var best = high(int)
      for j in 0 ..< predators.len:
        let d2 = dist2(body.x, body.y, predators[j].x, predators[j].y)
        if d2 < best:
          best = d2
          nearest = j
      if nearest >= 0:
        let away = unitVec(body.x - predators[nearest].x,
          body.y - predators[nearest].y)
        let speed =
          if s.crowd >= ManyEyesCrowd: GrazerManyEyesSpeed else: GrazerFleeSpeed
        let moved = stepBy(body.x, body.y, away.x, away.y, speed)
        body.x = moved.x
        body.y = moved.y
        if away.x != 0 or away.y != 0:
          body.heading = bradOf(away.x, away.y)
      body.energy -= GrazerFleeMetabolism + s.stress
      continue
    var target = s.foodTuft
    if target < 0: target = s.nearestTuft
    var dir: tuple[x, y: int]
    if target >= 0 and target < sim.bodies[spGrass].len:
      let food = unitVec(sim.bodies[spGrass][target].x - body.x,
        sim.bodies[spGrass][target].y - body.y)
      if s.herdCount > 0 and herdWeight > 0:
        let toHerd = unitVec(s.herdX div s.herdCount - body.x,
          s.herdY div s.herdCount - body.y)
        dir = blendVec(food.x, food.y, 100 - herdWeight,
          toHerd.x, toHerd.y, herdWeight)
      else:
        dir = food
    else:
      body.heading = sim.rng.randBrad()
      dir = bradVec(body.heading)
    if dir.x == 0 and dir.y == 0:
      dir = bradVec(body.heading)
    else:
      body.heading = bradOf(dir.x, dir.y)
    let moved = stepBy(body.x, body.y, dir.x, dir.y, GrazerSpeed)
    body.x = moved.x
    body.y = moved.y
    body.energy -= GrazerMetabolism + s.stress

proc predatorStep(sim: SimServer, eaten: var seq[bool]) =
  ## Rules 5 and 6 — sense, then idle / kill / chase / roam.
  let
    predators = addr sim.bodies[spPredators]
    grazers = addr sim.bodies[spGrazers]
    restEnergy = sim.doctrine[spPredators][2]
    huntRange = sim.doctrine[spPredators][1]
    spread = sim.doctrine[spPredators][3]
    crowd2 = CrowdRadius * CrowdRadius
    hunt2 = huntRange * huntRange
    kill2 = KillRadius * KillRadius
    spread2 = SpreadRadius * SpreadRadius
  # Rule 5: sense on the state as it stood at the start of the step.
  var stress = newSeq[int](predators[].len)
  for i in 0 ..< predators[].len:
    var pcrowd = 0
    for j in 0 ..< predators[].len:
      if i == j: continue
      if dist2(predators[][i].x, predators[][i].y,
          predators[][j].x, predators[][j].y) <= crowd2:
        inc pcrowd
    stress[i] = min(2, pcrowd div 2)
  let senseSnapshot = predators[]
  for i in 0 ..< predators[].len:
    var body = addr predators[][i]
    inc body.age
    body.cooldown = max(body.cooldown - 1, 0)
    if body.energy >= restEnergy:
      body.energy -= PredatorIdle + stress[i]
      continue
    var target = -1
    var best = high(int)
    for j in 0 ..< grazers[].len:
      if eaten[j]: continue
      let d2 = dist2(body.x, body.y, grazers[][j].x, grazers[][j].y)
      if d2 <= hunt2 and d2 < best:
        best = d2
        target = j
    if target < 0:
      if sim.tick mod PredatorRoamPeriod == 0:
        body.heading = sim.rng.randBrad()
      let dir = bradVec(body.heading)
      let moved = stepBy(body.x, body.y, dir.x, dir.y, PredatorSpeed)
      body.x = moved.x
      body.y = moved.y
      body.energy -= PredatorRoam + stress[i]
      continue
    if best <= kill2 and body.cooldown == 0:
      let prey = grazers[][target]
      let gain = min(KillCap, KillBase + prey.energy)
      body.energy = min(PredatorEMax, body.energy + gain)
      eaten[target] = true
      body.cooldown = HuntCooldown
      sim.events.add(EcosEvent(
        tick: sim.tick + 1,
        kind: ekPredation,
        species: spGrazers,
        x: prey.x, y: prey.y, energy: prey.energy,
        px: body.x, py: body.y
      ))
      continue
    let toTarget = unitVec(grazers[][target].x - body.x,
      grazers[][target].y - body.y)
    var dir = toTarget
    if spread > 0:
      var nearest = -1
      var nearestD2 = high(int)
      for j in 0 ..< senseSnapshot.len:
        if i == j: continue
        let d2 = dist2(body.x, body.y, senseSnapshot[j].x, senseSnapshot[j].y)
        if d2 < nearestD2:
          nearestD2 = d2
          nearest = j
      if nearest >= 0 and nearestD2 <= spread2:
        let away = unitVec(body.x - senseSnapshot[nearest].x,
          body.y - senseSnapshot[nearest].y)
        dir = blendVec(toTarget.x, toTarget.y, 100 - spread,
          away.x, away.y, spread)
    if dir.x != 0 or dir.y != 0:
      body.heading = bradOf(dir.x, dir.y)
    let moved = stepBy(body.x, body.y, dir.x, dir.y, PredatorChaseSpeed)
    body.x = moved.x
    body.y = moved.y
    body.energy -= PredatorChase + stress[i]

proc clampPositions(sim: SimServer) =
  ## Rule 7 — no walls, but no escape either.
  for species in Species:
    for body in sim.bodies[species].mitems:
      body.x = clampInt(body.x, 0, sim.config.fieldW)
      body.y = clampInt(body.y, 0, sim.config.fieldH)

proc deaths(sim: SimServer, eaten: seq[bool]) =
  ## Rule 8 — predation first, then starvation. Dead bodies are removed
  ## before any birth is considered.
  for species in Species:
    var survivors: seq[Body]
    for i in 0 ..< sim.bodies[species].len:
      let body = sim.bodies[species][i]
      if species == spGrazers and i < eaten.len and eaten[i]:
        inc sim.predation
        inc sim.genEaten
        continue
      if body.energy <= 0:
        inc sim.starved[species]
        inc sim.genStarved[species]
        sim.events.add(EcosEvent(
          tick: sim.tick + 1,
          kind: ekStarve,
          species: species,
          x: body.x, y: body.y, age: body.age
        ))
        continue
      survivors.add(body)
    sim.bodies[species] = survivors

proc bornBody(sim: SimServer, species: Species, x, y, energy, px, py: int) =
  sim.bodies[species].add(Body(
    x: clampInt(x, 0, sim.config.fieldW),
    y: clampInt(y, 0, sim.config.fieldH),
    energy: energy,
    heading: sim.rng.randBrad()
  ))
  inc sim.births[species]
  inc sim.genBirths[species]
  sim.events.add(EcosEvent(
    tick: sim.tick + 1,
    kind: ekBirth,
    species: species,
    x: clampInt(x, 0, sim.config.fieldW),
    y: clampInt(y, 0, sim.config.fieldH),
    energy: energy,
    px: px, py: py
  ))

proc grassBirths(sim: SimServer) =
  let
    d = sim.doctrine[spGrass]
    threshold = d[0]
    seedRange = d[1]
    seedCost = d[2]
    crowdLimit = d[3]
    cap = sim.capOf(spGrass)
    shade2 = ShadeRadius * ShadeRadius
    parents = sim.bodies[spGrass].len
  for i in 0 ..< parents:
    if sim.bodies[spGrass].len >= cap: break
    if sim.bodies[spGrass][i].energy < threshold: continue
    let brad = sim.rng.randBrad()
    let dir = bradVec(brad)
    let tx = clampInt(sim.bodies[spGrass][i].x +
      (dir.x * seedRange) div UnitScale, 0, sim.config.fieldW)
    let ty = clampInt(sim.bodies[spGrass][i].y +
      (dir.y * seedRange) div UnitScale, 0, sim.config.fieldH)
    if crowdLimit > 0:
      var near = 0
      for j in 0 ..< sim.bodies[spGrass].len:
        if dist2(tx, ty, sim.bodies[spGrass][j].x,
            sim.bodies[spGrass][j].y) <= shade2:
          inc near
          if near >= crowdLimit: break
      if near >= crowdLimit:
        sim.bodies[spGrass][i].energy -= SeedLoss
        continue
    let px = sim.bodies[spGrass][i].x
    let py = sim.bodies[spGrass][i].y
    sim.bodies[spGrass][i].energy -= seedCost + SeedLoss
    sim.bornBody(spGrass, tx, ty, seedCost, px, py)

proc splitBirths(sim: SimServer, species: Species) =
  let
    threshold = sim.doctrine[species][0]
    cap = sim.capOf(species)
    parents = sim.bodies[species].len
  for i in 0 ..< parents:
    if sim.bodies[species].len >= cap: break
    if sim.bodies[species][i].energy < threshold: continue
    let half = (sim.bodies[species][i].energy - SplitOverhead) div 2
    if half <= 0: continue
    let brad = sim.rng.randBrad()
    let dir = bradVec(brad)
    let px = sim.bodies[species][i].x
    let py = sim.bodies[species][i].y
    sim.bodies[species][i].energy = half
    sim.bornBody(species,
      px + (dir.x * ChildOffset) div UnitScale,
      py + (dir.y * ChildOffset) div UnitScale,
      half, px, py)

proc checkAlarms(sim: SimServer) =
  ## The `alarm` event drives the viewer's silent-spring desaturation. Fires
  ## once per species per crossing, in both directions. Called AFTER the tick
  ## counter advances, so the tick it stamps is `sim.tick` — the frame whose
  ## population crossed — and `events[]` stays sorted by `t`.
  for species in Species:
    let cap = sim.capOf(species)
    let pop = sim.population(species)
    if not sim.alarmed[species] and pop * 100 < AlarmFraction * cap:
      sim.alarmed[species] = true
      sim.events.add(EcosEvent(
        tick: sim.tick, kind: ekAlarm, species: species,
        population: pop, cap: cap))
    elif sim.alarmed[species] and pop * 100 >= RecoverFraction * cap:
      sim.alarmed[species] = false

proc recordFrame(sim: SimServer) =
  var frame: Frame
  for species in Species:
    for body in sim.bodies[species]:
      case species
      of spGrass:
        frame.g.add(body.x); frame.g.add(body.y); frame.g.add(body.energy)
      of spGrazers:
        frame.h.add(body.x); frame.h.add(body.y); frame.h.add(body.energy)
      of spPredators:
        frame.p.add(body.x); frame.p.add(body.y); frame.p.add(body.energy)
    sim.hash.mix(sim.population(species))
    for body in sim.bodies[species]:
      sim.hash.mixBody(body)
  sim.frames.add(frame)
  var pop: array[3, int]
  var bio: array[3, int]
  for species in Species:
    pop[ord(species)] = sim.population(species)
    bio[ord(species)] = sim.biomass(species)
    ## A generation is the `ticksPerGeneration` ticks it played, and
    ## `results.biomass` is the mean over the ticks actually played: frame 0
    ## is the opening state, not a tick, so it is recorded and drawn but
    ## never scored or averaged. The viewer re-derives the same window from
    ## `series.bio` (`replays.nim`'s `precompute`), so the two agree exactly.
    if sim.tick > 0:
      sim.genAccum[species] += bio[ord(species)]
      sim.biomassSum[species] += bio[ord(species)]
    sim.lastBiomass[species] = bio[ord(species)]
  sim.seriesPop.add(pop)
  sim.seriesBio.add(bio)

proc generationScore*(sim: SimServer, species: Species): float =
  ## `G_i(g) = (sum of B_i(t) over the generation) / (ticksPerGeneration * R_i)`
  let denom = float(sim.config.ticksPerGeneration *
    ReferenceBiomass[species])
  if denom <= 0.0: 0.0
  else: float(sim.genAccum[species]) / denom

proc scoreVector*(sim: SimServer): array[3, float] =
  ## Scores by SLOT (the results arrays are slot-indexed).
  for slot in 0 .. 2:
    result[slot] = sim.scores[sim.roleOf[slot]]

proc closeGeneration(sim: SimServer) =
  var row: GenerationRow
  var genScore: array[3, float]
  for species in Species:
    let capped = min(sim.generationScore(species), GenerationScoreCap)
    sim.scores[species] += capped
    row.pop[ord(species)] = sim.population(species)
    row.bio[ord(species)] = sim.lastBiomass[species]
    row.births[ord(species)] = sim.genBirths[species]
    row.starved[ord(species)] = sim.genStarved[species]
    row.score[ord(species)] = capped
    genScore[ord(species)] = capped
    sim.genAccum[species] = 0
    sim.genBirths[species] = 0
    sim.genStarved[species] = 0
  row.eaten = sim.genEaten
  sim.genEaten = 0
  sim.history.add(row)
  inc sim.generationsPlayed
  sim.events.add(EcosEvent(
    tick: sim.tick,
    kind: ekGeneration,
    gen: sim.generation,
    pop: row.pop,
    bio: row.bio,
    score: genScore
  ))

proc finish(sim: SimServer, reason, ending: string) =
  if sim.done: return
  sim.done = true
  sim.reason = reason
  sim.ending = ending
  let scores = sim.scoreVector()
  sim.events.add(EcosEvent(
    tick: sim.tick, kind: ekEnd, reason: reason, ending: ending,
    score: scores))

proc endEarly*(sim: SimServer) =
  ## The play deadline fired between generations: score what was played and
  ## settle. Unplayed generations contribute 0.
  sim.finish("deadline", "deadline")

proc forfeit*(sim: SimServer) =
  ## No seat connected. All zero, but results and the replay are still
  ## written.
  for species in Species:
    sim.scores[species] = 0.0
  sim.finish("forfeit", "forfeit")

proc atGenerationBoundary*(sim: SimServer): bool =
  sim.tick > 0 and sim.tick mod sim.config.ticksPerGeneration == 0

proc step*(sim: SimServer) =
  ## Exactly one tick, rules 1..10 in order.
  if sim.done: return
  var eaten = newSeq[bool](sim.bodies[spGrazers].len)
  sim.grassStep()                       # 1
  let sense = sim.senseGrazers()        # 2
  sim.grazeStep(sense)                  # 3
  sim.moveGrazers(sense)                # 4
  sim.predatorStep(eaten)               # 5, 6
  sim.clampPositions()                  # 7
  sim.deaths(eaten)                     # 8
  sim.grassBirths()                     # 9
  sim.splitBirths(spGrazers)
  sim.splitBirths(spPredators)
  inc sim.tick
  sim.checkAlarms()
  sim.recordFrame()                     # 10

  var collapsed = false
  for species in Species:
    if sim.population(species) == 0:
      sim.events.add(EcosEvent(tick: sim.tick, kind: ekCollapse,
        species: species))
      collapsed = true
  if sim.atGenerationBoundary():
    sim.closeGeneration()
    if not collapsed and sim.generationsPlayed < sim.config.generations:
      inc sim.generation
  if collapsed:
    if not sim.atGenerationBoundary():
      sim.closeGeneration()
    var which = spGrass
    for species in Species:
      if sim.population(species) == 0:
        which = species
        break
    sim.finish("complete", "collapse_" & RoleNames[which])
  elif sim.generationsPlayed >= sim.config.generations:
    sim.finish("complete", "ten_generations")

proc runGeneration*(sim: SimServer) =
  ## Advance to the next generation boundary (or to the end of the episode).
  let target = sim.generationsPlayed + 1
  while not sim.done and sim.generationsPlayed < target:
    sim.step()

# ---- observations and results ------------------------------------------------

proc meanEnergy*(sim: SimServer, species: Species): int =
  let pop = sim.population(species)
  if pop == 0: 0 else: sim.biomass(species) div pop

proc meanCrowd*(sim: SimServer, species: Species): int =
  let bodies = sim.bodies[species]
  if bodies.len == 0: return 0
  let radius2 = CrowdRadius * CrowdRadius
  var total = 0
  for i in 0 ..< bodies.len:
    for j in 0 ..< bodies.len:
      if i == j: continue
      if dist2(bodies[i].x, bodies[i].y, bodies[j].x, bodies[j].y) <= radius2:
        inc total
  total div bodies.len

const DensityCols* = 10
const DensityRows* = 6

proc densityGrid*(sim: SimServer, species: Species): seq[int] =
  result = newSeq[int](DensityCols * DensityRows)
  for body in sim.bodies[species]:
    let col = clampInt(body.x * DensityCols div max(1, sim.config.fieldW),
      0, DensityCols - 1)
    let row = clampInt(body.y * DensityRows div max(1, sim.config.fieldH),
      0, DensityRows - 1)
    inc result[row * DensityCols + col]

proc historyJson*(sim: SimServer): JsonNode =
  result = newJArray()
  for index, row in sim.history:
    result.add(%*{
      "g": index + 1,
      "pop": [row.pop[0], row.pop[1], row.pop[2]],
      "bio": [row.bio[0], row.bio[1], row.bio[2]],
      "births": [row.births[0], row.births[1], row.births[2]],
      "starved": [row.starved[0], row.starved[1], row.starved[2]],
      "eaten": row.eaten,
      "score": [row.score[0], row.score[1], row.score[2]]
    })

proc speciesSummaryJson(sim: SimServer): JsonNode =
  result = newJArray()
  for species in Species:
    result.add(%*{
      "role": RoleNames[species],
      "alias": sim.names[sim.seatOf[species]],
      "population": sim.population(species),
      "biomass": sim.biomass(species),
      "reference": ReferenceBiomass[species],
      "cap": sim.capOf(species)
    })

proc rulesJson(sim: SimServer, species: Species): JsonNode =
  ## The seat's OWN constants — the numbers its kernel runs on. A grass seat
  ## has no bite radius and a predator has no flee speed; sending the grazer's
  ## table to all three told two of them numbers that do not apply to them.
  case species
  of spGrass:
    %*{
      "metabolism": GrassMetabolism,
      "gain": sim.config.grassGain,
      "shadeRadius": ShadeRadius,
      "seedLoss": SeedLoss,
      "energyMax": GrassEMax
    }
  of spGrazers:
    %*{
      "metabolism": GrazerMetabolism,
      "fleeMetabolism": GrazerFleeMetabolism,
      "speed": GrazerSpeed,
      "fleeSpeed": GrazerFleeSpeed,
      "manyEyesSpeed": GrazerManyEyesSpeed,
      "biteRadius": BiteRadius,
      "conversionPercent": ConversionPercentNum * 100 div ConversionPercentDen,
      "crowdRadius": CrowdRadius,
      "splitOverhead": SplitOverhead,
      "energyMax": GrazerEMax
    }
  of spPredators:
    %*{
      "idleMetabolism": PredatorIdle,
      "chaseMetabolism": PredatorChase,
      "roamMetabolism": PredatorRoam,
      "chaseSpeed": PredatorChaseSpeed,
      "roamSpeed": PredatorSpeed,
      "killRadius": KillRadius,
      "killBase": KillBase,
      "killCap": KillCap,
      "huntCooldown": HuntCooldown,
      "crowdRadius": CrowdRadius,
      "splitOverhead": SplitOverhead,
      "energyMax": PredatorEMax
    }

proc observationJson*(sim: SimServer, slot: int): JsonNode =
  ## The `state` frame a seat sees at every generation boundary. Every number
  ## here is visible to the seat; nothing else is. In particular: no other
  ## seat's doctrine, notes or say text, no seed, no body positions.
  let species = sim.roleOf[slot]
  var density = newJObject()
  density["cols"] = %DensityCols
  density["rows"] = %DensityRows
  for other in Species:
    var cells = newJArray()
    for value in sim.densityGrid(other):
      cells.add(%value)
    density[RoleNames[other]] = cells
  %*{
    "type": "state",
    "protocol": PlayerProtocol,
    "slot": slot,
    "name": sim.names[slot],
    "role": RoleNames[species],
    "generation": sim.generation,
    "generations": sim.config.generations,
    "ticksPerGeneration": sim.config.ticksPerGeneration,
    "tick": sim.tick,
    "field": {"w": sim.config.fieldW, "h": sim.config.fieldH},
    "you": {
      "population": sim.population(species),
      "biomass": sim.biomass(species),
      "reference": ReferenceBiomass[species],
      "scoreSoFar": sim.scores[species],
      "doctrine": doctrineJson(species, sim.doctrine[species]),
      "meanEnergy": sim.meanEnergy(species),
      "meanCrowd": sim.meanCrowd(species),
      "cap": sim.capOf(species)
    },
    "species": sim.speciesSummaryJson(),
    "history": sim.historyJson(),
    "density": density,
    "notes": sim.notes[slot],
    "rules": sim.rulesJson(species)
  }

proc meanBiomass*(sim: SimServer, species: Species): int =
  let ticks = max(1, sim.tick)
  sim.biomassSum[species] div ticks

proc resultsJson*(sim: SimServer): JsonNode =
  ## Arrays are indexed by SLOT, always length 3. `names` are POLICY names
  ## (platform side); the aliases go to the players and into the replay.
  var
    names = newJArray()
    scores = newJArray()
    win = newJArray()
    roles = newJArray()
    biomass = newJArray()
    population = newJArray()
    births = newJArray()
    starved = newJArray()
  let vector = sim.scoreVector()
  var best = vector[0]
  for slot in 0 .. 2:
    if vector[slot] > best: best = vector[slot]
  for slot in 0 .. 2:
    let species = sim.roleOf[slot]
    names.add(%sim.policyNames[slot])
    scores.add(%vector[slot])
    win.add(%(vector[slot] == best))
    roles.add(%RoleNames[species])
    biomass.add(%sim.meanBiomass(species))
    population.add(%sim.population(species))
    births.add(%sim.births[species])
    starved.add(%sim.starved[species])
  %*{
    "names": names,
    "scores": scores,
    "win": win,
    "roles": roles,
    "biomass": biomass,
    "population": population,
    "generations": sim.generationsPlayed,
    "births": births,
    "starved": starved,
    "predation": sim.predation,
    "reason": (if sim.reason.len > 0: sim.reason else: "complete"),
    "ending": (if sim.ending.len > 0: sim.ending else: "ten_generations")
  }

proc gameHash*(sim: SimServer): string = sim.hash.hex()

proc roleName*(sim: SimServer, slot: int): string =
  RoleNames[sim.roleOf[slot]]

proc summaryLine*(sim: SimServer): string =
  var parts: seq[string]
  for species in Species:
    parts.add(RoleNames[species] & " " & $sim.population(species) & "/" &
      $sim.capOf(species) & " B" & $sim.biomass(species))
  "gen " & $sim.generation & " tick " & $sim.tick & ": " & parts.join("  ")
