## Ecos sim substrate: the seeded integer RNG, the brad trigonometry table,
## the integer geometry helpers, the running game hash and the log line
## helper.
##
## Forked from paintbot's `src/ctf/sim_state.nim`. Nothing in here touches a
## float: a seed reproduces a replay bit-exactly on any host, which is what
## `tests/test_sim.nim`'s determinism case asserts.

import std/[math, strutils]
import sim_types

const
  Brads* = 256
  UnitScale* = 1024
    ## Fixed-point one. Direction vectors are (dx, dy) scaled to this.

type
  EcosRng* = object
    ## xorshift64*, seeded. Small, fast, and identical on every platform
    ## because every operation is on a uint64 with wrapping arithmetic.
    state*: uint64

proc initRng*(seed: int): EcosRng =
  ## Zero is a fixed point of xorshift, so fold in a nonzero constant.
  result.state = uint64(seed) * 0x9E3779B97F4A7C15'u64 + 0xDEADBEEFCAFEBABE'u64
  if result.state == 0:
    result.state = 0x2545F4914F6CDD1D'u64

proc next*(rng: var EcosRng): uint64 =
  var x = rng.state
  x = x xor (x shr 12)
  x = x xor (x shl 25)
  x = x xor (x shr 27)
  rng.state = x
  x * 0x2545F4914F6CDD1D'u64

proc rand*(rng: var EcosRng, bound: int): int =
  ## Uniform-ish in 0 ..< bound. `bound <= 0` returns 0.
  if bound <= 0: 0
  else: int(rng.next() shr 11) mod bound

proc randBrad*(rng: var EcosRng): int =
  int(rng.next() shr 13) and (Brads - 1)

const SinTable*: array[Brads, int] = block:
  ## 256-entry integer sine table, amplitude UnitScale. Computed at compile
  ## time so no float ever runs at sim time.
  var table: array[Brads, int]
  for i in 0 ..< Brads:
    table[i] = int(round(sin(2.0 * PI * float(i) / float(Brads)) *
      float(UnitScale)))
  table

proc bsin*(brad: int): int {.inline.} = SinTable[brad and (Brads - 1)]
proc bcos*(brad: int): int {.inline.} = SinTable[(brad + 64) and (Brads - 1)]

proc isqrt*(value: int): int =
  ## Integer square root, Newton on integers — deterministic everywhere.
  if value <= 0: return 0
  var x = value
  var y = (x + 1) div 2
  while y < x:
    x = y
    y = (x + value div x) div 2
  x

proc dist2*(ax, ay, bx, by: int): int {.inline.} =
  let dx = ax - bx
  let dy = ay - by
  dx * dx + dy * dy

proc dist*(ax, ay, bx, by: int): int {.inline.} =
  isqrt(dist2(ax, ay, bx, by))

proc unitVec*(dx, dy: int): tuple[x, y: int] =
  ## (dx, dy) rescaled to length UnitScale. A zero vector stays zero.
  let length = isqrt(dx * dx + dy * dy)
  if length == 0:
    return (0, 0)
  ((dx * UnitScale) div length, (dy * UnitScale) div length)

proc bradVec*(brad: int): tuple[x, y: int] {.inline.} =
  (bcos(brad), bsin(brad))

const AtanTable: array[33, int] = block:
  ## brads for `arctan(i / 32)`, i = 0..32 — an eighth-turn ramp. Built at
  ## compile time so NO float ever runs at sim time (a runtime `arctan2` can
  ## differ between the debug and -d:release builds CI runs back to back).
  var table: array[33, int]
  for i in 0 .. 32:
    table[i] = int(round(arctan(float(i) / 32.0) * float(Brads) /
      (2.0 * PI)))
  table

proc bradOf*(dx, dy: int): int =
  ## The brad heading of (dx, dy), integer-only. Zero vector reads as 0.
  if dx == 0 and dy == 0:
    return 0
  let ax = abs(dx)
  let ay = abs(dy)
  var octant: int
  if ax >= ay:
    octant = AtanTable[(ay * 32) div ax]
  else:
    octant = 64 - AtanTable[(ax * 32) div ay]
  if dx >= 0:
    if dy >= 0: octant and (Brads - 1)
    else: (-octant) and (Brads - 1)
  else:
    if dy >= 0: (128 - octant) and (Brads - 1)
    else: (128 + octant) and (Brads - 1)

proc blendVec*(ax, ay, wa, bx, by, wb: int): tuple[x, y: int] =
  ## The weighted integer blend the doctrine kernels use:
  ## `wa * a + wb * b`, renormalised to UnitScale.
  unitVec(ax * wa + bx * wb, ay * wa + by * wb)

proc stepBy*(x, y, ux, uy, speed: int): tuple[x, y: int] =
  ## Advance (x, y) by `speed` world units along the UnitScale unit vector.
  (x + (ux * speed) div UnitScale, y + (uy * speed) div UnitScale)

# ---- running game hash -------------------------------------------------------

type GameHash* = object
  value*: uint64

proc initGameHash*(): GameHash = GameHash(value: 0xCBF29CE484222325'u64)

proc mix*(hash: var GameHash, value: int) {.inline.} =
  ## FNV-1a over the whole integer, so a one-unit position difference at any
  ## tick changes the digest.
  var v = uint64(value)
  for _ in 0 .. 7:
    hash.value = hash.value xor (v and 0xFF'u64)
    hash.value = hash.value * 0x100000001B3'u64
    v = v shr 8

proc mixBody*(hash: var GameHash, body: Body) {.inline.} =
  hash.mix(body.x)
  hash.mix(body.y)
  hash.mix(body.energy)
  hash.mix(body.age)
  hash.mix(body.heading)
  hash.mix(body.cooldown)

proc hex*(hash: GameHash): string =
  toHex(hash.value, 16).toLowerAscii()

# ---- logging -----------------------------------------------------------------

var gameLogLines*: seq[string]

proc logLine*(text: string) =
  ## One line to stdout AND to the episode log artifact. The hosted game log
  ## is the only place a phase-60 verifier can see whether the LLM played.
  echo text
  if gameLogLines.len < 20000:
    gameLogLines.add(text)

proc gameLogText*(): string = gameLogLines.join("\n") & "\n"
