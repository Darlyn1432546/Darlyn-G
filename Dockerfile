FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /app

# 1. Copiamos solo el yaml (sin el lock para evitar rutas de Windows)
COPY pubspec.yaml ./
# 2. Generamos un nuevo lockfile limpio dentro del contenedor
RUN flutter pub get

# 3. Copiamos el resto
COPY . .

# 4. Compilamos
RUN dart compile exe lib/server/bin/server.dart -o bin/server

FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/bin/server /server
EXPOSE 8081
ENV PORT=8081
CMD ["/server"]