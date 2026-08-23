## Ecos scripted baselines — `steward` and `opportunist`.
##
## Both are fieldable policies (`PLAYER_SCRIPTED=steward|opportunist`) AND
## the fallback every LLM seat degrades to, which is what keeps offline
## certification green. Both are legal by construction: every field is
## clamped to its declared range before it leaves this module, and
## `tests/test_baseline.nim` asserts it over 12 seeds x 600 ticks.

import std/strutils
import sim_types, sim

type
  ScriptKind* = enum
    skNone = "none"
    skSteward = "steward"
    skOpportunist = "opportunist"

proc parseScriptKind*(text: string): ScriptKind =
  ## `PLAYER_SCRIPTED` values. "1"/"true"/"yes" pick the steward, the safe
  ## default; anything unrecognised registers no baseline at all.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "steward": skSteward
  of "opportunist", "greedy": skOpportunist
  else: skNone

proc baseDoctrine*(kind: ScriptKind, species: Species): Doctrine =
  case kind
  of skOpportunist: OpportunistDoctrine[species]
  else: StewardDoctrine[species]

proc correct(sim: SimServer, species: Species, base: Doctrine): Doctrine =
  ## The two closed-loop corrections, applied in this order:
  ##   1. recruit when thin  — my population below 0.4 x my cap
  ##   2. back off when my food is thin — the species I eat below 0.4 x its
  ##      cap (grass reads grazer PRESSURE instead: grazers above 0.6 x cap)
  result = base
  let myCap = sim.capOf(species)
  if sim.population(species) * 10 < 4 * myCap:
    case species
    of spGrass: result[0] -= 20
    of spGrazers: result[0] -= 20
    of spPredators: result[0] -= 40
  case species
  of spGrass:
    if sim.population(spGrazers) * 10 > 6 * sim.capOf(spGrazers):
      result[1] += 40
      result[2] -= 10
  of spGrazers:
    if sim.population(spGrass) * 10 < 4 * sim.capOf(spGrass):
      result[1] -= 4
      result[2] += 40
  of spPredators:
    if sim.population(spGrazers) * 10 < 4 * sim.capOf(spGrazers):
      result[1] -= 60
      result[2] += 80
  result = clampDoctrine(species, result).fields

proc scriptedDoctrine*(sim: SimServer, species: Species,
    kind: ScriptKind): Doctrine =
  ## The baseline's doctrine for the coming generation. Always in range.
  correct(sim, species, baseDoctrine(
    (if kind == skNone: skSteward else: kind), species))
