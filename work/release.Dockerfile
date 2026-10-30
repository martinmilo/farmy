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

FROM alpine:3.21 AS control
ARG FARMY_VERSION
ARG FARMY_HASH=source
LABEL farmy.version=$FARMY_VERSION farmy.hash=$FARMY_HASH farmy.format=1
RUN apk add --no-cache docker-cli docker-cli-compose docker-cli-buildx git tmux bash curl wget ca-certificates openssh-client netcat-openbsd sudo tzdata
# the Infisical CLI, from Infisical's own apk repository (the way its docs give for Alpine)
RUN wget -qO- 'https://artifacts-cli.infisical.com/setup.apk.sh' | sh && apk add --no-cache infisical
COPY --from=build /src/target/release/farmy /src/target/release/farmy-keys /src/target/release/farmy-knowledge /src/target/release/farmy-gate /usr/local/bin/
COPY --from=build /out/farmy /usr/local/lib/farmy/farmy
COPY VERSION README.md .env.example farmy.example.yml agents.yml tools.yml egress-hosts.yml factory-prompt.md keys.Dockerfile knowledge.Dockerfile gate.Dockerfile release.yml /opt/farmy/
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

# The keys broker's image: the farmy-keys binary from the control image, on a minimal Alpine with CA roots.
# Alpine because it is farmy's own image running a static binary (README → Images); services are not.
FROM alpine:3.21 AS keys
ARG FARMY_VERSION
ARG FARMY_HASH=source
LABEL farmy.version=$FARMY_VERSION farmy.hash=$FARMY_HASH
RUN apk add --no-cache ca-certificates openssh-client && mkdir -p /run/farmy-keys && adduser -D -u 1001 keys && chown keys /run /run/farmy-keys
COPY --from=build /src/target/release/farmy-keys /usr/local/bin/farmy-keys
EXPOSE 9181
USER 1001
ENTRYPOINT ["farmy-keys", "serve"]

# The knowledge container's image: the farmy-knowledge binary from the control image.
# Alpine because it is farmy's own image running a static binary (README → Images); services are not.
FROM alpine:3.21 AS knowledge
ARG FARMY_VERSION
ARG FARMY_HASH=source
LABEL farmy.version=$FARMY_VERSION farmy.hash=$FARMY_HASH
COPY --from=build /src/target/release/farmy-knowledge /usr/local/bin/farmy-knowledge
# farmy's own docs live in the image: the daemon resolves a bind source on the host, where the control
# container's /opt/farmy does not exist. The containers folder's services/ and .work/status are bind-mounted.
COPY README.md /kb/README.md
COPY docs /kb/docs
EXPOSE 9190
USER nobody
ENTRYPOINT ["farmy-knowledge"]

# Farmy's filtering proxy: only this helper has an outward network attachment.
FROM alpine:3.21 AS gate
ARG FARMY_VERSION
ARG FARMY_HASH=source
LABEL farmy.version=$FARMY_VERSION farmy.hash=$FARMY_HASH
RUN mkdir -p /run/farmy-gate && adduser -D -u 1001 gate && chown gate /run/farmy-gate
COPY --from=build /src/target/release/farmy-gate /usr/local/bin/farmy-gate
EXPOSE 9182
USER 1001
ENTRYPOINT ["farmy-gate", "serve"]
