## Export complete certified Ecos episodes as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import ecos/[events, llm, scripted, sim, sim_config, sim_types]

const OperatorPrompt = "Keep all three species alive while maximizing your integrated biomass score."
const Variants = ["standard", "harsh-spring"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT [PROMPT_VARIANT PROMPT_SEED]]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: Variants[0]
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit source before generating a pinned corpus"
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var wording = selection
    if wording.variant == pvMixed: wording.seed += seed - firstSeed
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = %*["t0", "t1", "t2"]
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    let sim = newSim(config)
    var rows: seq[string]
    while not sim.done:
      var messages: array[Species, tuple[system, user: string]]
      for species in Species:
        messages[species] = playerPrompts(sim.observationJson(sim.seatOf[species]),
          OperatorPrompt, wording)
      for species in Species:
        let teacher = scriptedDoctrineChecked(sim, species, skSteward)
        var fields = newJObject()
        for i in 0 .. 3:
          fields[DoctrineFieldNames[species][i]] = %teacher.fields[i]
        let completion = %*{
          "doctrine": fields,
          "say": "",
          "notes": ""
        }
        let parsed = parseDecision(species, completion)
        doAssert parsed.fields == teacher.fields and not parsed.clamped
        rows.add($(%*{
          "episode_id": "ecos-" & variant & "-" & $seed,
          "seed": "ecos-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": messages[species].system},
            {"role": "user", "content": messages[species].user}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "ecos",
          "prompt_template": wording.promptMetadata(messages[species].system, messages[species].user),
          "action_schema_revision": "ecos-doctrine-v1"
        }))
        sim.applyDoctrine(species, parsed.fields, dsScripted,
          teacher.clamped, parsed.say, parsed.notes, 0)
      sim.runGeneration()
    doAssert sim.reason == "complete"
    let outcome = sim.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"],
      "generations_played": sim.generationsPlayed,
      "prompt_selection": wording.selectionMetadata()})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "ecos",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-steward",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
