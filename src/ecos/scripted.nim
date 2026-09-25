## Ecos scripted baselines — `steward` and `opportunist`.
##
## Both are fieldable policies (`PLAYER_SCRIPTED=steward|opportunist`) AND
## the fallback every LLM seat degrades to, which is what keeps offline
## certification green. Both are legal by construction: every field is
## clamped to its declared range before it leaves this module, and
## `tests/test_baseline.nim` asserts it over 12 seeds x 600 ticks.

import std/[json, strutils]
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

proc correct(species: Species, base: Doctrine,
    populations, caps: array[Species, int]):
    tuple[fields: Doctrine, clamped: bool] =
  ## The two closed-loop corrections, applied in this order:
  ##   1. recruit when thin  — my population below 0.4 x my cap
  ##   2. back off when my food is thin — the species I eat below 0.4 x its
  ##      cap (grass reads grazer PRESSURE instead: grazers above 0.6 x cap)
  var fields = base
  if populations[species] * 10 < 4 * caps[species]:
    case species
    of spGrass: fields[0] -= 20
    of spGrazers: fields[0] -= 20
    of spPredators: fields[0] -= 40
  case species
  of spGrass:
    if populations[spGrazers] * 10 > 6 * caps[spGrazers]:
      fields[1] += 40
      fields[2] -= 10
  of spGrazers:
    if populations[spGrass] * 10 < 4 * caps[spGrass]:
      fields[1] -= 4
      fields[2] += 40
  of spPredators:
    if populations[spGrazers] * 10 < 4 * caps[spGrazers]:
      fields[1] -= 60
      fields[2] += 80
  clampDoctrine(species, fields)

proc scriptedDoctrineFromView*(view: JsonNode, kind: ScriptKind):
    tuple[fields: Doctrine, clamped: bool] =
  ## The baseline's doctrine for the coming generation, and whether a
  ## correction drove a field out of its declared range on the way. The
  ## baseline is legal because of that clamp, not in spite of it: the
  ## steward's "recruit when thin" takes a grazer birth_threshold of 90 to 70,
  ## which the range minimum of 80 pulls back up. The flag is recorded on the
  ## `doctrine` event, so the replay says which decisions were corrected.
  let species = speciesFromName(view["role"].getStr())
  var populations, caps: array[Species, int]
  for other in Species:
    populations[other] = view["species"][ord(other)]["population"].getInt()
    caps[other] = view["species"][ord(other)]["cap"].getInt()
  correct(species, baseDoctrine(
    (if kind == skNone: skSteward else: kind), species), populations, caps)

proc scriptedDoctrineChecked*(sim: SimServer, species: Species,
    kind: ScriptKind): tuple[fields: Doctrine, clamped: bool] =
  var populations, caps: array[Species, int]
  for other in Species:
    populations[other] = sim.population(other)
    caps[other] = sim.capOf(other)
  correct(species, baseDoctrine(
    (if kind == skNone: skSteward else: kind), species), populations, caps)

proc scriptedDoctrine*(sim: SimServer, species: Species,
    kind: ScriptKind): Doctrine =
  ## The baseline's doctrine for the coming generation. Always in range.
  scriptedDoctrineChecked(sim, species, kind).fields
