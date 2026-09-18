FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /app

# 1. AISLAMIENTO: Obligamos a que el caché de paquetes esté en una ruta limpia de Linux
ENV PUB_CACHE=/tmp/.pub-cache
ENV PATH="$PATH:/tmp/.pub-cache/bin"

# 2. Copiamos los archivos de configuración
COPY pubspec.yaml pubspec.lock ./

# 3. Borramos el lock y los paquetes para asegurar limpieza
RUN rm -rf .dart_tool/ .packages pubspec.lock && flutter pub get

# 4. Copiamos el código fuente
COPY lib/ lib/
COPY assets/ assets/

# 5. Compilamos
# Forzamos la regeneración del package_config.json justo antes de compilar
RUN rm -rf .dart_tool/ && flutter pub get && dart compile exe lib/server/bin/server.dart -o bin/server

# Segunda etapa: Imagen ligera
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/bin/server /server
EXPOSE 8081
ENV PORT=8081
CMD ["/server"]