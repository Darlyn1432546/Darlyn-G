# Usamos la imagen oficial de Dart (mucho más ligera y limpia)
FROM dart:stable AS build
WORKDIR /app

# 1. Copiamos los archivos de dependencias
COPY pubspec.yaml pubspec.lock ./

# 2. Instalamos dependencias limpias en un entorno Dart puro
RUN dart pub get

# 3. Copiamos solo el código necesario
COPY lib/ lib/
COPY assets/ assets/

# 4. Limpiamos cualquier rastro de .dart_tool y regeneramos
# Esto obliga a generar nuevas rutas internas de Linux
RUN rm -rf .dart_tool/ .packages && dart pub get

# 5. Compilamos
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