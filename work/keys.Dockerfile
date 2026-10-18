# The keys broker's image: the farmy-keys binary from the control image, on a minimal Alpine with CA roots.
# Alpine because it is farmy's own image running a static binary (README → Images); services are not.
FROM farmy:local AS bins
FROM alpine:3.21
RUN apk add --no-cache ca-certificates openssh-client && mkdir -p /run/farmy-keys && adduser -D -u 1001 keys && chown keys /run /run/farmy-keys
COPY --from=bins /usr/local/bin/farmy-keys /usr/local/bin/farmy-keys
EXPOSE 9181
USER 1001
ENTRYPOINT ["farmy-keys", "serve"]
