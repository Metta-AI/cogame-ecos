import
  std/json,
  ecos/[global, replays, sim_types]

var
  runtimeLoaded = false
  player: ReplayPlayer
  viewer: GlobalViewerState
  packet: seq[uint8]
  lastError: string

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping. The bundle is therefore linked
## with -s ABORTING_MALLOC=1 — allocation failure aborts the runtime loudly —
## and this fixed buffer, stamped BEFORE each risky phase, stays readable
## from JS after the abort (aborting kills the call stack, not the linear
## memory), so the page can still report what the runtime was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc renderCurrent() =
  let step = player.advanceReplayFrame(viewer)
  packet = buildBoardPacket(viewer, step.frame, step.fx, step.desat,
    step.chrome)

proc ecosLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "ecos_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let doc = parseReplayBytes(data.bytesFromPointer(int(length)))
    stampStage("initialize replay runtime")
    player = initReplayPlayer(doc)
    viewer = initGlobalViewerState()
    viewer.playing = false
    runtimeLoaded = true
    frameStage = "advance replay (" & $doc.frames.len & " frames)"
    stampStage("render first frame")
    renderCurrent()
    viewer.playing = true
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc ecosInput(data: ptr uint8, length: cint) {.exportc: "ecos_input", cdecl.} =
  if runtimeLoaded:
    viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))

proc ecosFrame(): cint {.exportc: "ecos_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    renderCurrent()
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc ecosPacketPointer(): ptr uint8 {.exportc: "ecos_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: packet[0].addr

proc ecosPacketLength(): cint {.exportc: "ecos_packet_len", cdecl.} =
  cint(packet.len)

proc ecosErrorPointer(): ptr uint8 {.exportc: "ecos_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc ecosErrorLength(): cint {.exportc: "ecos_error_len", cdecl.} =
  cint(lastError.len)

proc ecosStagePointer(): ptr uint8 {.exportc: "ecos_stage_ptr", cdecl.} =
  ## Unlike ecos_error_*, this stays valid after an allocation-failure abort,
  ## so JS can report what the runtime was doing when it died.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc ecosStageLength(): cint {.exportc: "ecos_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing the parsed replay, the sprite cache — everything — while the wasm
  # module stays alive and JS keeps calling ecos_load_replay/ecos_frame. The
  # whole session then runs on freed globals. Unwinding main through
  # emscripten's live-runtime exit skips the destructor epilogue entirely, so
  # globals stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
