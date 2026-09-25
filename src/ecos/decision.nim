## Complete doctrine parsing and game-owned fallback, without inference.

import std/[json, math, strutils, unicode]
import sim_types, sim, scripted, events

type
  Decision* = object
    fields*: Doctrine
    clamped*: bool
    say*: string
    notes*: string
    source*: DoctrineSource
    latencyMs*: int

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked. A byte
  ## cut put invalid UTF-8 into a bullwhip replay and only a strict parser
  ## found it (LEARNINGS 2026-08-22).
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc cleanSay*(text: string): string =
  cleanText(text.replace("\n", " ").replace("\r", " "), MaxSayLen)

proc cleanNotes*(text: string): string =
  cleanText(text, MaxNotesLen)

proc numberOf(node: JsonNode, name: string): int =
  ## A doctrine value may arrive as an integer, a numeric string or a float.
  if node.isNil or node.kind == JNull:
    raise newException(EcosError, "doctrine field missing: " & name)
  case node.kind
  of JInt: node.getInt()
  of JFloat: int(round(node.getFloat()))
  of JBool: raise newException(EcosError, "doctrine field is not a number: " & name)
  of JString:
    let text = node.getStr().strip()
    try:
      int(round(parseFloat(text)))
    except ValueError:
      raise newException(EcosError,
        "doctrine field is not a number: " & name & "=" & text)
  else:
    raise newException(EcosError, "doctrine field is not a number: " & name)

proc parseDecision*(species: Species, payload: JsonNode): Decision =
  ## Tolerant: extra keys are ignored, `doctrine` may also be inlined at the
  ## top level. A missing or non-numeric field is an INVALID reply; an
  ## out-of-range one is clamped and recorded as such.
  result.say = cleanSay(payload{"say"}.getStr())
  result.notes = cleanNotes(payload{"notes"}.getStr())
  var source = payload{"doctrine"}
  if source.isNil or source.kind != JObject:
    source = payload
  var raw: Doctrine
  for i in 0 .. 3:
    let name = DoctrineFieldNames[species][i]
    raw[i] = numberOf(source{name}, name)
  let checked = clampDoctrine(species, raw)
  result.fields = checked.fields
  result.clamped = checked.clamped

proc scriptedDecision*(sim: SimServer, species: Species,
    kind: ScriptKind): Decision =
  let checked = scriptedDoctrineChecked(sim, species, kind)
  Decision(
    fields: checked.fields,
    clamped: checked.clamped,
    source: (if kind == skNone: dsFallback else: dsScripted)
  )
