## tests/test_llm.nim — the decision layer, with a stubbed transport.
##
## Nothing here touches the network: `newLlmClientFor` takes the key
## explicitly, and every reply is a synthetic `curly.Response`, so the whole
## ladder — tolerant JSON extraction, numeric coercion, clamping, the auth /
## throttle / junk failure modes and the scripted fallback — is exercised
## deterministically.

import std/[json, strutils]
import curly
import helpers
import ../src/ecos/llm

proc reply(text: string): Response =
  Response(code: 200, body: $ %*{
    "content": [{"type": "text", "text": text}],
    "stop_reason": "end_turn"
  })

proc status(code: int, body = "{}"): Response =
  Response(code: code, body: body)

when isMainModule:
  let config = standardConfig(4)
  let sim = newSim(config)
  let client = newLlmClientFor(config, "test-key-not-used")
  doAssert not client.disabled

  # ---- extractJsonObject tolerates fences and prose -------------------------
  doAssert extractJsonObject("{\"a\":1}"){"a"}.getInt() == 1
  doAssert extractJsonObject("```json\n{\"a\":2}\n```"){"a"}.getInt() == 2
  doAssert extractJsonObject(
    "Sure! Here is my answer:\n{\"a\":3}\nHope that helps."){"a"}.getInt() == 3
  block:
    var raised = false
    try:
      discard extractJsonObject("I am afraid I cannot help with that.")
    except EcosError:
      raised = true
    doAssert raised, "prose with no object must be an invalid reply"

  # ---- numeric strings and floats are accepted ------------------------------
  block:
    let decision = parseDecision(spGrazers, parseJson("""
      {"doctrine":{"birth_threshold":"120","bite":8.7,"flee_range":90,
                   "herd":55},"say":"holding","notes":"n"}"""))
    doAssert decision.fields == [120, 9, 90, 55],
      "coerced doctrine " & $decision.fields
    doAssert not decision.clamped
    doAssert decision.say == "holding"
    doAssert decision.notes == "n"

  # ---- out of range is clamped and flagged ----------------------------------
  block:
    let decision = parseDecision(spPredators, parseJson("""
      {"doctrine":{"birth_threshold":9999,"hunt_range":-5,"rest_energy":700,
                   "spread":40}}"""))
    doAssert decision.clamped
    doAssert decision.fields == [400, 40, 400, 40], $decision.fields

  # ---- a missing or non-numeric field is INVALID, not clamped ---------------
  for payload in [
    """{"doctrine":{"birth_threshold":100,"bite":8,"flee_range":40}}""",
    """{"doctrine":{"birth_threshold":100,"bite":"soon","flee_range":40,
        "herd":20}}""",
    """{"say":"nothing else"}"""
  ]:
    var raised = false
    try:
      discard parseDecision(spGrazers, parseJson(payload))
    except EcosError:
      raised = true
    doAssert raised, "should have been invalid: " & payload

  # ---- a doctrine inlined at the top level is still read --------------------
  block:
    let decision = parseDecision(spGrass, parseJson("""
      {"seed_threshold":150,"seed_range":100,"seed_cost":50,"crowd_limit":2}"""))
    doAssert decision.fields == [150, 100, 50, 2]

  # ---- the stubbed transport: timeout, 429, 403, junk -----------------------
  proc failsWith(response: Response, error: string): string =
    try:
      discard client.decisionFrom(spGrazers, response, error, "http://stub")
      return ""
    except EcosError as e:
      return e.msg
  doAssert "transport" in failsWith(Response(), "operation timed out")
  doAssert "throttled" in failsWith(status(429), "")
  doAssert failsWith(reply("not json at all"), "").len > 0
  doAssert failsWith(
    Response(code: 200, body: $ %*{"content": [], "stop_reason": "refusal"}),
    "").len > 0
  block:
    let cut = Response(code: 200, body: $ %*{
      "content": [{"type": "text", "text": "Let me think about the"}],
      "stop_reason": "max_tokens"})
    doAssert "max_tokens" in failsWith(cut, "")
  # 403 disables the client for the rest of the episode.
  doAssert not client.disabled
  doAssert "auth failed" in failsWith(status(403, "denied"), "")
  doAssert client.disabled, "a 403 must disable the client"

  # ---- ONE batch carries every open seat ------------------------------------
  block:
    let batchClient = newLlmClientFor(config, "test-key-not-used")
    let seats = @[0, 1, 2]
    var prompts = @["", "be careful", ""]
    var kinds = @[skNone, skNone, skNone]
    var open = batchClient.openSeatsOf(seats, kinds)
    doAssert open.len == 3
    var batch = batchClient.requestBatchFor(sim, seats, open, prompts, 0)
    doAssert batch.len == open.len,
      "one batch must carry all " & $open.len & " open seats, saw " &
      $batch.len
    doAssert "GUIDANCE FROM YOUR OPERATOR" in batch[1].body,
      "the operator prompt must reach the seat that set it"
    # A scripted seat never joins the batch.
    kinds[2] = skOpportunist
    open = batchClient.openSeatsOf(seats, kinds)
    doAssert open == @[0, 1]
    batch = batchClient.requestBatchFor(sim, seats, open, prompts, 1)
    doAssert batch.len == 2
    doAssert "previous reply was invalid" in batch[0].body,
      "the retry batch must carry the hint"

  # ---- with no credentials every seat plays the steward, and nothing raises --
  block:
    let offline = newLlmClientFor(config, "")
    doAssert offline.disabled
    let seats = @[0, 1, 2]
    let decisions = offline.decideAll(sim, seats, @["", "", ""],
      @[skNone, skNone, skNone])
    doAssert decisions.len == 3
    for index, decision in decisions:
      let species = sim.roleOf[seats[index]]
      doAssert decision.source == dsFallback,
        "an offline seat is a fallback, saw " & $decision.source
      doAssert decision.fields == scriptedDoctrine(sim, species, skSteward),
        "the fallback must be the steward doctrine"
      doAssert not clampDoctrine(species, decision.fields).clamped

  # ---- a declared baseline is recorded as scripted, not as a fallback -------
  block:
    let offline = newLlmClientFor(config, "")
    let decisions = offline.decideAll(sim, @[0, 1, 2], @["", "", ""],
      @[skSteward, skOpportunist, skNone])
    doAssert decisions[0].source == dsScripted
    doAssert decisions[1].source == dsScripted
    doAssert decisions[2].source == dsFallback
    doAssert decisions[1].fields ==
      scriptedDoctrine(sim, sim.roleOf[1], skOpportunist)

  # ---- the kernel a seat is told is the kernel the sim runs ----------------
  # The prompt quotes the payoff a predator gets for a kill. It is built from
  # the sim's own constants, so a change to `KillBase` moves both or neither.
  block:
    let system = sim.systemPrompt(sim.seatOf[spPredators])
    doAssert "min(" & $KillCap & ", " & $KillBase &
      " + the grazer's energy)" in system,
      "the predator prompt must quote the sim's kill formula, not a stale one"

  # ---- haiku only: the sonnet fallbacks cascade on the sidecar --------------
  doAssert bedrockModelIds() == @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

  echo "test_llm: ok"
