# Usa la imagen oficial de Dart
FROM dart:stable AS build

# Establece el directorio de trabajo
WORKDIR /app

# Copia los archivos de dependencias
COPY pubspec.* ./
RUN dart pub get

# Copia el resto del código
COPY . .

# Compila el servidor a un ejecutable
RUN dart compile exe bin/server.dart -o bin/server

# Usa una imagen más ligera para la ejecución
FROM debian:stable-slim
# Instalamos solo los certificados necesarios para conexiones HTTPS
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copia el ejecutable compilado desde la etapa "build"
COPY --from=build /app/bin/server /server

# Expone el puerto que usa tu servidor
EXPOSE 8081

# Variables de entorno
ENV PORT=8081

# Ejecuta el servidor
CMD ["/server"]