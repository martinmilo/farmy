# The knowledge container's image: the farmy-knowledge binary from the control image.
# Alpine because it is farmy's own image running a static binary (README → Images); services are not.
FROM farmy:local AS bins
FROM alpine:3.21
COPY --from=bins /usr/local/bin/farmy-knowledge /usr/local/bin/farmy-knowledge
# farmy's own docs live in the image: the daemon resolves a bind source on the host, where the control
# container's /opt/farmy does not exist. The containers folder's services/ and .work/status are bind-mounted.
COPY README.md /kb/README.md
COPY docs /kb/docs
EXPOSE 9190
USER nobody
ENTRYPOINT ["farmy-knowledge"]
