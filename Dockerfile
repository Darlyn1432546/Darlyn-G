FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /app

COPY pubspec.yaml ./
RUN flutter pub get

COPY . .

# --- AÑADE ESTO: Limpieza definitiva ---
# Borramos todo rastro de configuración de Windows que se haya copiado
RUN rm -rf .dart_tool && rm -f package_config.json
# --------------------------------------

# Compilamos
RUN dart compile exe lib/server/bin/server.dart -o bin/server

FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/bin/server /server
EXPOSE 8081
ENV PORT=8081
CMD ["/server"]