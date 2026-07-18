FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /app

# 1. Copiamos los archivos de dependencias
COPY pubspec.yaml pubspec.lock ./

# 2. Descargamos dependencias limpias
RUN flutter pub get

# 3. Copiamos todo el código
COPY . .

# 4. LIMPIEZA FORZADA: Borramos cualquier rastro de Windows
# Esto elimina los archivos que apuntan a tu Disco C:\
RUN rm -rf .dart_tool && rm -f package_config.json .packages

# 5. Regeneramos la configuración dentro del contenedor (por si acaso)
RUN flutter pub get

# 6. Compilamos
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