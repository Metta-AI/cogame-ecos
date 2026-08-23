import std/os
import ecos/[sim, sim_types, sim_config, scripted, events, replays]
when isMainModule:
  var config = defaultGameConfig()
  config.seed = 7
  config.roleOffset = 0
  config.tokens = @["a","b","c"]
  config.players = @[PlayerConfig(name:"ecos-keeper"), PlayerConfig(name:"ecos-steward"), PlayerConfig(name:"ecos-bloom")]
  var s = newSim(config)
  while not s.done:
    for sp in Species:
      s.applyDoctrine(sp, scriptedDoctrine(s, sp, skSteward), dsScripted, false,
        (if sp == spPredators: "thin the herd" else: ""), "", 0)
    s.runGeneration()
  writeFile(paramStr(1), replayBytes(s, s.resultsJson()))
  echo "wrote ", paramStr(1), " ending=", s.ending
