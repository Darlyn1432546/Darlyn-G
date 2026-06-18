import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show kIsWeb;
import '../models/song.dart';

class MusicApiService {
  static const String _deezerBase = 'https://api.deezer.com';

  // Método que construye la URL final según la plataforma
  String _buildUrl(String endpoint) {
    if (kIsWeb) {
      // En web: usamos proxy CORS para evitar bloqueos
      final fullUrl = '$_deezerBase$endpoint';
      return 'https://corsproxy.io/?url=${Uri.encodeComponent(fullUrl)}';
    } else {
      // En móvil (Android/iOS): vamos directo a Deezer, sin proxy
      return '$_deezerBase$endpoint';
    }
  }

  Future<List<Song>> getTopTracks() async {
    try {
      final url = _buildUrl('/chart/0/tracks?limit=20');
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> tracks = data['data'] as List? ?? [];
        return tracks.map((track) => Song.fromDeezer(track)).toList();
      } else {
        print('Error en getTopTracks: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      print('Error en getTopTracks: $e');
      return [];
    }
  }

  Future<List<Song>> searchTracks(String query) async {
    try {
      final encodedQuery = Uri.encodeComponent(query);
      final url = _buildUrl('/search/track?q=$encodedQuery');
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> tracks = data['data'] as List? ?? [];
        return tracks.map((track) => Song.fromDeezer(track)).toList();
      } else {
        print('Error en searchTracks: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      print('Error en searchTracks: $e');
      return [];
    }
  }

  Future<List<Song>> getTracksByGenre(String genre) async {
    return searchTracks(genre);
  }
}