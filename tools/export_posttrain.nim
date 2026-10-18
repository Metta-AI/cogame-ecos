## Private complete candidates; independent review owns admission to training.
import std/[json, os, osproc, strutils]
import ecos/[llm, scripted, sim, sim_config, sim_types, events, evidence]

const OperatorPrompt = "Keep all three species alive while maximizing your integrated biomass score."

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT [PROMPT_VARIANT PROMPT_SEED]]", 1)
  let output = absolutePath(args[0])
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "standard"
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  doAssert games >= 10 and firstSeed >= 1
  doAssert not dirExists(output) and not fileExists(output)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before generating a pinned candidate corpus"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let revision = head.output.strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject
  writePrivate(output / "trajectories.jsonl", "")
  writePrivate(output / "execution.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  let execution = open(output / "execution.jsonl", fmAppend)
  var runs = newJArray()
  try:
    for seed in firstSeed ..< firstSeed + games:
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = %*["t0", "t1", "t2"]
      runtimeConfig["seed"] = %seed
      config.update($runtimeConfig)
      let world = newSim(config)
      let family = "ecos-" & $seed
      let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
      var count = 0
      while not world.done:
        let generation = world.generation
        var orders: array[3, Decision]
        var records: array[3, JsonNode]
        var ids = newJArray()
        for seat in 0 .. 2:
          let species = world.roleOf[seat]
          var view = world.observationJson(seat)
          let rendered = playerPrompts(view, OperatorPrompt, selection)
          let messages = %*[{"role": "system", "content": rendered.system}, {"role": "user", "content": rendered.user}]
          view["prompt_template"] = selection.promptMetadata(rendered.system, rendered.user)
          let teacher = scriptedDoctrineChecked(world, species, skSteward)
          let proposal = %*{"doctrine": doctrineJson(species, teacher.fields), "say": "", "notes": ""}
          orders[seat] = parseDecision(species, proposal)
          let normalized = %*{"doctrine": doctrineJson(species, orders[seat].fields),
            "say": orders[seat].say, "notes": orders[seat].notes}
          let accepted = proposal == normalized
          let id = count + seat
          ids.add(%($id))
          let attemptId = $id & "-teacher"
          let attempt = %*{
            "attempt_id": attemptId, "policy": "scripted-steward", "origin": "teacher",
            "inference_mode": "text_action", "prompt": messages,
            "response": $proposal, "parsed_action": proposal, "accepted": accepted,
            "request": newJNull(), "platform_call_id": newJNull(), "behavior_logprobs": newJNull(),
            "rejection_reason": (if accepted: newJNull() else: %"engine-normalized-submission")}
          records[seat] = %*{
            "schema_version": "1", "event_type": "decision", "episode_id": episode,
            "decision_id": $id, "decision_index": id,
            "game": "ecos", "game_version": "source-" & revision,
            "source_revision": revision, "seat": $seat, "visibility": "private",
            "observation": view, "prompt": (if accepted: messages else: newJNull()),
            "attempts": [attempt], "selected_attempt_id": (if accepted: %attemptId else: newJNull()),
            "executed_action": normalized, "action_status": (if accepted: "accepted" else: "fallback"),
            "fallback_origin": (if accepted: newJNull() else: %"engine-normalized-submission"),
            "terminal": false}
        var installed = newJArray()
        for seat in 0 .. 2:
          let order = orders[seat]
          let species = world.roleOf[seat]
          world.applyDoctrine(species, order.fields, dsScripted, order.clamped, order.say, order.notes, 0)
          installed.add(eventToJson(world.events[^1]))
          doAssert records[seat]["executed_action"]["doctrine"] == doctrineJson(species, world.doctrine[species])
        let startTick = world.tick
        world.runGeneration()
        records[2]["terminal"] = %world.done
        execution.writeLine($(%*{
          "schema_version": 1, "event_type": "generation_execution", "episode_id": episode,
          "decision_ids": ids, "source_revision": revision, "visibility": "private", "generation": generation,
          "start_tick": startTick, "end_tick": world.tick, "installed_doctrines": installed,
          "frames": executionFrames(world, startTick), "terminal": world.done}))
        for record in records: stream.writeLine($record)
        count += 3
      doAssert world.reason == "complete"
      let outcome = world.resultsJson()
      var participants = newJObject()
      for seat in 0 .. 2: participants[$seat] = %*{"score": outcome["scores"][seat]}
      stream.writeLine($(%*{
        "schema_version": "1", "event_type": "episode", "episode_id": episode,
        "seed_family": family, "game": "ecos", "game_version": "source-" & revision,
        "source_revision": revision, "status": "completed", "outcome": outcome,
        "participant_outcomes": participants}))
      runs.add(%*{"seed": seed, "decisions": count, "scores": outcome["scores"],
        "generations_played": world.generationsPlayed, "ticks": world.tick, "ending": world.ending})
  finally:
    execution.close()
    stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "ecos", "variant": variant,
    "source_revision": revision, "teacher": "scripted-steward",
    "prompt_selection": selection.selectionMetadata(),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "execution_evidence": "execution.jsonl", "runs": runs}) & "\n")
  echo "complete games=", games
