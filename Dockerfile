# Usamos una imagen que sí tiene Flutter instalado
FROM ghcr.io/cirruslabs/flutter:stable AS build

# Establece el directorio de trabajo
WORKDIR /app

# Copia los archivos de dependencias
COPY pubspec.* ./
RUN flutter pub get --no-dev

# Copia el resto del código
COPY . .

# Compila el servidor (Si es un proyecto Flutter de servidor/backend)
# Nota: Si es solo un backend en Dart, puedes usar 'dart compile exe'. 
# Si es una app de Flutter completa, el build process cambia.
RUN dart compile exe bin/server.dart -o bin/server

# Usa una imagen ligera para la ejecución final
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copia el ejecutable desde la etapa anterior
COPY --from=build /app/bin/server /server

# Expone el puerto
EXPOSE 8081
ENV PORT=8081

# Ejecuta el servidor
CMD ["/server"]