# Farmy's filtering proxy: only this helper has an outward network attachment.
FROM farmy:local AS bins
FROM alpine:3.21
RUN mkdir -p /run/farmy-gate && adduser -D -u 1001 gate && chown gate /run/farmy-gate
COPY --from=bins /usr/local/bin/farmy-gate /usr/local/bin/farmy-gate
EXPOSE 9182
USER 1001
ENTRYPOINT ["farmy-gate", "serve"]
