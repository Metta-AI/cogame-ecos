## Player-side prompt parsing and the visible-observation policy boundary.

import std/[json, strutils]
import curly
import helpers
import ../src/ecos/[llm, scripted, sim, sim_types]

when isMainModule:
  let config = standardConfig(4)
  let world = newSim(config)
  let client = newLlmClientFor("test-key-not-used")
  doAssert not client.disabled

  doAssert extractJsonObject("```json\n{\"a\":2}\n```")["a"].getInt() == 2
  let parsed = parseDecision(spGrazers, parseJson("""
    {"doctrine":{"birth_threshold":"120","bite":8.7,"flee_range":90,
                 "herd":55},"say":"holding","notes":"n"}"""))
  doAssert parsed.fields == [120, 9, 90, 55]
  doAssert not parsed.clamped
  doAssert parsed.say == "holding" and parsed.notes == "n"
  let clamped = parseDecision(spPredators, parseJson("""
    {"doctrine":{"birth_threshold":9999,"hunt_range":-5,
                 "rest_energy":700,"spread":40}}"""))
  doAssert clamped.clamped
  doAssert clamped.fields == [400, 40, 400, 40]

  for slot in 0 .. 2:
    let species = world.roleOf[slot]
    let view = world.observationJson(slot)
    doAssert view["role"].getStr() == RoleNames[species]
    for kind in [skSteward, skOpportunist]:
      doAssert scriptedDoctrineFromView(view, kind).fields ==
        scriptedDoctrine(world, species, kind)

  let refusal = Response(code: 200, body: $ %*{
    "content": [], "stop_reason": "refusal"})
  var rejected = false
  try:
    discard client.textOf(refusal, "", "http://stub")
  except EcosError:
    rejected = true
  doAssert rejected
  doAssert "min(" & $KillCap & ", " & $KillBase &
    " + the grazer's energy)" in world.systemPrompt(world.seatOf[spPredators])
  echo "test_llm: ok"
