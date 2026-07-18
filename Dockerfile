# 1. Usamos la imagen con Flutter SDK
FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /app

# 2. Variable para forzar rebuild (cambia el '1' a '2' si falla de nuevo)
ARG CACHEBUST=1

# 3. Copiamos solo el YAML (SIN el lockfile)
COPY pubspec.yaml ./

# 4. Instalamos dependencias y GENERAMOS un lockfile nuevo en Linux
RUN flutter pub get

# 5. Copiamos todo el código fuente
COPY . .

# 6. LIMPIEZA NUCLEAR: Borramos cualquier rastro de .dart_tool que pudo entrar
# y regeneramos el entorno de nuevo
RUN rm -rf .dart_tool/ && flutter pub get

# 7. Compilamos
RUN dart compile exe lib/server/bin/server.dart -o bin/server

# Segunda etapa: Imagen ligera de ejecución
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/bin/server /server
EXPOSE 8081
ENV PORT=8081
CMD ["/server"]