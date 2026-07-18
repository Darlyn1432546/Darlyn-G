import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show kIsWeb;
import '../models/song.dart';

class ProxyYoutubeService {
  // 🔥 URL del servidor proxy
  static String get baseUrl {
    if (kIsWeb) {
      return 'http://localhost:8081'; // ← Puerto 8081 para el proxy
    } else {
      return 'http://192.168.0.207:8081'; // IP local para Android
    }
  }

  Future<List<Song>> searchSongs(String query) async {
    final response = await http.get(Uri.parse('$baseUrl/search?q=$query'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final List songs = data['songs'];
      return songs
          .map(
            (s) => Song(
              audioPath: s['id'],
              title: s['title'],
              artist: s['artist'],
              img: s['thumbnail'],
              isOnline: true,
              source: 'youtube',
            ),
          )
          .toList();
    } else {
      throw Exception('Error al buscar: ${response.statusCode}');
    }
  }

  Future<List<Song>> getTrendingSongs() async {
    final response = await http.get(Uri.parse('$baseUrl/trending'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final List songs = data['songs'];
      return songs
          .map(
            (s) => Song(
              audioPath: s['id'],
              title: s['title'],
              artist: s['artist'],
              img: s['thumbnail'],
              isOnline: true,
              source: 'youtube',
            ),
          )
          .toList();
    } else {
      throw Exception('Error al obtener tendencias: ${response.statusCode}');
    }
  }

// En services/proxy_youtube_service.dart
// En services/proxy_youtube_service.dart
Future<String?> getAudioUrl(String videoId) async {
  try {
    final response = await http.get(Uri.parse('$baseUrl/audio?id=$videoId'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['url']; // URL directa de YouTube
    } else {
      print('❌ Error al obtener audio: ${response.statusCode}');
      return null;
    }
  } catch (e) {
    print('❌ Error en getAudioUrl: $e');
    return null;
  }
}
  Future<List<Song>> getLikedSongs() async {
    final response = await http.get(Uri.parse('$baseUrl/liked'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final List songs = data['songs'];
      return songs
          .map(
            (s) => Song(
              audioPath: s['id'],
              title: s['title'],
              artist: s['artist'],
              img: s['thumbnail'],
              isOnline: true,
              source: 'youtube',
            ),
          )
          .toList();
    } else {
      throw Exception('Error al obtener "Me gusta": ${response.statusCode}');
    }
  }
}
