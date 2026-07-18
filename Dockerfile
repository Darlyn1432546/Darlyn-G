FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /app

# 1. Copiamos solo el YAML
# Cambia esto:
COPY pubspec.yaml pubspec.lock ./

# Por esto (quita el pubspec.lock):
COPY pubspec.yaml ./

# 2. Instalamos dependencias para Linux
RUN flutter pub get

# 3. Copiamos todo el código
COPY . .

# 4. LIMPIEZA TOTAL: Borramos cualquier archivo de configuración de Windows
# que se haya copiado por error en el paso anterior.
RUN rm -rf .dart_tool/ && rm -f package_config.json

# 5. Regeneramos la configuración LIMPIA dentro del contenedor
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