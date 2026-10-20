## Prompt policy transport for Ecos players and trace-format prompts for training.
## Model requests run in the player container over its private observation.
import std/[json, os, strutils]
import bitworld/runtime
import curly
import sim_types, sim_state, decision, prompts
export prompts
export decision

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  EcosThrottleError* = object of EcosError
    ## A 429 from the player sidecar. The player sends a steward fallback
    ## action for this generation and can make a fresh call next generation.

  LlmTransport = enum
    ltNone, ltSidecar, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    sidecarEndpoint: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model: string
    maxOutputTokens: int
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

proc newLlmClient*(maxOutputTokens: int, model: string): LlmClient =
  result = LlmClient(
    model: model,
    maxOutputTokens: maxOutputTokens
  )
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
    result.curl = newCurly()
    return
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

proc requestFor(client: LlmClient, system, user: string, slot: int):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  if client.transport == ltSidecar and slot >= 0:
    headers["X-Coworld-Player-Slot"] = $slot
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  elif client.transport == ltSidecar:
    body["model"] = %client.model
    headers["anthropic-version"] = AnthropicVersion
    result.url = client.sidecarEndpoint & "/v1/messages"
  else:
    body["model"] = %client.model
    ## Haiku 4.5 rejects the whole request with a 400 when
    ## `output_config.effort` is present.
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc newLlmClientFor*(apiKey: string): LlmClient =
  ## Explicit-key constructor for parser and transport tests.
  result = LlmClient(
    model: "claude-haiku-4-5",
    maxOutputTokens: 900,
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
    raise newException(EcosThrottleError, "llm throttled (429): " & detail)
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

proc playerPrompts*(view: JsonNode, prompt: string, selection: PromptSelection):
    tuple[system, user: string] =
  ## Shared by live players and training, using only the private wire view.
  let species = speciesFromName(view["role"].getStr())
  var shape: seq[string]
  for i in 0 .. 3:
    shape.add("\"" & DoctrineFieldNames[species][i] & "\": <" &
      $DoctrineMin[species][i] & ".." & $DoctrineMax[species][i] & ">")
  result.system = selection.introduction(RoleNames[species])
  result.user = "Private observation and visible rules:\n" & $view &
    "\n\nOperator guidance:\n" & prompt &
    "\n\nReturn {\"doctrine\": {" & shape.join(", ") &
    "}, \"say\": \"\", \"notes\": \"\"}."

proc choosePromptDoctrine*(client: LlmClient, view: JsonNode,
    prompt: string, timeoutSeconds: int, selection: PromptSelection): JsonNode =
  let species = speciesFromName(view["role"].getStr())
  let messages = playerPrompts(view, prompt, selection)
  var request = client.requestFor(messages.system, messages.user, -1)
  if client.transport == ltSidecar:
    request.headers["x-coworld-player-slot"] = $view["slot"].getInt()
  let response = client.curl.post(request.url, request.headers, request.body,
    timeoutSeconds)
  let answer = extractJsonObject(client.textOf(response, "", request.url))
  discard parseDecision(species, answer)
  answer
