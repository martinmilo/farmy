# The control image: farmy, the docker CLI with compose, git, tmux and the Infisical CLI (providers/infisical). The host needs Docker and nothing
# else; the `farmy` shim builds this image and runs every command in a container made from it, with the
# Docker socket and the containers folder mounted.
# Alpine, like farmy's other helper images: static binaries, small is all that matters (README → Images).
FROM rust:1-alpine AS build
# Ruby renders the release.yml defaults into the shipped shell artifacts at build time.
RUN apk add --no-cache musl-dev ruby
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY VERSION egress-hosts.yml farmy Dockerfile release.Dockerfile README.md .env.example farmy.example.yml agents.yml tools.yml factory-prompt.md keys.Dockerfile knowledge.Dockerfile gate.Dockerfile ./
COPY crates ./crates
COPY docs ./docs
COPY toolbox ./toolbox
COPY providers ./providers
COPY release.yml ./
COPY bin/build bin/release bin/render-release bin/install ./bin/
ARG FARMY_HASH
# the commit the sources come from, which farmy --version prints (build.rs; the context has no .git)
ARG FARMY_COMMIT
RUN case "$FARMY_HASH" in *[!0-9a-fA-F]*|'') FARMY_HASH=$(FARMY_HASH_ONLY=1 sh ./farmy);; esac; FARMY_SOURCE_HASH="$FARMY_HASH" cargo build --release --locked
RUN bin/render-release /out

FROM alpine:3.21
ARG FARMY_VERSION
ARG FARMY_HASH=source
LABEL farmy.version=$FARMY_VERSION farmy.hash=$FARMY_HASH farmy.format=1
RUN apk add --no-cache docker-cli docker-cli-compose docker-cli-buildx git tmux bash curl wget ca-certificates openssh-client netcat-openbsd sudo tzdata
# the Infisical CLI, from Infisical's own apk repository (the way its docs give for Alpine)
RUN wget -qO- 'https://artifacts-cli.infisical.com/setup.apk.sh' | sh && apk add --no-cache infisical
COPY --from=build /src/target/release/farmy /src/target/release/farmy-keys /src/target/release/farmy-knowledge /src/target/release/farmy-gate /usr/local/bin/
COPY --from=build /out/farmy /usr/local/lib/farmy/farmy
COPY VERSION README.md .env.example farmy.example.yml tools.yml agents.yml egress-hosts.yml factory-prompt.md keys.Dockerfile knowledge.Dockerfile gate.Dockerfile release.yml /opt/farmy/
COPY docs /opt/farmy/docs
COPY toolbox /opt/farmy/toolbox
COPY providers /opt/farmy/providers
COPY crates /opt/farmy/crates
ENV FARMY_HOME=/opt/farmy
# no "What's next: Try Docker Debug" after every docker command (Docker Desktop prints it otherwise)
ENV DOCKER_CLI_HINTS=false
# No ENTRYPOINT: the shim keeps the control container up with a sleeper (`tail -f /dev/null`) and runs farmy
# in it with `docker exec`; `docker run --rm farmy:local` alone prints the usage.
CMD ["farmy", "help"]
