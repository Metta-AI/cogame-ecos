## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "ecos-player-v1"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc introduction*(selection: PromptSelection, role: string): string =
  case selection.selectedVariant
  of pvCanonical:
    "You control the " & role & " species in Ecos. Choose its four-integer doctrine for the next generation. Your goal is integrated biomass without collapsing the food chain. Reply with ONLY one JSON object."
  of pvPlain:
    "In Ecos you control the " & role & " species. Pick four integers as its doctrine for the coming generation. Pursue integrated biomass while keeping the food chain from collapsing. Respond with one JSON object only."
  of pvNumbered:
    "1. Control the " & role & " species in Ecos. 2. Choose a doctrine of four integers for the next generation. 3. Aim for integrated biomass without food-chain collapse. 4. Output only one JSON object."
  of pvQuestions:
    "Which species do you control in Ecos? The " & role & ". What must you choose for the next generation? A four-integer doctrine. What is your goal? Integrated biomass without collapsing the food chain. How must you reply? Only one JSON object."
  of pvReordered:
    "Reply with ONLY one JSON object containing the four-integer doctrine for the next generation. In Ecos you control the " & role & " species, pursuing integrated biomass without collapsing the food chain."
  of pvHeldoutBriefing:
    "Ecos briefing: you command the " & role & " species. Set the next generation's doctrine using four integers. Seek integrated biomass while avoiding collapse of the food chain. Submit a single JSON object and nothing else."
  of pvHeldoutReference:
    "Game: Ecos. Controlled species: " & role & ". Decision: four-integer doctrine for the next generation. Objective: integrated biomass without food-chain collapse. Response: one JSON object only."
  of pvMixed: raise newException(ValueError, "mixed selection must resolve to a training wording")
