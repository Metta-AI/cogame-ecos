## Ecos board renderer — the sprite-protocol emitter.
##
## Forked from paintbot's `src/ctf/global.nim`, heavily reduced: the sprite
## protocol emitter, the layer/object pooling, the map bands (here one tiled
## soil bake) and the chrome `TextMessage` smuggling survive; fog-of-war,
## first-person PiP, rig art, the grenade/spray/shield/barrier families,
## endzone bakes, perks and handicaps are gone — Ecos has none of them.
##
## Two callers, one code path: the live `/global` websocket walks a
## `SimServer` and the static wasm replay walks a recorded `ReplayDoc`; both
## hand this module a `BoardFrame` plus a chrome JSON string.

import std/[json, math, strutils, tables]
import pixie
import bitworld/spriteprotocol
import sim_types

const
  MapLayerId* = 0
  MapLayerKind* = SpriteLayerMap
  ZoomableFlag* = SpriteLayerZoomableFlag
  BroadcastChromeSpriteId* = 4090
    ## The broadcast chrome (scorebug / clock / feed / scrubber) rides as the
    ## LABEL of this reserved 1x1 sprite. `broadcast_core.js` keeps it off the
    ## drawable sprite map and feeds it straight to `onText` — the only path
    ## that survives a hosted replay.
  TargetFps* = 24
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]

  SoilTile* = 96
  SoilVariants = 4
  EnergyTints = 3
  WashStages* = 6

  SoilSpriteBase = 100
  WashSpriteBase = 120
  TuftSpriteBase = 200
  GrazerSpriteBase = 300
  PredatorSpriteBase = 400
  SparkleSpriteBase = 500
  SplashSpriteBase = 510
  FadeSpriteBase = 520

  SoilObjectBase = 1000
  WashObjectBase = 1400
  GrassObjectBase = 2000
  GrazerObjectBase = 2400
  PredatorObjectBase = 2600
  FxObjectBase = 3000
  MaxFxObjects = 400

  SoilZ = -30000
  GrassZ = 100
  GrazerZ = 400
  PredatorZ = 700
  FxZ = 900
  WashZ = 1200

  SparkleTicks* = 6
  FadeTicks* = 8
  SplashTicks* = 6
  DesatTicks* = 24

type
  BoardBody* = object
    x*, y*, energy*: int

  BoardFrame* = object
    tick*: int
    fieldW*, fieldH*: int
    bodies*: array[3, seq[BoardBody]]

  FxKind* = enum
    fkSparkle, fkFade, fkSplash

  FxItem* = object
    kind*: FxKind
    speciesIndex*: int
    x*, y*, px*, py*, age*: int

  GlobalViewerState* = object
    initialized*: bool
    objectIds*: seq[int]
    ## transport, driven by the chrome's command channel
    playing*: bool
    speed*: int
    looping*: bool
    replaySeekTick*: int
    stepBack*: bool
    skipForward*: bool
    jumpEnd*: bool
    restart*: bool

proc initGlobalViewerState*(): GlobalViewerState =
  ## Looping starts OFF: a replay that reaches its last tick HOLDS there, so
  ## the end-card is the last thing on screen and a scrub to 100% reads the
  ## final generation rather than whatever the restart happened to be showing.
  ## The chrome's loop button turns it on.
  GlobalViewerState(
    playing: true,
    speed: 1,
    looping: false,
    replaySeekTick: -1
  )

proc boardRenderScaleFor*(fieldW, fieldH: int): int =
  ## Ecos draws its field 1:1 — a world unit is a board pixel. Kept as a
  ## function (and reported to the chrome as `bs`) because every viewer
  ## control converts board pixels to world units through it.
  discard fieldW
  discard fieldH
  1

proc applyGlobalViewerMessage*(state: var GlobalViewerState, message: string) =
  ## Applies the chrome's transport commands. Whole-string commands are
  ## intercepted before the single-character ones, so a multi-digit tick is
  ## never mangled into speed keystrokes.
  for item in message.parseSpriteClientMessages():
    if item.kind != SpriteClientChatMessage:
      continue
    let text = item.text
    if text.startsWith("s:"):
      let tick = try: parseInt(text[2 .. ^1]) except ValueError: -1
      if tick >= 0:
        state.replaySeekTick = tick
      continue
    if text.startsWith("v:"):
      continue          ## Ecos has no POV lens: a seat is a species.
    for command in text:
      case command
      of ' ': state.playing = not state.playing
      of ',': state.restart = true
      of 'b': state.stepBack = true
      of '.': state.skipForward = true
      of 'e': state.jumpEnd = true
      of 'r': state.looping = not state.looping
      of '1': state.speed = 1
      of '2': state.speed = 2
      of '3': state.speed = 3
      of '4': state.speed = 4
      of '8': state.speed = 8
      of '6': state.speed = 16
      of '+': state.speed = min(16, state.speed * 2)
      of '-': state.speed = max(1, state.speed div 2)
      else: discard

# ---- art ---------------------------------------------------------------------

const
  SoilPng = [
    staticRead("../../data/art/soil_0.png"),
    staticRead("../../data/art/soil_1.png"),
    staticRead("../../data/art/soil_2.png"),
    staticRead("../../data/art/soil_3.png")
  ]
  TuftPng = [
    staticRead("../../data/art/tuft_1.png"),
    staticRead("../../data/art/tuft_2.png"),
    staticRead("../../data/art/tuft_3.png"),
    staticRead("../../data/art/tuft_4.png")
  ]
  GrazerPng = [
    staticRead("../../data/art/grazer_idle.png"),
    staticRead("../../data/art/grazer_run.png")
  ]
  PredatorPng = [
    staticRead("../../data/art/predator_idle.png"),
    staticRead("../../data/art/predator_run.png")
  ]
  SparklePng = staticRead("../../data/art/sparkle.png")
  SplashPng = staticRead("../../data/art/splash.png")

type BakedSprite = object
  width, height: int
  pixels: seq[uint8]

proc straightRgba(image: Image): seq[uint8] =
  ## Straight-alpha RGBA bytes for the Sprite v1 protocol (pixie stores
  ## premultiplied).
  result = newSeq[uint8](image.width * image.height * 4)
  for i in 0 ..< image.width * image.height:
    let c = image.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc baked(image: Image): BakedSprite =
  BakedSprite(width: image.width, height: image.height,
    pixels: straightRgba(image))

proc tinted(source: BakedSprite, mul, alpha: int): BakedSprite =
  ## `mul` is a per-channel multiplier in percent (a starving body reads dull
  ## before it dies); `alpha` scales the whole sprite for the death fade.
  result.width = source.width
  result.height = source.height
  result.pixels = source.pixels
  for i in countup(0, result.pixels.len - 4, 4):
    for channel in 0 .. 2:
      result.pixels[i + channel] =
        uint8(min(255, int(result.pixels[i + channel]) * mul div 100))
    result.pixels[i + 3] =
      uint8(min(255, int(result.pixels[i + 3]) * alpha div 100))

proc flipped(source: BakedSprite): BakedSprite =
  result.width = source.width
  result.height = source.height
  result.pixels = newSeq[uint8](source.pixels.len)
  for y in 0 ..< source.height:
    for x in 0 ..< source.width:
      let src = (y * source.width + x) * 4
      let dst = (y * source.width + (source.width - 1 - x)) * 4
      for channel in 0 .. 3:
        result.pixels[dst + channel] = source.pixels[src + channel]

proc solid(width, height: int, r, g, b, a: uint8): BakedSprite =
  result.width = width
  result.height = height
  result.pixels = newSeq[uint8](width * height * 4)
  for i in countup(0, result.pixels.len - 4, 4):
    result.pixels[i] = r
    result.pixels[i + 1] = g
    result.pixels[i + 2] = b
    result.pixels[i + 3] = a

var spriteCache: Table[int, BakedSprite]

proc bodySpriteId*(speciesIndex, pose, flip, tint: int): int =
  let base = if speciesIndex == 1: GrazerSpriteBase else: PredatorSpriteBase
  base + pose * (2 * EnergyTints) + flip * EnergyTints + tint

proc buildSpriteCache() =
  if spriteCache.len > 0:
    return
  for i in 0 ..< SoilVariants:
    spriteCache[SoilSpriteBase + i] = baked(decodeImage(SoilPng[i]))
  for stage in 0 ..< WashStages:
    ## The silent-spring wash: a grey tile crossfaded over the whole board.
    ## Cosmetic only — it never touches a sim quantity.
    spriteCache[WashSpriteBase + stage] =
      solid(SoilTile, SoilTile, 118'u8, 120'u8, 112'u8,
        uint8(18 + stage * 22))
  for stage in 0 ..< 4:
    spriteCache[TuftSpriteBase + stage] = baked(decodeImage(TuftPng[stage]))
  for speciesIndex in 1 .. 2:
    for pose in 0 .. 1:
      let source = baked(decodeImage(
        if speciesIndex == 1: GrazerPng[pose] else: PredatorPng[pose]))
      for flip in 0 .. 1:
        let oriented = if flip == 1: flipped(source) else: source
        for tint in 0 ..< EnergyTints:
          spriteCache[bodySpriteId(speciesIndex, pose, flip, tint)] =
            tinted(oriented, 100 - tint * 22, 100)
  let sparkle = baked(decodeImage(SparklePng))
  for stage in 0 ..< 3:
    spriteCache[SparkleSpriteBase + stage] =
      tinted(sparkle, 100, 100 - stage * 30)
  let splash = baked(decodeImage(SplashPng))
  for stage in 0 ..< 3:
    spriteCache[SplashSpriteBase + stage] =
      tinted(splash, 100, 100 - stage * 30)
  for speciesIndex in 0 .. 2:
    let source =
      if speciesIndex == 0: spriteCache[TuftSpriteBase + 1]
      else: spriteCache[bodySpriteId(speciesIndex, 0, 0, 0)]
    for stage in 0 ..< 3:
      spriteCache[FadeSpriteBase + speciesIndex * 3 + stage] =
        tinted(source, 100, 60 - stage * 20)

proc spriteFor*(id: int): BakedSprite =
  buildSpriteCache()
  spriteCache[id]

# ---- packet building ---------------------------------------------------------

proc addBaked(packet: var seq[uint8], id: int, label: string) =
  let sprite = spriteFor(id)
  packet.addSprite(id, sprite.width, sprite.height, sprite.pixels, label)

proc soilObjectCount(fieldW, fieldH: int): int =
  let cols = (fieldW + SoilTile - 1) div SoilTile
  let rows = (fieldH + SoilTile - 1) div SoilTile
  cols * rows

proc addInit(packet: var seq[uint8], fieldW, fieldH: int) =
  ## Layer, viewport, every sprite definition and the static soil bake. Sent
  ## once; the soil objects are never tracked in `objectIds`, so the per-frame
  ## delete diff leaves them on the client forever.
  packet.addU8(SpriteMessageClearObjects)
  packet.addLayer(MapLayerId, MapLayerKind, ZoomableFlag)
  packet.addViewport(MapLayerId, fieldW, fieldH)
  buildSpriteCache()
  for i in 0 ..< SoilVariants:
    packet.addBaked(SoilSpriteBase + i, "soil " & $i)
  for stage in 0 ..< WashStages:
    packet.addBaked(WashSpriteBase + stage, "wash " & $stage)
  for stage in 0 ..< 4:
    packet.addBaked(TuftSpriteBase + stage, "tuft " & $(stage + 1))
  for speciesIndex in 1 .. 2:
    for pose in 0 .. 1:
      for flip in 0 .. 1:
        for tint in 0 ..< EnergyTints:
          packet.addBaked(bodySpriteId(speciesIndex, pose, flip, tint),
            RoleNames[Species(speciesIndex)])
  for stage in 0 ..< 3:
    packet.addBaked(SparkleSpriteBase + stage, "sparkle")
    packet.addBaked(SplashSpriteBase + stage, "splash")
  for speciesIndex in 0 .. 2:
    for stage in 0 ..< 3:
      packet.addBaked(FadeSpriteBase + speciesIndex * 3 + stage, "fade")
  let cols = (fieldW + SoilTile - 1) div SoilTile
  let rows = (fieldH + SoilTile - 1) div SoilTile
  for row in 0 ..< rows:
    for col in 0 ..< cols:
      let index = row * cols + col
      packet.addObject(SoilObjectBase + index, col * SoilTile, row * SoilTile,
        SoilZ, MapLayerId, SoilSpriteBase + ((col * 3 + row * 5) mod SoilVariants))

proc tuftStage(energy: int): int =
  clampInt(energy * 4 div max(1, GrassEMax + 1), 0, 3)

proc energyTint(energy, ceiling: int): int =
  ## 0 = healthy, 2 = starving. A dull field reads as trouble before the
  ## first body dies.
  let ratio = energy * 100 div max(1, ceiling)
  if ratio >= 45: 0 elif ratio >= 20: 1 else: 2

proc buildBoardPacket*(
  view: var GlobalViewerState,
  frame: BoardFrame,
  fx: seq[FxItem],
  desatStage: int,
  chrome: string
): seq[uint8] =
  ## One wire frame: the sprite/soil init on the first call, then the live
  ## body objects, the fx pool, the silent-spring wash and the chrome label.
  result = @[]
  if not view.initialized:
    view.initialized = true
    result.addInit(frame.fieldW, frame.fieldH)
  var live: seq[int]

  for speciesIndex in 0 .. 2:
    let bodies = frame.bodies[speciesIndex]
    let base =
      case speciesIndex
      of 0: GrassObjectBase
      of 1: GrazerObjectBase
      else: PredatorObjectBase
    let z =
      case speciesIndex
      of 0: GrassZ
      of 1: GrazerZ
      else: PredatorZ
    let limit =
      case speciesIndex
      of 0: GrazerObjectBase - GrassObjectBase
      of 1: PredatorObjectBase - GrazerObjectBase
      else: FxObjectBase - PredatorObjectBase
    for index in 0 ..< min(bodies.len, limit):
      let body = bodies[index]
      var spriteId: int
      var half: int
      if speciesIndex == 0:
        let stage = tuftStage(body.energy)
        spriteId = TuftSpriteBase + stage
        half = (24 + stage * 8) div 2
      else:
        let ceiling = SpeciesEMax[Species(speciesIndex)]
        let pose = if (frame.tick div 4 + index) mod 2 == 0: 0 else: 1
        let flip = if (index * 7 + body.x) mod 2 == 0: 0 else: 1
        spriteId = bodySpriteId(speciesIndex, pose, flip,
          energyTint(body.energy, ceiling))
        half = (if speciesIndex == 1: 14 else: 20)
      let objectId = base + index
      live.add(objectId)
      result.addObject(objectId, body.x - half, body.y - half, z,
        MapLayerId, spriteId)

  var fxSlot = 0
  for item in fx:
    if fxSlot >= MaxFxObjects: break
    let objectId = FxObjectBase + fxSlot
    inc fxSlot
    live.add(objectId)
    case item.kind
    of fkSparkle:
      let stage = clampInt(item.age * 3 div max(1, SparkleTicks), 0, 2)
      result.addObject(objectId, item.x - 8, item.y - 8, FxZ, MapLayerId,
        SparkleSpriteBase + stage)
    of fkSplash:
      let stage = clampInt(item.age * 3 div max(1, SplashTicks), 0, 2)
      result.addObject(objectId, item.x - 10, item.y - 10, FxZ, MapLayerId,
        SplashSpriteBase + stage)
    of fkFade:
      let stage = clampInt(item.age * 3 div max(1, FadeTicks), 0, 2)
      let half = (if item.speciesIndex == 0: 16
                  elif item.speciesIndex == 1: 14 else: 20)
      result.addObject(objectId, item.x - half, item.y - half, FxZ - 1,
        MapLayerId, FadeSpriteBase + item.speciesIndex * 3 + stage)

  if desatStage > 0:
    let cols = (frame.fieldW + SoilTile - 1) div SoilTile
    let rows = (frame.fieldH + SoilTile - 1) div SoilTile
    let stage = clampInt(desatStage - 1, 0, WashStages - 1)
    for row in 0 ..< rows:
      for col in 0 ..< cols:
        let objectId = WashObjectBase + row * cols + col
        live.add(objectId)
        result.addObject(objectId, col * SoilTile, row * SoilTile, WashZ,
          MapLayerId, WashSpriteBase + stage)

  var liveSet = initTable[int, bool]()
  for id in live:
    liveSet[id] = true
  for id in view.objectIds:
    if not liveSet.hasKey(id):
      result.addDeleteObject(id)
  view.objectIds = live

  ## The chrome frame rides as the label of the reserved 1x1 sprite. Never a
  ## drawable: `broadcast_core.js` routes it straight to `onText`.
  if chrome.len > 0 and chrome.len < 65535:
    result.addSprite(BroadcastChromeSpriteId, 1, 1,
      [0'u8, 0'u8, 0'u8, 0'u8], chrome)

proc chunkSpritePacket*(packet: seq[uint8], maxBytes: int): seq[seq[uint8]] =
  ## Splits one wire frame on message boundaries so no websocket frame
  ## approaches the hosted 1 MiB cap. The static replay bundle hands the
  ## whole packet to the core in memory and never needs this.
  var current: seq[uint8]
  var offset = 0
  while offset < packet.len:
    let size = spriteMessageBytes(packet, offset)
    if size <= 0: break
    if current.len > 0 and current.len + size > maxBytes:
      result.add(current)
      current = @[]
    for i in 0 ..< size:
      current.add(packet[offset + i])
    offset += size
  if current.len > 0:
    result.add(current)

# ---- fx extraction -----------------------------------------------------------

proc desaturationStage*(alarmTicks: int): int =
  ## 0 = full colour, WashStages = the full silent-spring wash. The crossfade
  ## runs over DesatTicks either way.
  clampInt(alarmTicks * WashStages div max(1, DesatTicks), 0, WashStages)

proc collectFx*(events: seq[JsonNode], tick: int): seq[FxItem] =
  ## Births sparkle for 6 ticks, deaths fade over 8, a predation death also
  ## throws a short red splash.
  for event in events:
    let t = event{"t"}.getInt(-1)
    if t > tick: break
    let age = tick - t
    case event{"k"}.getStr()
    of "birth":
      if age < SparkleTicks:
        result.add(FxItem(kind: fkSparkle, x: event{"x"}.getInt(),
          y: event{"y"}.getInt(), px: event{"px"}.getInt(),
          py: event{"py"}.getInt(), age: age))
    of "starve":
      if age < FadeTicks:
        let name = event{"sp"}.getStr("grass")
        result.add(FxItem(kind: fkFade,
          speciesIndex: ord(speciesFromName(name)),
          x: event{"x"}.getInt(), y: event{"y"}.getInt(), age: age))
    of "predation":
      if age < SplashTicks:
        result.add(FxItem(kind: fkSplash, x: event{"x"}.getInt(),
          y: event{"y"}.getInt(), age: age))
      if age < FadeTicks:
        result.add(FxItem(kind: fkFade, speciesIndex: 1,
          x: event{"x"}.getInt(), y: event{"y"}.getInt(), age: age))
    else:
      discard

const WireConstantsJs* =
  "window.CTF_WIRE={speeds:[" & $PlaybackSpeeds[0] & "," & $PlaybackSpeeds[1] &
  "," & $PlaybackSpeeds[2] & "," & $PlaybackSpeeds[3] & "," &
  $PlaybackSpeeds[4] & "," & $PlaybackSpeeds[5] & "]" &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",shotFxTicks:0,shotTrailFalloff:1.6};"
  ## The handful of engine constants the browser chrome must agree with,
  ## rendered ONCE from the Nim consts the engine runs on.

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"

proc spliceWireConstants*(page: string): string =
  page.replace(WireConstantsMarker, "<script>" & WireConstantsJs & "</script>")
