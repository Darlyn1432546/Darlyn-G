// lib/models/song.dart
class Song {
  final String audioPath;
  final String title;
  final String artist;
  final String img;
  final bool isOnline;

  const Song({
    required this.audioPath,
    required this.title,
    required this.artist,
    required this.img,
    this.isOnline = false,
  });

  // Factory para parsear respuestas de Deezer
  factory Song.fromDeezer(Map<String, dynamic> json) {
    return Song(
      audioPath: json['preview'] ?? '',
      title: json['title'] ?? 'Sin título',
      artist: json['artist']?['name'] ?? 'Artista desconocido',
      img: json['album']?['cover_medium'] ?? '',
      isOnline: true, // <-- Muy importante: marcamos como online
    );
  }
}