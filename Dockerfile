# Build Docker. Two stages, the paintbot nimby recipe: the build stage pins
# the same Nim and the same nimby.lock the CI test job uses, so a green test
# job means the image's compiler and package tree agree.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/ecos
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
# The committed nim.cfg (if any) pins the author's machine; rebuild it from
# this image's package tree, exactly as ci.yml does.
RUN rm -f nim.cfg && \
  for pkg in /root/.nimby/pkgs/*; do \
    if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg; \
    else echo "--path:\"$pkg\"" >> nim.cfg; fi; \
  done && \
  echo '--path:"src"' >> nim.cfg

ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
RUN nim c $NimFlags --nimcache:/tmp/ecos-nimcache --out:ecos src/ecos.nim && \
    nim c $NimFlags --nimcache:/tmp/ecos-player-nimcache --out:ecos-player \
      src/ecos_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/ecos
COPY --from=build /workspace/ecos/ecos /bin/ecos
COPY --from=build /workspace/ecos/ecos-player /bin/ecos-player
COPY --from=build /workspace/ecos/data ./data
COPY --from=build /workspace/ecos/client ./client

CMD ["/bin/ecos"]
