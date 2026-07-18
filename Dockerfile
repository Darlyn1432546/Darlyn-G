# Usamos una imagen que sí tiene Flutter instalado
FROM ghcr.io/cirruslabs/flutter:stable AS build

WORKDIR /app

# 1. Primero copiamos solo lo necesario para instalar dependencias
COPY pubspec.yaml pubspec.lock ./
# 2. Descargamos las dependencias DENTRO del contenedor
RUN flutter pub get

# 3. Ahora sí copiamos el resto del código
COPY . .

# 4. Compilamos
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