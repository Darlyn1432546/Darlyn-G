# Usa la imagen oficial de Dart
FROM dart:stable AS build

# Establece el directorio de trabajo
WORKDIR /app

# Copia los archivos de dependencias
COPY pubspec.* ./
RUN dart pub get

# Copia el resto del código
COPY . .

# Compila el servidor a un ejecutable (opcional, pero recomendado para producción)
RUN dart compile exe bin/server.dart -o bin/server

# Usa una imagen más ligera para la ejecución
FROM debian:stable-slim
RUN apt-get update && apt-get install -y \
    ca-certificates \
    --no-install-recommends && rm -rf /var/lib/apt/lists/*

# Copia el ejecutable compilado
COPY --from=build /app/bin/server /server

# Expone el puerto que usa tu servidor
EXPOSE 8081

# Variables de entorno (se pueden pasar en Railway)
ENV PORT=8081

# Ejecuta el servidor
CMD ["/server"]