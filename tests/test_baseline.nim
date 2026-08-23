## tests/test_baseline.nim — the scripted baselines are legal by construction.
##
## For 12 seeds x a whole episode with `steward` and with `opportunist` on all
## three seats: every doctrine field emitted is inside its declared range
## AFTER the closed-loop corrections, every body position is inside the field,
## no energy is negative or above its ceiling, no population exceeds a cap,
## the baselines never raise, and a generation's worth of decisions costs
## well under a millisecond.

import std/[strutils, times]
import helpers

const Seeds = 12

proc checkInvariants(sim: SimServer, label: string) =
  for species in Species:
    doAssert sim.population(species) <= sim.capOf(species),
      label & ": " & RoleNames[species] & " population " &
      $sim.population(species) & " exceeded its cap of " &
      $sim.capOf(species)
    for body in sim.bodies[species]:
      doAssert body.x >= 0 and body.x <= sim.config.fieldW,
        label & ": " & RoleNames[species] & " left the field at x=" & $body.x
      doAssert body.y >= 0 and body.y <= sim.config.fieldH,
        label & ": " & RoleNames[species] & " left the field at y=" & $body.y
      doAssert body.energy > 0,
        label & ": a living " & RoleNames[species] & " has energy " &
        $body.energy
      doAssert body.energy <= SpeciesEMax[species],
        label & ": " & RoleNames[species] & " energy " & $body.energy &
        " exceeded its ceiling of " & $SpeciesEMax[species]

proc checkDoctrine(species: Species, fields: Doctrine, label: string) =
  for i in 0 .. 3:
    doAssert fields[i] >= DoctrineMin[species][i] and
      fields[i] <= DoctrineMax[species][i],
      label & ": " & DoctrineFieldNames[species][i] & "=" & $fields[i] &
      " is outside " & $DoctrineMin[species][i] & ".." &
      $DoctrineMax[species][i]

when isMainModule:
  var slowest = 0.0
  for kind in [skSteward, skOpportunist]:
    for seed in 1 .. Seeds:
      let label = $kind & " seed " & $seed
      let sim = newSim(standardConfig(seed))
      while not sim.done:
        for species in Species:
          let started = epochTime()
          let fields = scriptedDoctrine(sim, species, kind)
          let elapsed = epochTime() - started
          if elapsed > slowest: slowest = elapsed
          checkDoctrine(species, fields, label)
          sim.applyDoctrine(species, fields, dsScripted, false, "", "", 0)
        # Step the generation one tick at a time so the invariants are
        # checked on EVERY tick, not only at the boundary.
        let target = sim.generationsPlayed + 1
        while not sim.done and sim.generationsPlayed < target:
          sim.step()
          sim.checkInvariants(label)
      doAssert sim.tick > 0, label & ": no ticks were played"
      doAssert sim.reason in ["complete", "deadline", "forfeit"],
        label & ": illegal reason " & sim.reason
      # Every doctrine event the episode recorded is legal too.
      for event in sim.events:
        if event.kind == ekDoctrine:
          checkDoctrine(event.species, event.fields, label & " event")
          doAssert not event.clamped,
            label & ": a scripted decision should never need clamping"
  doAssert slowest < 0.001,
    "a baseline decision took " & formatFloat(slowest * 1000.0, ffDecimal, 3) &
    " ms; the budget is 1 ms per generation"
  echo "test_baseline: ok (slowest decision ",
    formatFloat(slowest * 1_000_000.0, ffDecimal, 1), " us)"
