# syntax=docker/dockerfile:1
# Den relay image. Build from the repository root (the relay depends on den_net and den_core):
#   docker build -f deploy/relay/Dockerfile -t den-relay .

FROM dart:stable AS build
WORKDIR /src

# Resolve dependencies first so source edits don't invalidate the pub cache layer.
COPY packages/den_core/pubspec.yaml packages/den_core/pubspec.lock* packages/den_core/
COPY packages/den_net/pubspec.yaml packages/den_net/pubspec.lock* packages/den_net/
COPY packages/den_relay/pubspec.yaml packages/den_relay/pubspec.lock* packages/den_relay/
RUN cd packages/den_relay && dart pub get

COPY packages/den_core/ packages/den_core/
COPY packages/den_net/ packages/den_net/
COPY packages/den_relay/ packages/den_relay/
RUN mkdir -p /out/data \
 && cd packages/den_relay \
 && dart pub get --offline \
 && dart compile exe bin/den_relay.dart -o /out/den_relay

# The dart image's /runtime holds the few shared libraries an AOT executable needs.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /out/den_relay /app/den_relay
COPY --from=build --chown=65532:65532 /out/data /data

ENV DEN_RELAY_PORT=47734 \
    DEN_RELAY_DATA=/data
USER 65532:65532
EXPOSE 47734
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/app/den_relay", "--healthcheck"]
ENTRYPOINT ["/app/den_relay"]
