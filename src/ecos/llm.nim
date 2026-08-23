## Claude-backed decision making for Ecos. A policy is just a prompt: the
## GAME composes each seat's observation plus that seat's `PLAYER_PROMPT`
## and asks Claude for the next generation's doctrine.
##
## Forked from `cogame-bullwhip/src/bullwhip/llm.nim`. Decisions within a
## generation are simultaneous by rule, so all three seats' requests go out
## as ONE parallel batch (`curly.makeRequests`); an invalid reply is retried
## once in the next batch with a hint, and anything still failing falls back
## to the `steward` scripted doctrine. `decideAll` never raises — the episode
## always advances.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With none, the client disables itself immediately and every seat plays
## `steward`, which is what keeps offline certification green.

import std/[json, math, os, strutils, times, unicode]
import bitworld/runtime
import curly
import sim_types, sim, sim_config, sim_state, scripted, events

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  Decision* = object
    fields*: Doctrine
    clamped*: bool
    say*: string
    notes*: string
    source*: DoctrineSource
    latencyMs*: int

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    logLine("ecos llm: failed to fetch ANTHROPIC_API_KEY_URI: " & error.msg)
    result = ""

proc bedrockModelIds*(): seq[string] =
  ## Haiku only. The sonnet fallbacks time out on every sidecar call and turn
  ## one throttle into a cascade (LEARNINGS 2026-08-23 raid, item 4).
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    logLine("ecos llm: bedrock transport, url " & result.bedrockUrl)
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    logLine("ecos llm: anthropic transport, model " & result.model)
  else:
    result.transport = ltNone
    result.disabled = true
    logLine("ecos llm: no LLM credentials; every seat plays the steward baseline")

# ---- text hygiene ------------------------------------------------------------

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

# ---- prompts -----------------------------------------------------------------

proc doctrineSpec(species: Species): string =
  var parts: seq[string]
  for i in 0 .. 3:
    parts.add(DoctrineFieldNames[species][i] & " (" &
      $DoctrineMin[species][i] & ".." & $DoctrineMax[species][i] &
      ", default " & $StewardDoctrine[species][i] & ")")
  parts.join(", ")

proc kernelText(species: Species): string =
  case species
  of spGrass:
    """You are GRASS, the producer. Every tick each tuft gains
(5 - the number of other tufts within 55 units) energy, at least 0, and pays
1 to metabolism; energy is capped at 200. A tuft with energy >= seed_threshold
throws a seedling seed_range units away on a random heading: if crowd_limit is
above 0 and that spot already has crowd_limit tufts within 55 units the seed
fails and the parent loses 10; otherwise the parent pays seed_cost + 10 and a
new tuft is born with seed_cost energy. Your population cap is 220. Nothing
eats you but the GRAZERS, who bite energy straight out of your tufts."""
  of spGrazers:
    """You are GRAZERS, the herbivores. Every tick a grazer within 16 units of
a tuft eats: it takes `bite` energy from that tuft and keeps 80% of it. A
grazer with a predator nearer than flee_range sprints away at 9 units per tick
(11 when four or more grazers are close - many eyes) and pays 2 metabolism;
otherwise it walks at 6 toward food, steering `herd` percent of the way toward
the local herd centroid, and pays 1. Crowding costs up to 2 more per tick.
Energy is capped at 260; at birth_threshold a grazer splits, both halves
keeping (energy - 20) / 2. Your population cap is 140. You eat GRASS and the
PREDATORS eat you."""
  of spPredators:
    """You are PREDATORS, the carnivores. A predator above rest_energy idles and
pays 1 per tick. Below it, it locks onto the nearest grazer within hunt_range
and chases at 12 units per tick for 3 per tick, steering `spread` percent away
from the nearest other predator; with no grazer in range it roams at 7 for 2
per tick. Within 16 units, and only once every 12 ticks, it kills: it gains
min(""" & $KillCap & ", " & $KillBase & """ + the grazer's energy), capped at
480 total. At birth_threshold it splits, both halves keeping (energy - 20) / 2.
Your population cap is 30. You eat GRAZERS, who eat GRASS. Nothing eats you."""

proc systemPrompt*(sim: SimServer, slot: int): string =
  let species = sim.roleOf[slot]
  result.add("You are " & sim.names[slot].toUpperAscii() & ", the " &
    RoleNames[species].toUpperAscii() & " of one ecosystem. You are a SPECIES, " &
    "not an individual: you may have one body alive or two hundred, and every " &
    "one of them runs the same kernel.\n\n")
  result.add(kernelText(species) & "\n\n")
  result.add("ONCE PER GENERATION you submit a DOCTRINE: four whole numbers " &
    "that reparameterise that kernel for the next 60 ticks. Your fields are: " &
    doctrineSpec(species) & ".\n\n")
  result.add("""SCORING. Your instantaneous biomass is the total energy of your
living bodies. For each generation g, G(g) = (the sum of your biomass over that
generation's ticks) / (ticks per generation x your reference biomass). Your
score is the sum over all ten generations of min(G(g), 2.0) - so a generation
spent at twice your reference pays no more than two generations spent at
reference, and a boom that risks a crash never pays more than steady abundance
that does not. HIGHER IS BETTER.

THE EPISODE ENDS THE MOMENT ANY SPECIES' POPULATION REACHES ZERO, AND EVERY
REMAINING GENERATION THEN SCORES ZERO FOR ALL THREE SEATS - including you.
Energy only flows up the chain, so a level that strips the level below it
starves about one generation later.

""")
  result.add("The other two seats are run by other cogs, deciding at the same " &
    "moment you are. Nothing you write is read by them; there is no channel " &
    "between you.\n\n")
  result.add("""OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no
analysis, no explanation, no markdown fences, no text before or after the
object. Your reply must begin with the character { and end with }.""")

proc historyTable(sim: SimServer): string =
  var lines: seq[string]
  lines.add("gen | grass n/B | grazers n/B | predators n/B | births | " &
    "starved | eaten | your score")
  let mine = ord(sim.roleOf[0])
  discard mine
  for index, row in sim.history:
    lines.add($(index + 1) & " | " &
      $row.pop[0] & "/" & $row.bio[0] & " | " &
      $row.pop[1] & "/" & $row.bio[1] & " | " &
      $row.pop[2] & "/" & $row.bio[2] & " | " &
      $row.births[0] & "," & $row.births[1] & "," & $row.births[2] & " | " &
      $row.starved[0] & "," & $row.starved[1] & "," & $row.starved[2] & " | " &
      $row.eaten & " | " & formatFloat(row.score[0], ffDecimal, 2) & "," &
      formatFloat(row.score[1], ffDecimal, 2) & "," &
      formatFloat(row.score[2], ffDecimal, 2))
  if sim.history.len == 0:
    lines.add("(no generation has been played yet)")
  lines.join("\n")

proc densityText(sim: SimServer, species: Species): string =
  let cells = sim.densityGrid(species)
  var lines: seq[string]
  for row in 0 ..< DensityRows:
    var parts: seq[string]
    for col in 0 ..< DensityCols:
      parts.add(align($cells[row * DensityCols + col], 3))
    lines.add(parts.join(" "))
  lines.join("\n")

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc userPrompt*(sim: SimServer, slot: int, prompt: string): string =
  let species = sim.roleOf[slot]
  result.add("Generation " & $sim.generation & " of " &
    $sim.config.generations & ", tick " & $sim.tick & " of " &
    $(sim.config.generations * sim.config.ticksPerGeneration) &
    ". You are the " & RoleNames[species].toUpperAscii() & ".\n\n")
  result.add("YOU RIGHT NOW: population " & $sim.population(species) &
    " of a cap of " & $sim.capOf(species) &
    ", biomass " & $sim.biomass(species) &
    " against a reference of " & $ReferenceBiomass[species] &
    ", mean body energy " & $sim.meanEnergy(species) &
    ", mean crowding " & $sim.meanCrowd(species) &
    ", score so far " & formatFloat(sim.scores[species], ffDecimal, 2) & ".\n")
  result.add("YOUR DOCTRINE IN FORCE: ")
  var current: seq[string]
  for i in 0 .. 3:
    current.add(DoctrineFieldNames[species][i] & "=" &
      $sim.doctrine[species][i])
  result.add(current.join(", ") & "\n\n")
  result.add("THE WHOLE FIELD:\n")
  for other in Species:
    result.add("  " & RoleNames[other] & " (" &
      sim.names[sim.seatOf[other]] & "): population " &
      $sim.population(other) & "/" & $sim.capOf(other) & ", biomass " &
      $sim.biomass(other) & "/" & $ReferenceBiomass[other] & "\n")
  result.add("\nHISTORY:\n" & sim.historyTable() & "\n\n")
  result.add("DENSITY GRIDS (" & $DensityCols & " columns x " &
    $DensityRows & " rows over the whole field):\n")
  for other in Species:
    result.add(RoleNames[other] & ":\n" & sim.densityText(other) & "\n")
  result.add("\nYOUR NOTES FROM LAST GENERATION:\n" &
    (if sim.notes[slot].len > 0: sim.notes[slot] else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  var shape: seq[string]
  for i in 0 .. 3:
    shape.add("\"" & DoctrineFieldNames[species][i] & "\": <" &
      $DoctrineMin[species][i] & ".." & $DoctrineMax[species][i] & ">")
  result.add("Reply with ONLY {\"doctrine\": {" & shape.join(", ") &
    "}, \"say\": \"…\", \"notes\": \"…\"} — every doctrine value a whole " &
    "number in range; say at most " & $MaxSayLen & " characters; notes at " &
    "most " & $MaxNotesLen & " characters.")

# ---- transport ---------------------------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences
  ## and prose prefixes.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    var head = text.strip()
    if head.len > 160:
      head = head[0 ..< 160] & "..."
    raise newException(EcosError,
      "no JSON object in response: " & head.replace("\n", " "))
  parseJson(text[start .. stop])

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Haiku 4.5 rejects the whole request with a 400 when
    ## `output_config.effort` is present.
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc newLlmClientFor*(config: GameConfig, apiKey: string): LlmClient =
  ## Explicit-key constructor. `newLlmClient` reads the environment; this one
  ## is what `tests/test_llm.nim` uses to exercise the batch shape and the
  ## reply parser without credentials anywhere near the runner.
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds,
    apiKey: apiKey,
    transport: (if apiKey.len > 0: ltAnthropic else: ltNone),
    disabled: apiKey.len == 0
  )

proc textOf*(client: LlmClient, response: Response, error, url: string): string =
  if error.len > 0:
    raise newException(EcosError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    client.disabled = true
    raise newException(EcosError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    raise newException(EcosError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(EcosError, "llm error " & $response.code & ": " &
      response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(EcosError, "llm refusal")
  for contentBlock in payload{"content"}:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(EcosError, "reply cut off at max_tokens before any " &
      "JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

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

proc openSeatsOf*(client: LlmClient, seats: seq[int],
    scriptedKinds: seq[ScriptKind]): seq[int] =
  ## Indexes into `seats` that still need a model call this generation.
  for index, slot in seats:
    if scriptedKinds[slot] == skNone and not client.disabled:
      result.add(index)

proc requestBatchFor*(
  client: LlmClient,
  sim: SimServer,
  seats: seq[int],
  open: seq[int],
  prompts: seq[string],
  attempt: int
): RequestBatch =
  ## ONE batch carrying every still-open seat. Decisions within a generation
  ## are simultaneous by rule, so they go out together (curly.makeRequests) —
  ## sequential calls blow the 720 s play budget.
  for index in open:
    let slot = seats[index]
    var user = sim.userPrompt(slot, prompts[slot])
    if attempt > 0:
      user.add("\n\nYour previous reply was invalid. Respond with ONLY the " &
        "requested JSON object, with all four doctrine fields as whole " &
        "numbers in range.")
    let request = client.requestFor(sim.systemPrompt(slot), user)
    result.post(request.url, request.headers, request.body, $index)

proc decisionFrom*(client: LlmClient, species: Species, response: Response,
    error, url: string): Decision =
  ## One reply, parsed tolerantly. Raises EcosError on anything unusable —
  ## which is what puts the seat back in the retry batch.
  parseDecision(species, extractJsonObject(
    client.textOf(response, error, url)))

proc scriptedDecision*(sim: SimServer, species: Species,
    kind: ScriptKind): Decision =
  Decision(
    fields: scriptedDoctrine(sim, species, kind),
    source: (if kind == skNone: dsFallback else: dsScripted)
  )

proc decideAll*(
  client: LlmClient,
  sim: SimServer,
  seats: seq[int],
  prompts: seq[string],
  scriptedKinds: seq[ScriptKind]
): seq[Decision] =
  ## One decision per seat in `seats`, in order. ONE parallel batch per
  ## generation; a failing seat is retried once in the next batch with a hint
  ## and then falls back to the steward doctrine. Never raises.
  result = newSeq[Decision](seats.len)
  var open = client.openSeatsOf(seats, scriptedKinds)
  var isOpen = newSeq[bool](seats.len)
  for index in open:
    isOpen[index] = true
  for index, slot in seats:
    if isOpen[index]:
      continue
    let kind = scriptedKinds[slot]
    result[index] = scriptedDecision(sim, sim.roleOf[slot], kind)
    if kind == skNone:
      result[index].source = dsFallback
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    let batch = client.requestBatchFor(sim, seats, open, prompts, attempt)
    let started = epochTime()
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    let latency = int((epochTime() - started) * 1000.0)
    var stillOpen: seq[int]
    for position, index in open:
      let slot = seats[index]
      try:
        var decision = client.decisionFrom(sim.roleOf[slot],
          responses[position].response, responses[position].error,
          batch[position].url)
        decision.source = (if attempt == 0: dsLlm else: dsRetry)
        decision.latencyMs = latency
        result[index] = decision
      except CatchableError as error:
        logLine("ecos llm: seat " & $slot & " attempt " & $attempt &
          " failed: " & error.msg)
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let slot = seats[index]
    logLine("ecos llm: seat " & $slot & " falling back to scripted doctrine")
    result[index] = scriptedDecision(sim, sim.roleOf[slot], skSteward)
    result[index].source = dsFallback
