## Persistent JSONL bridge for the Metta decision training environment.
## Usage: nim c --path:src -o:ecos-train-bridge tools/train_bridge.nim
##        ecos-train-bridge coworld_manifest_template.json [standard|harsh-spring]

import std/[json, os]
import ecos/[events, llm, scripted, sim, sim_config, sim_types]

const OperatorPrompt = "Keep all three species alive while maximizing your integrated biomass score."

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc decision(sim: SimServer, slot, id: int, selection: PromptSelection, textMode: bool): JsonNode =
  let state = sim.observationJson(slot)
  let messages = playerPrompts(state, OperatorPrompt, selection)
  result = %*{
    "kind": "decision",
    "game": "ecos",
    "decision_id": id,
    "seat": slot,
    "engine_seat": slot,
    "turn": sim.generation,
    "semantic_view": state,
    "inbox": [],
    "messages": [
      {"role": "system", "content": messages.system},
      {"role": "user", "content": messages.user}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "required": ["field0", "field1", "field2", "field3"]},
    "typed_question": newJNull()
  }

  if textMode:
    result["semantic_view"]["prompt_template"] = selection.promptMetadata(messages.system, messages.user)
    var fields = newJObject()
    var required = newJArray()
    let species = sim.roleOf[slot]
    for i in 0 .. 3:
      let name = DoctrineFieldNames[species][i]
      required.add(%name)
      fields[name] = %*{"type": "integer", "minimum": DoctrineMin[species][i], "maximum": DoctrineMax[species][i]}
    result["action_schema"] = %*{"type": "object", "required": ["doctrine"],
      "properties": {"doctrine": {"type": "object", "required": required, "properties": fields},
        "say": {"type": "string", "maxLength": MaxSayLen},
        "notes": {"type": "string", "maxLength": MaxNotesLen}}}

proc encoding(sim: SimServer, slot, id: int): JsonNode =
  let state = sim.observationJson(slot)
  let species = sim.roleOf[slot]
  var values = newJArray()
  for role in Species:
    values.add(%(if role == species: 1 else: 0))
  values.add(state["generation"])
  values.add(state["generations"])
  for key in ["population", "biomass", "reference", "scoreSoFar", "meanEnergy", "meanCrowd", "cap"]:
    values.add(state["you"][key])
  for summary in state["species"]:
    for key in ["population", "biomass", "reference", "cap"]:
      values.add(summary[key])
  for role in Species:
    for cell in state["density"][RoleNames[role]]:
      values.add(cell)
  var heads = newJArray()
  for field in 0 .. 3:
    var width = 0
    for role in Species:
      width = max(width, DoctrineMax[role][field] - DoctrineMin[role][field] + 1)
    var choices = newJArray()
    for offset in 0 ..< width:
      let candidate = DoctrineMin[species][field] + offset
      choices.add(if candidate <= DoctrineMax[species][field]: %candidate else: newJNull())
    heads.add(%*{"name": "field" & $field, "choices": choices})
  %*{"decision_id": id, "values": values, "action_heads": heads}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 3:
    quit("usage: ecos-train-bridge MANIFEST [VARIANT [text]]", 1)
  let textMode = args.len == 3
  if textMode: doAssert args[2] == "text"
  let variant = if args.len >= 2: args[1] else: "standard"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var selection: PromptSelection
  var pending: array[3, Decision]
  var game: SimServer
  var slot = 0
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == 3
      selection = if textMode: promptSelection(request) else: PromptSelection()
      let split = if request.hasKey("split"): request["split"].getStr() else: "train"
      doAssert split in ["train", "validation", "test"]
      if split == "train" and selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
        raise newException(ValueError, "held-out wording is evaluation-only")
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = %*["t0", "t1", "t2"]
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      config.update($runtimeConfig)
      game = newSim(config)
      slot = 0
      id = 0
      response = game.decision(slot, id, selection, textMode)
    of "encode":
      doAssert not game.isNil and not game.done
      response = game.encoding(slot, id)
    of "teacher":
      doAssert not game.isNil and not game.done
      let teacher = scriptedDoctrineChecked(game, game.roleOf[slot], skSteward)
      var action = newJObject()
      for field in 0 .. 3:
        action["field" & $field] = %teacher.fields[field]
      if textMode:
        action = %*{"doctrine": doctrineJson(game.roleOf[slot], teacher.fields), "say": "", "notes": ""}
      response = %*{"response": $action}
    of "step":
      doAssert not game.isNil and not game.done
      doAssert request["decision_id"].getInt() == id
      let action = extractJsonObject(request["response"].getStr())
      let species = game.roleOf[slot]
      var payload = action
      if not textMode:
        var fields = newJObject()
        for field in 0 .. 3:
          let value = action["field" & $field].getInt()
          doAssert value in DoctrineMin[species][field] .. DoctrineMax[species][field]
          fields[DoctrineFieldNames[species][field]] = %value
        payload = %*{"doctrine": fields, "say": "", "notes": ""}
      let parsed = parseDecision(species, payload)
      var accepted = action
      if textMode:
        accepted = %*{"doctrine": doctrineJson(species, parsed.fields), "say": parsed.say, "notes": parsed.notes}
        pending[slot] = parsed
      else:
        doAssert not parsed.clamped
        game.applyDoctrine(species, parsed.fields, dsScripted, false, "", "", 0)
      inc slot
      if slot == 3:
        if textMode:
          for seat in 0 .. 2:
            let order = pending[seat]
            game.applyDoctrine(game.roleOf[seat], order.fields, dsScripted,
              order.clamped, order.say, order.notes, 0)
        game.runGeneration()
        slot = 0
      inc id
      var observation: JsonNode
      if game.done:
        var scores = newJObject()
        for seat in 0 .. 2:
          scores[$seat] = game.resultsJson()["scores"][seat]
        observation = %*{"kind": "terminal", "scores": scores}
      else:
        observation = game.decision(slot, id, selection, textMode)
      response = %*{"kind": "accepted", "action": accepted, "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
