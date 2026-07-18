FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /app

# 1. Forzamos a Docker a no usar caché para esta capa
ARG CACHEBUST=1

# 2. Copiamos solo lo esencial
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

# 3. Copiamos solo las carpetas de código (NO copies todo con COPY . .)
COPY lib/ lib/
COPY bin/ bin/
COPY assets/ assets/

# 4. Compilamos
RUN dart compile exe bin/server.dart -o bin/server

# Segunda etapa
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/bin/server /server
EXPOSE 8081
ENV PORT=8081
CMD ["/server"]