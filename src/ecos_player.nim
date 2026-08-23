## Ecos player: a policy is just a prompt.
##
## Forked from `cogame-bullwhip/src/bullwhip_player.nim`. Connects, delivers
## its prompt once (and again after the welcome, which guards the
## slot-registration race), then only listens. Every decision is made inside
## the GAME container, which is what makes one parallel batch of three
## requests per generation possible.
##
## PLAYER_SCRIPTED=steward|opportunist registers the seat as a built-in
## baseline instead; the server plays those deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <ecos-image> --name my-ecos \
##     --run /bin/ecos-player --secret-env PLAYER_PROMPT="<your strategy>"

import std/[json, options, os, strutils]
import whisky

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
  let scripted = getEnv("PLAYER_SCRIPTED").strip()

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "ecos player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "ecos player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

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
          ## Re-deliver the prompt after the welcome, in case the first send
          ## raced the server's slot registration.
          socket.send(promptFrame())
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
