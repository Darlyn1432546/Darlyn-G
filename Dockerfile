# Etapa de construcción
FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /app

# 1. Copiamos solo los archivos de configuración
COPY pubspec.yaml pubspec.lock ./

# 2. Instalamos dependencias limpias
RUN flutter pub get

# 3. Copiamos SOLO la carpeta lib (donde está todo tu código, incluido el server)
COPY lib/ lib/

# 4. Copiamos assets si los necesitas
COPY assets/ assets/

# 5. Compilamos el servidor apuntando a la ruta real de tu archivo
RUN dart compile exe lib/server/bin/server.dart -o bin/server

# Segunda etapa: Imagen ligera
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/bin/server /server
EXPOSE 8081
ENV PORT=8081
CMD ["/server"]