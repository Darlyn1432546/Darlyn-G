FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /app

# 1. Definimos una variable de caché (cambia a 2 si sigue fallando)
ARG CACHEBUST=1

# 2. Copiamos solo los archivos de dependencias
COPY pubspec.yaml pubspec.lock ./

# 3. Instalamos dependencias en Linux (esto crea rutas de Linux)
RUN flutter pub get

# 4. AQUÍ ESTÁ EL CAMBIO: No copies todo. Copia solo lo que necesitas.
# Esto evita que las carpetas "sucias" de Windows entren al contenedor.
COPY lib/ lib/
COPY assets/ assets/
# Si tienes una carpeta bin en la raíz, descomenta la línea de abajo:
# COPY bin/ bin/

# 5. Compilamos
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