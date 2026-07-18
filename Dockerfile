# Etapa de construcción
FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /app

# 1. Copiamos los archivos de dependencias
COPY pubspec.yaml pubspec.lock ./

# 2. Instalamos dependencias primero (sin los archivos locales de Windows)
RUN flutter pub get

# 3. Ahora copiamos el código fuente (después de haber instalado dependencias)
COPY . .

# 4. Forzamos una actualización de dependencias por si acaso
RUN flutter pub get

# 5. Compilamos
RUN dart compile exe lib/server/bin/server.dart -o bin/server

# Etapa final
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/bin/server /server
EXPOSE 8081
ENV PORT=8081
CMD ["/server"]