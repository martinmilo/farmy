# farmy's toolbox: the app container's image, built on the service's own image (BASE) with what an agent
# and a developer need inside: git, a shell, curl, the dev user, the agents named in AGENTS (installed from
# agents.tsv, which farmy puts into the build context: one line per agent, FORMATS.md → Agents). BASE is
# the service's own choice, never defaulted: an official Debian image (apt) is the supported path; Alpine
# (apk) builds, best effort (README → Images). A toolbox/ folder in the containers folder replaces this
# one; farmy's own entrypoint goes on top of either (see the end of this file).
ARG BASE=debian:bookworm-slim
FROM ${BASE}
ARG AGENTS=""
USER root
COPY agents.tsv /etc/farmy/agents.tsv
COPY install.sh /usr/local/lib/farmy-install.sh
COPY agents-as-dev.sh /usr/local/lib/farmy-agents-as-dev.sh
RUN sh /usr/local/lib/farmy-install.sh "$AGENTS" && rm /usr/local/lib/farmy-install.sh
# UTF-8 whatever the base image and the user's own LANG: Debian slim carries only C and C.UTF-8, musl takes it too
ENV LANG=C.UTF-8 DISABLE_AUTOUPDATER=1 USE_BUILTIN_RIPGREP=0 PATH=/home/dev/.local/bin:$PATH
WORKDIR /workspace
# Each agent's version line, run as dev, the user who runs the agents: a CLI dev cannot run (installed under
# /root, say) fails the build here, naming the agent and what the command said (FORMATS.md → Agents).
USER dev
RUN sh /usr/local/lib/farmy-agents-as-dev.sh "$AGENTS"
USER root
# No ENTRYPOINT here: farmy appends its own layer to whichever toolbox is built, last, and that layer
# installs entrypoint.sh as /usr/local/bin/farmy-entrypoint and makes it the ENTRYPOINT.
