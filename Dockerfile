# Etapa de construcción
FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /app

# 1. Copiamos solo los archivos de dependencias
COPY pubspec.yaml pubspec.lock ./

# 2. Instalamos dependencias en Linux
RUN flutter pub get

# 3. Copiamos el resto del código
COPY . .

# 4. LIMPIEZA: Si algo se copió, lo eliminamos explícitamente
RUN rm -rf .dart_tool/ && rm -rf build/

# 5. Regeneramos dependencias con la configuración de Linux
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