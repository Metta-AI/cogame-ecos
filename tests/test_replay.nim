## tests/test_replay.nim — a whole episode, end to end, plus the strict-UTF-8
## contract on every recorded string.
##
## Plays a full scripted episode headless, builds `results.json` and the
## replay exactly as `server.nim` does, then re-reads the replay BYTES: a
## byte-boundary truncation of a `say`/`notes` string renders fine in a
## browser and is rejected by a strict parser, so only reading the bytes back
## catches it (LEARNINGS 2026-08-22 bullwhip).

import std/[json, strutils, tables, unicode]
import helpers
import bitworld/spriteprotocol
import ../src/ecos/[replays, llm, global]

const MaxReplayBytes = 8 * 1024 * 1024

when isMainModule:
  let sim = stewardEpisode(standardConfig(3))
  let results = sim.resultsJson()
  let bytes = replayBytes(sim, results)

  # ---- strict UTF-8, then strict JSON --------------------------------------
  doAssert validateUtf8(bytes) == -1,
    "the replay is not valid UTF-8; first bad byte at " &
    $validateUtf8(bytes)
  doAssert bytes.len < MaxReplayBytes,
    "the replay is " & $(bytes.len div 1024) & " KiB, over the 8 MiB budget"
  let document = parseJson(bytes)
  doAssert document{"protocol"}.getStr() == "ecos.replay.v1"
  doAssert document{"game"}.getStr() == "ecos"
  doAssert document{"names"}.len == 3
  doAssert document{"policyNames"}.len == 3
  doAssert document{"roles"}.len == 3

  let ticksPlayed = sim.tick
  doAssert ticksPlayed > 0
  # Frame 0 is the opening state, so a T-tick episode records T + 1 frames.
  doAssert document{"frames"}.len == ticksPlayed + 1,
    "frames " & $document{"frames"}.len & " for " & $ticksPlayed & " ticks"
  doAssert document{"series"}{"pop"}.len == ticksPlayed + 1
  doAssert document{"series"}{"bio"}.len == ticksPlayed + 1
  for row in document{"series"}{"pop"}:
    doAssert row.len == 4, "a series row is [tick, grass, grazers, predators]"

  var counts = {"birth": 0, "starve": 0, "predation": 0, "doctrine": 0,
                "generation": 0, "alarm": 0, "collapse": 0, "end": 0}.toTable
  var lastEventTick = 0
  for event in document{"events"}:
    let tick = event{"t"}.getInt(-1)
    doAssert tick >= 0 and tick <= ticksPlayed,
      "event tick " & $tick & " outside 0.." & $ticksPlayed
    # `replays.nim`'s event cursor and `server.nim`'s recent-event walk both
    # assume `events[]` is sorted by `t`; an out-of-order row lands in the
    # wrong tick's slice and the feed draws it a frame late.
    doAssert tick >= lastEventTick,
      "events must be non-decreasing in t; " & event{"k"}.getStr() &
      " at " & $tick & " follows " & $lastEventTick
    lastEventTick = tick
    let kind = event{"k"}.getStr()
    doAssert counts.hasKey(kind), "unknown event kind " & kind
    counts[kind] = counts[kind] + 1
  doAssert counts["birth"] >= 1, "no births were recorded"
  doAssert counts["starve"] >= 1, "no starvations were recorded"
  doAssert counts["predation"] >= 1, "no predation was recorded"
  doAssert counts["generation"] == sim.config.generations,
    "expected " & $sim.config.generations & " generation events, saw " &
    $counts["generation"]
  doAssert counts["end"] == 1, "exactly one end event, saw " & $counts["end"]
  doAssert counts["doctrine"] == 3 * sim.config.generations

  # ---- results -------------------------------------------------------------
  doAssert results{"scores"}.len == 3
  doAssert results{"names"}.len == 3
  doAssert results{"win"}.len == 3
  doAssert results{"reason"}.getStr() in ["complete", "deadline", "forfeit"]
  doAssert results{"ending"}.getStr() == "ten_generations",
    "the all-steward field must reach ten generations, saw " &
    results{"ending"}.getStr()
  doAssert document{"results"}{"scores"}.len == 3

  # ---- the parser the wasm viewer uses reads its own bytes back ------------
  let reparsed = parseReplayBytes(bytes)
  doAssert reparsed.frames.len == ticksPlayed + 1
  doAssert reparsed.config.fieldW == sim.config.fieldW

  # Value by value, not count by count: a transposed or truncated triple
  # draws a board that is the right SIZE and the wrong picture, and the
  # viewer has nothing else to check itself against.
  doAssert reparsed.frames.len == sim.frames.len
  for index, frame in sim.frames:
    let reread = reparsed.frames[index]
    doAssert reread.t == index, "frame " & $index & " is stamped " & $reread.t
    doAssert reread.g == frame.g, "grass bodies differ at frame " & $index
    doAssert reread.h == frame.h, "grazer bodies differ at frame " & $index
    doAssert reread.p == frame.p, "predator bodies differ at frame " & $index
    # …and the frame agrees with the series row the same tick recorded: the
    # populations are the body counts and the biomass is their energy sum.
    for species in 0 .. 2:
      var energy = 0
      for i in 0 ..< reread.bodyCount(species):
        energy += reread.bodyAt(species, i).e
      doAssert reread.bodyCount(species) ==
        reparsed.series.pop[index][species + 1],
        "frame " & $index & " draws " & $reread.bodyCount(species) &
        " bodies of species " & $species & " where the strip says " &
        $reparsed.series.pop[index][species + 1]
      doAssert energy == reparsed.series.bio[index][species + 1],
        "frame " & $index & " carries biomass " & $energy &
        " where the series says " & $reparsed.series.bio[index][species + 1]

  var player = initReplayPlayer(reparsed)
  doAssert player.lastTick == ticksPlayed
  doAssert player.boardFrame().bodies[0].len ==
    reparsed.frames[0].bodyCount(0)

  # ---- one generation window: the viewer's score IS the sim's --------------
  # The sim scores generation g over the ticks it played (frame 0 is the
  # opening state, not a tick) and the viewer re-derives that same window from
  # the recorded `series.bio`. If the two windows ever differ again, the
  # scorebug, the end-card and `results.win` stop agreeing on who won.
  block:
    var scored = initReplayPlayer(reparsed)
    let derived = scored.scoreAt[scored.lastTick]
    for slot in 0 .. 2:
      let index = ord(sim.roleOf[slot])
      doAssert derived[index] == results{"scores"}[slot].getFloat(),
        "slot " & $slot & ": the viewer re-derives " &
        formatFloat(derived[index], ffDecimal, 6) & " where results.json " &
        "carries " & formatFloat(results{"scores"}[slot].getFloat(),
          ffDecimal, 6)
    # …and the end-card the viewer draws crowns the seat `results.win` does.
    var viewer = initGlobalViewerState()
    viewer.jumpEnd = true
    let ending = scored.advanceReplayFrame(viewer)
    let card = parseJson(ending.chrome){"over"}
    doAssert not card.isNil, "the last frame must carry the end-card"
    for slot in 0 .. 2:
      let key = RoleTeamKey[sim.roleOf[slot]]
      doAssert card{"teams"}{key}{"score"}.getFloat() ==
        results{"scores"}[slot].getFloat(),
        "the end-card score for " & key & " is not results.scores[" &
        $slot & "]"
      if results{"win"}[slot].getBool():
        doAssert card{"winner"}.getStr() == key or card{"draw"}.getBool(),
          "the end-card crowns " & card{"winner"}.getStr() &
          " where results.win crowns slot " & $slot & " (" & key & ")"

  # ---- the wasm entry point's whole loop, natively ---------------------------
  # `replay-viewer/ecos_replay.nim` is exactly these three calls; running them
  # here means a broken packet or a bad seek is a test failure rather than a
  # blank theater. (The wasm BUILD is what ci.yml's wasm-viewer job proves.)
  block:
    var viewer = initGlobalViewerState()
    var drawn = 0
    var chromeSeen = 0
    for step in 0 ..< 120:
      let advanced = player.advanceReplayFrame(viewer)
      let packet = buildBoardPacket(viewer, advanced.frame, advanced.fx,
        advanced.desat, advanced.chrome)
      doAssert packet.len > 0, "empty viewer packet at step " & $step
      for message in packet.parseSpritePacket():
        if message.kind == spkObject: inc drawn
        if message.kind == spkSprite and
            message.sprite.id == BroadcastChromeSpriteId:
          inc chromeSeen
          let chrome = parseJson(message.sprite.label)
          doAssert chrome{"teams"}.len == 3
          doAssert chrome{"t"}.getInt() == player.tick
      if step == 40:
        # A seek is an array index: no re-simulation, so it cannot diverge.
        viewer.replaySeekTick = ticksPlayed div 2
      if step == 80:
        viewer.replaySeekTick = ticksPlayed
    doAssert drawn > 1000, "the viewer drew only " & $drawn & " objects"
    doAssert chromeSeen == 120, "every frame must carry the chrome label"

  # ---- the multi-byte cap fixture -------------------------------------------
  # Exactly at the cap in RUNES, well over it in bytes: a byte cut would slice
  # a code point in half and put invalid UTF-8 in the replay.
  block:
    var sayRunes = ""
    for _ in 0 ..< MaxSayLen:
      sayRunes.add("\u00e9")            # 2 bytes each
    var noteRunes = ""
    for _ in 0 ..< MaxNotesLen:
      noteRunes.add(Rune(0x1F331).toUTF8())  # 4 bytes each: a seedling
    doAssert sayRunes.runeLen == MaxSayLen
    doAssert noteRunes.runeLen == MaxNotesLen
    doAssert sayRunes.len > MaxSayLen and noteRunes.len > MaxNotesLen

    let clean = cleanSay(sayRunes)
    let cleanNote = cleanNotes(noteRunes)
    doAssert validateUtf8(clean) == -1
    doAssert validateUtf8(cleanNote) == -1
    doAssert clean.runeLen <= MaxSayLen, "say is " & $clean.runeLen & " runes"
    doAssert cleanNote.runeLen <= MaxNotesLen

    # One rune OVER the cap must be cut, still on a rune boundary.
    let over = sayRunes & "\u00e9"
    let cut = cleanSay(over)
    doAssert validateUtf8(cut) == -1
    doAssert cut.runeLen == MaxSayLen
    doAssert cut.endsWith("…")
    let overNote = noteRunes & Rune(0x1F331).toUTF8()
    let cutNote = cleanNotes(overNote)
    doAssert validateUtf8(cutNote) == -1
    doAssert cutNote.runeLen == MaxNotesLen

    # …and the recorded event carries the cut string through to the bytes.
    let fixture = newSim(standardConfig(9))
    fixture.applyDoctrine(spGrazers, StewardDoctrine[spGrazers], dsLlm, false,
      cut, cutNote, 12)
    fixture.runGeneration()
    let fixtureBytes = replayBytes(fixture, fixture.resultsJson())
    doAssert validateUtf8(fixtureBytes) == -1,
      "multi-byte say/notes broke the replay's UTF-8"
    let reread = parseJson(fixtureBytes)
    var sawDoctrine = false
    for event in reread{"events"}:
      if event{"k"}.getStr() == "doctrine":
        sawDoctrine = true
        doAssert event{"say"}.getStr().runeLen <= MaxSayLen
        doAssert event{"notes"}.getStr().runeLen <= MaxNotesLen
        doAssert validateUtf8(event{"say"}.getStr()) == -1
        doAssert validateUtf8(event{"notes"}.getStr()) == -1
    doAssert sawDoctrine

  echo "test_replay: ok (", bytes.len div 1024, " KiB, ", ticksPlayed,
    " ticks)"
