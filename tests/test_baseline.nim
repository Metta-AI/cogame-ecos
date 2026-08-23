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
  var stewardClamps = 0
  for kind in [skSteward, skOpportunist]:
    for seed in 1 .. Seeds:
      let label = $kind & " seed " & $seed
      let sim = newSim(standardConfig(seed))
      while not sim.done:
        for species in Species:
          let started = epochTime()
          let decided = scriptedDoctrineChecked(sim, species, kind)
          let elapsed = epochTime() - started
          if elapsed > slowest: slowest = elapsed
          checkDoctrine(species, decided.fields, label)
          if kind == skSteward and decided.clamped: inc stewardClamps
          sim.applyDoctrine(species, decided.fields, dsScripted,
            decided.clamped, "", "", 0)
        # Step the generation one tick at a time so the invariants are
        # checked on EVERY tick, not only at the boundary.
        let target = sim.generationsPlayed + 1
        while not sim.done and sim.generationsPlayed < target:
          sim.step()
          sim.checkInvariants(label)
      doAssert sim.tick > 0, label & ": no ticks were played"
      doAssert sim.reason in ["complete", "deadline", "forfeit"],
        label & ": illegal reason " & sim.reason
      # Every doctrine event the episode recorded is legal too — that is what
      # "legal by construction" means, and the clamp is HOW: the recorded
      # `clamped` flag is the baseline's own, not a literal passed in here.
      for event in sim.events:
        if event.kind == ekDoctrine:
          checkDoctrine(event.species, event.fields, label & " event")
  # The steward's "recruit when thin" correction takes the grazer
  # birth_threshold from 90 to 70 on the standard opening, which the range
  # minimum of 80 pulls back up: the baseline is legal BECAUSE of the clamp,
  # so a scripted decision that never reports one means the flag went dead.
  doAssert stewardClamps > 0,
    "the steward never reported a clamp; the recorded `clamped` flag is not " &
    "the baseline's own"
  doAssert slowest < 0.001,
    "a baseline decision took " & formatFloat(slowest * 1000.0, ffDecimal, 3) &
    " ms; the budget is 1 ms per generation"
  echo "test_baseline: ok (slowest decision ",
    formatFloat(slowest * 1_000_000.0, ffDecimal, 1), " us)"
