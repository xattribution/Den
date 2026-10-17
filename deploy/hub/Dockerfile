# Den hub: the family's always-on device in a container. Serves the web app, the sync endpoint,
# the HTTP API, MCP and the Home Assistant bridge on one port.
# Build from the repository root:  docker build -f deploy/hub/Dockerfile -t den-hub .

FROM ghcr.io/cirruslabs/flutter:3.38.5 AS web
WORKDIR /src
COPY packages/den_core packages/den_core
COPY packages/den_net packages/den_net
COPY app app
WORKDIR /src/app
RUN flutter pub get && flutter build web --release

FROM dart:3.10 AS hub
WORKDIR /src
COPY packages packages
WORKDIR /src/packages/den_hub
RUN dart pub get && dart compile exe bin/den_hub.dart -o /out/den_hub

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home /data den \
 && mkdir -p /data /app/web && chown den /data
COPY --from=hub /runtime/ /
COPY --from=hub /out/den_hub /app/den_hub
COPY --from=web /src/app/build/web /app/web
USER den
VOLUME /data
EXPOSE 47733
ENV DEN_DATA=/data DEN_WEB=/app/web DEN_PORT=47733
HEALTHCHECK --interval=30s --timeout=5s CMD curl -fsS http://127.0.0.1:47733/health || exit 1
ENTRYPOINT ["/app/den_hub"]
CMD ["serve"]
