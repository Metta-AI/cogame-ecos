## Ecos event vocabulary — the replay's `events[]`.
##
## Forked from paintbot's `src/ctf/events.nim`. One JSON row per event, `t`
## is the tick it fired on. Everything the viewer draws that is not a body
## position comes from here, so the shapes are pinned by
## `tests/test_replay.nim` and `tests/test_broadcast.nim`.

import std/json
import sim_types

type
  EventKind* = enum
    ekBirth = "birth"
    ekStarve = "starve"
    ekPredation = "predation"
    ekDoctrine = "doctrine"
    ekGeneration = "generation"
    ekAlarm = "alarm"
    ekCollapse = "collapse"
    ekEnd = "end"

  DoctrineSource* = enum
    dsLlm = "llm"
    dsRetry = "retry"
    dsFallback = "fallback"
    dsScripted = "scripted"

  EcosEvent* = object
    ## One recorded beat. The union is flat on purpose: flatty-style field
    ## order stays stable and the JSON writer below is the only reader.
    tick*: int
    kind*: EventKind
    species*: Species
    x*, y*: int
    energy*: int
    px*, py*: int          ## birth: parent position; predation: the predator
    age*: int
    seat*: int
    gen*: int
    fields*: Doctrine
    source*: DoctrineSource
    clamped*: bool
    say*: string
    notes*: string
    latencyMs*: int
    pop*: array[3, int]
    bio*: array[3, int]
    score*: array[3, float]
    cap*: int
    population*: int
    reason*: string
    ending*: string

proc eventToJson*(event: EcosEvent): JsonNode =
  ## The recorded row. Only the fields that kind defines are emitted, so a
  ## replay stays small and a reader never has to guess which are live.
  result = %*{"t": event.tick, "k": $event.kind}
  case event.kind
  of ekBirth:
    result["sp"] = %($event.species)
    result["x"] = %event.x
    result["y"] = %event.y
    result["e"] = %event.energy
    result["px"] = %event.px
    result["py"] = %event.py
  of ekStarve:
    result["sp"] = %($event.species)
    result["x"] = %event.x
    result["y"] = %event.y
    result["age"] = %event.age
  of ekPredation:
    result["x"] = %event.x
    result["y"] = %event.y
    result["e"] = %event.energy
    result["byX"] = %event.px
    result["byY"] = %event.py
  of ekDoctrine:
    result["seat"] = %event.seat
    result["sp"] = %($event.species)
    result["gen"] = %event.gen
    result["fields"] = doctrineJson(event.species, event.fields)
    result["source"] = %($event.source)
    result["clamped"] = %event.clamped
    result["say"] = %event.say
    result["notes"] = %event.notes
    result["latencyMs"] = %event.latencyMs
  of ekGeneration:
    result["gen"] = %event.gen
    result["pop"] = %[event.pop[0], event.pop[1], event.pop[2]]
    result["bio"] = %[event.bio[0], event.bio[1], event.bio[2]]
    result["score"] = %[event.score[0], event.score[1], event.score[2]]
  of ekAlarm:
    result["sp"] = %($event.species)
    result["pop"] = %event.population
    result["cap"] = %event.cap
  of ekCollapse:
    result["sp"] = %($event.species)
  of ekEnd:
    result["reason"] = %event.reason
    result["ending"] = %event.ending
    result["scores"] = %[event.score[0], event.score[1], event.score[2]]
