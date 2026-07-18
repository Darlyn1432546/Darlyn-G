FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /app

# 1. Copiamos solo los archivos de dependencias
COPY pubspec.yaml pubspec.lock ./

# 2. Eliminamos cualquier rastro de configuración local de Windows antes de hacer el pub get
RUN rm -rf .dart_tool/ package_config.json

# 3. Instalamos dependencias limpias
RUN flutter pub get

# 4. Copiamos el resto del código
COPY . .

# 5. ELIMINACIÓN CRÍTICA: Borramos la carpeta .dart_tool que pudo haber venido con el COPY . .
# y forzamos la regeneración de configuración de Linux.
RUN rm -rf .dart_tool/ && rm -f package_config.json && flutter pub get

# 6. Compilamos el servidor
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