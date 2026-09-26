## Ecos player: scripted or prompt policy over a private observation.
##
## The game requests one complete doctrine per generation from each seat.
##
## PLAYER_SCRIPTED=steward|opportunist selects a local baseline.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <ecos-image> --name my-ecos \
##     --run /bin/ecos-player --secret-env PLAYER_PROMPT="<your strategy>"

import std/[json, options, os, strutils, times]
import whisky
import ecos/[sim_types, scripted, llm]

const DefaultPrompt = """
You are a steward. Your score is integrated biomass, so what you want is many
generations of solid, boring abundance - not one spike. Every generation, read
the two other populations first: if the species you depend on has fallen more
than 20% since last generation, back off before you do anything else. Only push
for growth when the level below you is at or above its reference. Never let any
population fall under a fifth of its cap - if one does, the whole episode can
end and every remaining generation scores zero for you too. Keep notes of the
last three generations' populations and of what your last change did.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scriptKind = parseScriptKind(getEnv("PLAYER_SCRIPTED"))
  let kind =
    if scriptKind != skNone: "scripted"
    else: "prompt"
  let client =
    if kind == "prompt":
      newLlmClient(parseInt(getEnv("PLAYER_MAX_OUTPUT_TOKENS", "900")),
        getEnv("PLAYER_MODEL", "claude-haiku-4-5"))
    else: nil

  echo "ecos player: connecting to game"
  let socket = newWebSocket(url)
  echo "ecos player: policy ", kind

  ## whisky's receiveMessage RAISES on a close or truncated frame (only a
  ## timeout returns none), and mummy's send only queues — the game's
  ## quit(0) can outrun the flushed final frame. Exiting non-zero there makes
  ## docker_smoke pass and certification fail intermittently (LEARNINGS
  ## 2026-08-23 raid, item 3), so a dead socket is a clean exit 0.
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "ecos player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "ecos player: seated at slot ", payload{"slot"}.getInt(),
            " as ", payload{"name"}.getStr(),
            " (", payload{"role"}.getStr(), ")"
        of "decision":
          if payload["protocol"].getStr() != PlayerProtocol:
            raise newException(EcosError, "unexpected player protocol")
          let view = payload["view"]
          let species = speciesFromName(view["role"].getStr())
          let generation = payload["generation"].getInt()
          let started = epochTime()
          let timeoutSeconds = max(1,
            payload["timeout_ms"].getInt() div 1000 - 1)
          var source = "scripted"
          var answer: JsonNode
          if kind == "scripted":
            let fields = scriptedDoctrineFromView(view, scriptKind).fields
            answer = %*{"doctrine": doctrineJson(species, fields),
              "say": "", "notes": ""}
          elif client.disabled:
            source = "fallback"
          else:
            source = "llm"
            try:
              answer =
                choosePromptDoctrine(client, view, prompt, timeoutSeconds)
            except CatchableError as error:
              echo "ecos player: policy call failed: ", error.msg
              source = "fallback"
          if source == "fallback":
            let fields = scriptedDoctrineFromView(view, skSteward).fields
            answer = %*{"doctrine": doctrineJson(species, fields),
              "say": "", "notes": ""}
          answer["type"] = %"action"
          answer["generation"] = %generation
          answer["source"] = %source
          answer["latency_ms"] = %int((epochTime() - started) * 1000.0)
          socket.send($answer)
        of "state":
          echo "ecos player: generation ", payload{"generation"}.getInt(),
            " population ", payload{"you"}{"population"}.getInt(),
            " biomass ", payload{"you"}{"biomass"}.getInt()
        of "final":
          echo "ecos player: final scores ", payload{"scores"},
            " (", payload{"ending"}.getStr(), ")"
          break
        else:
          discard
      except CatchableError as error:
        echo "ecos player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "ecos player: socket closed (", error.msg, "), exiting 0"
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
