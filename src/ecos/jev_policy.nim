## Jev ranks each field of the ordinary Ecos doctrine from one private view.

import std/[json, os, strutils]
import curly
import sim_types

proc jevConfigured*(): bool =
  getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip().len > 0 or
    (getEnv("METTA_CAPTURE_URL").strip().len > 0 and
      getEnv("METTA_CAPTURE_KEY").strip().len > 0) or
    getEnv("TYPESAFE_API_KEY").strip().len > 0

proc bestChoice(answer, criteria: JsonNode): string =
  if answer["type"].getStr() != "choice":
    raise newException(EcosError, "Jev returned a non-choice answer")
  let probabilities = answer["probabilities"]
  if probabilities.len != criteria.len:
    raise newException(EcosError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(EcosError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(EcosError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      result = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(EcosError, "Jev probabilities do not sum to one")

proc fieldChoices(view: JsonNode, species: Species, i: int): JsonNode =
  result = newJObject()
  let name = DoctrineFieldNames[species][i]
  let lo = DoctrineMin[species][i]
  let hi = DoctrineMax[species][i]
  let step = max(1, (hi - lo) div 6)
  for value in countup(lo, hi, step):
    result[$value] = %(name & " = " & $value)
  result[$hi] = %(name & " = " & $hi)
  let current = view["you"]["doctrine"][name].getInt()
  result[$current] = %("Keep current " & name & " = " & $current)

proc chooseJevDoctrine*(decision: JsonNode, timeoutSeconds: int): JsonNode =
  let view = decision["view"]
  let species = speciesFromName(view["role"].getStr())
  var questions = newJObject()
  var choices: array[4, JsonNode]
  for i in 0 .. 3:
    let name = DoctrineFieldNames[species][i]
    choices[i] = fieldChoices(view, species, i)
    questions[name] = %*{
      "type": "choice",
      "instructions": "Choose " & name & " for the next generation.",
      "criteria": choices[i]
    }

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  let endpoint =
    if sidecar.len > 0: sidecar
    elif capture.len > 0: capture
    else: getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
  let model =
    if sidecar.len > 0: "typesafe/jev-1.13"
    elif capture.len > 0: getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    else: getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  let key =
    if sidecar.len > 0: ""
    elif capture.len > 0: getEnv("METTA_CAPTURE_KEY").strip()
    else: getEnv("TYPESAFE_API_KEY").strip()
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $view["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You control one species in Ecos. Choose a legal four-integer " &
      "doctrine for the next generation. Your score is integrated biomass. " &
      "A species collapse ends the episode for all seats. Use only this " &
      "private observation and its visible rules:\n" & $view,
    "questions": questions
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, timeoutSeconds)
  if response.code < 200 or response.code >= 300:
    raise newException(EcosError, "Jev HTTP " & $response.code)
  let answers = parseJson(response.body)["answers"]
  var doctrine = newJObject()
  for i in 0 .. 3:
    let name = DoctrineFieldNames[species][i]
    doctrine[name] = %parseInt(bestChoice(answers[name], choices[i]))
  %*{"doctrine": doctrine, "say": "", "notes": ""}
