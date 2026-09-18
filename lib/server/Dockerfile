FROM dart:stable

# Instalar Python, pip y ffmpeg para yt-dlp
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir --break-system-packages yt-dlp

WORKDIR /app

# 1. Copiar la configuración de dependencias primero
COPY pubspec.* ./

# 2. Descargar las dependencias limpias dentro de Linux
RUN dart pub get

# 3. Copiar el resto del código fuente
COPY . .

EXPOSE 8081

CMD ["dart", "run", "bin/server.dart"]