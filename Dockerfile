# Etapa de construcción
FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /app

# 1. Definimos una variable de caché (cambia el número 1 a 2, 3, etc., si sigue fallando)
ARG CACHEBUST=1

# 2. Copiamos solo los archivos de configuración
COPY pubspec.yaml pubspec.lock ./

# 3. Limpiamos cualquier rastro antes de instalar
RUN rm -rf .dart_tool/ && flutter pub get

# 4. Copiamos el código
COPY lib/ lib/
COPY assets/ assets/

# 5. Compilamos el servidor
# Forzamos una última limpieza antes de compilar
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