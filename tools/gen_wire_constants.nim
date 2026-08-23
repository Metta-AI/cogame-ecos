## Emits the JS wire-constants block (src/ecos/global.nim) on stdout.
##
## The static replay-viewer bundle cannot run the server's compile-time
## splice, so Dockerfile.replay-viewer runs this to write
## dist/wire_constants.js and injects a <script src> for it into the dist
## page — same constants, same source, different delivery. Historically each
## HTML client re-typed these as literals and nothing enforced agreement.
import ../src/ecos/global

echo WireConstantsJs
