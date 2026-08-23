## tests/test_sim.nim — the sim units and determinism.
##
## Every number checked here is one the design note pins: change a constant
## and this test is where it shows up.

import std/[json, strutils, tables]
import helpers
import ../src/ecos/sim_state

proc singleSpecies(species: Species, bodies: seq[Body],
    doctrine: Doctrine): SimServer =
  ## A hand-built board with exactly the bodies a rule needs, so a rule can
  ## be read in isolation.
  var config = standardConfig(1)
  config.initGrass = 1
  config.initGrazers = 1
  config.initPredators = 1
  result = newSim(config)
  for other in Species:
    result.bodies[other] = @[]
  result.bodies[species] = bodies
  result.doctrine[species] = clampDoctrine(species, doctrine).fields

when isMainModule:
  # ---- integer geometry -----------------------------------------------------
  doAssert isqrt(0) == 0
  doAssert isqrt(1) == 1
  doAssert isqrt(15) == 3
  doAssert isqrt(16) == 4
  doAssert dist(0, 0, 3, 4) == 5
  block:
    let u = unitVec(300, 0)
    doAssert u == (UnitScale, 0)
  for brad in 0 ..< 256:
    let v = bradVec(brad)
    let length = isqrt(v.x * v.x + v.y * v.y)
    doAssert length >= UnitScale - 8 and length <= UnitScale + 8,
      "brad " & $brad & " length " & $length
    let delta = ((bradOf(v.x, v.y) - brad + 384) mod 256) - 128
    doAssert abs(delta) <= 1,
      "bradOf round trip failed at " & $brad & " (delta " & $delta & ")"

  # ---- rule 1: the shade-gain table -----------------------------------------
  for neighbours in 0 .. 6:
    var bodies: seq[Body]
    bodies.add(Body(x: 500, y: 300, energy: 60))
    for i in 0 ..< neighbours:
      bodies.add(Body(x: 500 + i, y: 300 + 1, energy: 60))
    let sim = singleSpecies(spGrass, bodies, StewardDoctrine[spGrass])
    let before = sim.bodies[spGrass][0].energy
    sim.step()
    let expected = clampInt(5 - neighbours, 0, 5) - GrassMetabolism
    doAssert sim.bodies[spGrass][0].energy == before + expected,
      "shade gain wrong at " & $neighbours & " neighbours: " &
      $(sim.bodies[spGrass][0].energy - before) & " vs " & $expected

  # ---- rule 3: the bite transfer and its integer rounding -------------------
  for bite in [2, 3, 7, 10, 14]:
    var doctrine = StewardDoctrine[spGrazers]
    doctrine[1] = bite
    var config = standardConfig(2)
    config.initGrass = 1
    config.initGrazers = 1
    config.initPredators = 1
    let sim = newSim(config)
    sim.bodies[spGrass] = @[Body(x: 500, y: 300, energy: 150)]
    sim.bodies[spGrazers] = @[Body(x: 505, y: 300, energy: 50)]
    sim.bodies[spPredators] = @[]
    sim.doctrine[spGrazers] = doctrine
    sim.doctrine[spGrass] = [200, 90, 40, 3]   # too dear to seed this tick
    sim.step()
    ## The tuft photosynthesises (+4) before the bite lands.
    doAssert sim.bodies[spGrass][0].energy == 150 + 4 - bite,
      "tuft energy after a bite of " & $bite
    doAssert sim.bodies[spGrazers][0].energy ==
      50 + (bite * 4) div 5 - GrazerMetabolism,
      "grazer energy after a bite of " & $bite

  # ---- rule 6: predation gain, the cap and the cooldown ---------------------
  for preyEnergy in [10, 90, 120, 200]:
    var config = standardConfig(3)
    config.initGrass = 1
    config.initGrazers = 1
    config.initPredators = 1
    let sim = newSim(config)
    sim.bodies[spGrass] = @[]
    sim.bodies[spGrazers] = @[Body(x: 500, y: 300, energy: preyEnergy)]
    sim.bodies[spPredators] = @[Body(x: 500, y: 300, energy: 100)]
    sim.doctrine[spPredators] = StewardDoctrine[spPredators]
    # flee_range 0: the grazer wanders rather than sprinting out of reach, so
    # the only thing between its recorded energy and the kill is one tick of
    # metabolism.
    sim.doctrine[spGrazers] = [240, 10, 0, 0]
    sim.step()
    let gain = min(KillCap, KillBase + preyEnergy - GrazerMetabolism)
    doAssert sim.bodies[spGrazers].len == 0, "the grazer should be eaten"
    doAssert sim.bodies[spPredators][0].energy == min(PredatorEMax, 100 + gain),
      "kill gain for prey energy " & $preyEnergy
    doAssert sim.bodies[spPredators][0].cooldown == HuntCooldown,
      "the kill must set a 12-tick cooldown"
    doAssert sim.predation == 1

  # ---- crowding stress steps ------------------------------------------------
  block:
    for crowd in [0, 5, 6, 11, 12, 20]:
      var bodies: seq[Body]
      bodies.add(Body(x: 500, y: 300, energy: 60))
      for i in 0 ..< crowd:
        bodies.add(Body(x: 500 + (i mod 5), y: 300 + (i div 5), energy: 60))
      let sim = singleSpecies(spGrazers, bodies, StewardDoctrine[spGrazers])
      let before = sim.bodies[spGrazers][0].energy
      sim.step()
      let stress = min(2, crowd div 6)
      doAssert before - sim.bodies[spGrazers][0].energy ==
        GrazerMetabolism + stress,
        "grazer stress step at crowd " & $crowd
    for pcrowd in [0, 1, 2, 3, 4, 8]:
      var bodies: seq[Body]
      bodies.add(Body(x: 500, y: 300, energy: 300))
      for i in 0 ..< pcrowd:
        bodies.add(Body(x: 500 + i, y: 301, energy: 300))
      var doctrine = StewardDoctrine[spPredators]
      doctrine[2] = 200          ## rest_energy: 300 >= 200, so it idles
      let sim = singleSpecies(spPredators, bodies, doctrine)
      let before = sim.bodies[spPredators][0].energy
      sim.step()
      let stress = min(2, pcrowd div 2)
      doAssert before - sim.bodies[spPredators][0].energy ==
        PredatorIdle + stress,
        "predator stress step at crowd " & $pcrowd

  # ---- rule 4: the many-eyes flee speed -------------------------------------
  block:
    for crowd in [1, 4]:
      var config = standardConfig(4)
      config.initGrass = 1
      config.initGrazers = 1
      config.initPredators = 1
      let sim = newSim(config)
      sim.bodies[spGrass] = @[]
      sim.bodies[spPredators] = @[Body(x: 400, y: 300, energy: 480)]
      var grazers = @[Body(x: 420, y: 300, energy: 100)]
      for i in 0 ..< crowd:
        grazers.add(Body(x: 421 + i, y: 301, energy: 100))
      sim.bodies[spGrazers] = grazers
      var doctrine = StewardDoctrine[spGrazers]
      doctrine[2] = 300          ## flee_range: always fleeing
      doctrine[0] = 240          ## birth_threshold: nothing splits this tick
      sim.doctrine[spGrazers] = doctrine
      sim.doctrine[spPredators] = [400, 40, 480, 40]  ## the predator idles
      sim.step()
      let expected =
        if crowd >= ManyEyesCrowd: GrazerManyEyesSpeed else: GrazerFleeSpeed
      doAssert sim.bodies[spGrazers][0].x == 420 + expected,
        "flee speed at crowd " & $crowd & ": moved " &
        $(sim.bodies[spGrazers][0].x - 420)

  # ---- rule 9: split arithmetic and cap refusal -----------------------------
  for energy in [100, 121, 240, 400]:
    var doctrine = StewardDoctrine[spGrazers]
    doctrine[0] = 80
    let sim = singleSpecies(spGrazers,
      @[Body(x: 500, y: 300, energy: energy)], doctrine)
    sim.bodies[spGrass] = @[]
    sim.step()
    let half = (energy - GrazerMetabolism - SplitOverhead) div 2
    doAssert sim.bodies[spGrazers].len == 2,
      "a grazer at " & $energy & " must split"
    doAssert sim.bodies[spGrazers][0].energy == half and
      sim.bodies[spGrazers][1].energy == half,
      "split halves at " & $energy & ": " &
      $sim.bodies[spGrazers][0].energy & " / " &
      $sim.bodies[spGrazers][1].energy & " expected " & $half
  block:
    ## A birth that would exceed the cap does not happen.
    var doctrine = StewardDoctrine[spGrazers]
    doctrine[0] = 80
    var bodies: seq[Body]
    for i in 0 ..< 140:
      bodies.add(Body(x: 100 + (i mod 40) * 20, y: 100 + (i div 40) * 90,
        energy: 240))
    let sim = singleSpecies(spGrazers, bodies, doctrine)
    sim.bodies[spGrass] = @[]
    sim.step()
    doAssert sim.bodies[spGrazers].len == 140,
      "the grazer cap must be hard, saw " & $sim.bodies[spGrazers].len

  # ---- rule 8: death removal happens before birth ---------------------------
  block:
    var doctrine = StewardDoctrine[spGrazers]
    doctrine[0] = 80
    let sim = singleSpecies(spGrazers, @[
      Body(x: 500, y: 300, energy: 1),      # starves this tick
      Body(x: 700, y: 300, energy: 200)     # splits this tick
    ], doctrine)
    sim.bodies[spGrass] = @[]
    sim.step()
    doAssert sim.starved[spGrazers] == 1
    doAssert sim.bodies[spGrazers].len == 2,
      "one starved, one split: " & $sim.bodies[spGrazers].len
    for body in sim.bodies[spGrazers]:
      doAssert body.energy > 0

  # ---- rule 7: field clamping -----------------------------------------------
  block:
    let sim = singleSpecies(spGrazers, @[
      Body(x: 2, y: 2, energy: 100, heading: 128),
      Body(x: 998, y: 560, energy: 100, heading: 0)
    ], StewardDoctrine[spGrazers])
    sim.bodies[spGrass] = @[]
    for _ in 0 .. 40:
      sim.step()
    for body in sim.bodies[spGrazers]:
      doAssert body.x >= 0 and body.x <= sim.config.fieldW
      doAssert body.y >= 0 and body.y <= sim.config.fieldH

  # ---- doctrine clamping at both ends of all twelve ranges ------------------
  for species in Species:
    for field in 0 .. 3:
      var low = StewardDoctrine[species]
      low[field] = DoctrineMin[species][field] - 1000
      let clampedLow = clampDoctrine(species, low)
      doAssert clampedLow.clamped
      doAssert clampedLow.fields[field] == DoctrineMin[species][field]
      var high = StewardDoctrine[species]
      high[field] = DoctrineMax[species][field] + 1000
      let clampedHigh = clampDoctrine(species, high)
      doAssert clampedHigh.clamped
      doAssert clampedHigh.fields[field] == DoctrineMax[species][field]
    doAssert not clampDoctrine(species, StewardDoctrine[species]).clamped
    doAssert not clampDoctrine(species, OpportunistDoctrine[species]).clamped

  # ---- determinism -----------------------------------------------------------
  block:
    let a = stewardEpisode(standardConfig(11))
    let b = stewardEpisode(standardConfig(11))
    doAssert a.gameHash() == b.gameHash(),
      "the same seed must reproduce the same 600 ticks: " &
      a.gameHash() & " vs " & b.gameHash()
    doAssert a.tick == b.tick and a.tick > 0
    let c = stewardEpisode(standardConfig(12))
    doAssert a.gameHash() != c.gameHash(),
      "different seeds must diverge"
    ## Twice in one process, and across a fresh SimServer built from the same
    ## config object — no hidden global carries state between episodes.
    var config = standardConfig(11)
    let d = stewardEpisode(config)
    doAssert a.gameHash() == d.gameHash()

  # ---- role rotation ---------------------------------------------------------
  block:
    var seen: Table[string, bool]
    for offset in 0 .. 2:
      var config = standardConfig(5)
      config.roleOffset = offset
      let sim = newSim(config)
      var roles: seq[string]
      for slot in 0 .. 2:
        roles.add(RoleNames[sim.roleOf[slot]])
        doAssert sim.names[slot] == SeatAliases[slot],
          "roles rotate, aliases do not"
      doAssert roles.len == 3
      seen[roles.join(",")] = true
      for species in Species:
        doAssert sim.roleOf[sim.seatOf[species]] == species
    doAssert seen.len == 3, "each roleOffset must deal a distinct rotation"

  # ---- every seat is told ITS OWN constants ---------------------------------
  block:
    let sim = newSim(standardConfig(5))
    for slot in 0 .. 2:
      let species = sim.roleOf[slot]
      let rules = sim.observationJson(slot){"rules"}
      doAssert rules{"energyMax"}.getInt() == SpeciesEMax[species],
        RoleNames[species] & " is told the wrong energy ceiling"
      case species
      of spGrass:
        doAssert rules{"gain"}.getInt() == sim.config.grassGain
        doAssert rules{"shadeRadius"}.getInt() == ShadeRadius
        doAssert not rules.hasKey("biteRadius"), "grass does not bite"
      of spGrazers:
        doAssert rules{"biteRadius"}.getInt() == BiteRadius
        doAssert rules{"speed"}.getInt() == GrazerSpeed
        doAssert rules{"fleeSpeed"}.getInt() == GrazerFleeSpeed
      of spPredators:
        doAssert rules{"killBase"}.getInt() == KillBase
        doAssert rules{"chaseSpeed"}.getInt() == PredatorChaseSpeed
        doAssert not rules.hasKey("fleeSpeed"), "a predator never flees"

  echo "test_sim: ok"
