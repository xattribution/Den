# syntax=docker/dockerfile:1
# Den hub: the family's always-on device in a container. Serves the web app, device sync (/ws),
# the HTTP API, MCP with OAuth, calendar feeds and reminders on one port.
# Build from the repository root:  docker build -f deploy/hub/Dockerfile -t den-hub .

FROM ghcr.io/cirruslabs/flutter:3.38.5 AS web
WORKDIR /src
COPY packages packages
COPY app app
COPY deploy/hub/fallback_fonts.sh /usr/local/bin/fallback_fonts.sh
WORKDIR /src/app
# The hub serves the web app under a Content-Security-Policy that allows nothing from a CDN:
# --csp keeps dart2js from generating code at run time, CanvasKit loads from the hub
# (build/web/canvaskit/) instead of gstatic.com, and so do the fonts Flutter falls back to for
# emoji and symbols (build/web/fonts/fallback/). DEN_FALLBACK_FONTS=. ships every script's.
ARG DEN_FALLBACK_FONTS=
RUN flutter pub get \
 && flutter build web --release --csp --dart-define=FLUTTER_WEB_CANVASKIT_URL=canvaskit/ \
 && sh /usr/local/bin/fallback_fonts.sh build/web "$DEN_FALLBACK_FONTS"

FROM dart:3.10 AS hub
WORKDIR /src
# Resolve dependencies first so source edits don't invalidate the pub cache layer.
COPY packages/den_core/pubspec.yaml packages/den_core/pubspec.lock* packages/den_core/
COPY packages/den_net/pubspec.yaml packages/den_net/pubspec.lock* packages/den_net/
COPY packages/den_capture/pubspec.yaml packages/den_capture/pubspec.lock* packages/den_capture/
COPY packages/den_assistant/pubspec.yaml packages/den_assistant/pubspec.lock* packages/den_assistant/
COPY packages/den_actions/pubspec.yaml packages/den_actions/pubspec.lock* packages/den_actions/
COPY packages/den_relay/pubspec.yaml packages/den_relay/pubspec.lock* packages/den_relay/
COPY packages/den_sett_import/pubspec.yaml packages/den_sett_import/pubspec.lock* packages/den_sett_import/
COPY packages/den_hub/pubspec.yaml packages/den_hub/pubspec.lock* packages/den_hub/
COPY packages/den_hub_cli/pubspec.yaml packages/den_hub_cli/pubspec.lock* packages/den_hub_cli/
RUN cd packages/den_hub_cli && dart pub get
COPY packages packages
# den_sett_import links SQLite through a build hook, which `dart compile exe` doesn't run;
# `dart build cli` does, and bundles the library next to the binary (bundle/lib).
# The entry point lives in den_hub_cli (bin/den_hub.dart); den_hub is the library it serves.
RUN cd packages/den_hub_cli \
 && dart pub get --offline \
 && dart build cli -t bin/den_hub.dart -o /out \
 && mkdir -p /out/data

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home /data den \
 && mkdir -p /data /app/web && chown den /data
COPY --from=hub /out/bundle/ /app/
COPY --from=web /src/app/build/web /app/web
USER den
VOLUME /data
EXPOSE 47733
ENV DEN_DATA=/data \
    DEN_WEB=/app/web \
    DEN_PORT=47733
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s CMD curl -fsS "http://127.0.0.1:${DEN_PORT:-47733}/health" || exit 1
ENTRYPOINT ["/app/bin/den_hub"]
CMD ["serve"]
