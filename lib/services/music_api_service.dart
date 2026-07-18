// services/music_api_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/song.dart';

class MusicApiService {
  static const String baseUrl = 'https://api.jamendo.com/v3.0';
  static const String clientId = '3a078c92';

  Future<List<Song>> getTopTracks() async {
    final response = await http.get(
      Uri.parse('$baseUrl/tracks/?client_id=$clientId&format=json&limit=20&order=popularity_total'),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final List tracks = data['results'];
      return tracks.map((track) => Song(
        audioPath: track['audiodownload'] ?? track['audio'],
        title: track['name'],
        artist: track['artist_name'],
        img: track['image'] ?? track['album_image'] ?? '',
        isOnline: true,
      )).toList();
    } else {
      throw Exception('Error al cargar canciones');
    }
  }

  Future<List<Song>> getTracksByGenre(String genre) async {
    final response = await http.get(
      Uri.parse('$baseUrl/tracks/?client_id=$clientId&format=json&limit=20&tags=$genre'),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final List tracks = data['results'];
      return tracks.map((track) => Song(
        audioPath: track['audiodownload'] ?? track['audio'],
        title: track['name'],
        artist: track['artist_name'],
        img: track['image'] ?? track['album_image'] ?? '',
        isOnline: true,
      )).toList();
    } else {
      throw Exception('Error al cargar canciones por género');
    }
  }

  Future<List<Song>> searchTracks(String query) async {
    final response = await http.get(
      Uri.parse('$baseUrl/tracks/?client_id=$clientId&format=json&limit=20&search=$query'),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final List tracks = data['results'];
      return tracks.map((track) => Song(
        audioPath: track['audiodownload'] ?? track['audio'],
        title: track['name'],
        artist: track['artist_name'],
        img: track['image'] ?? track['album_image'] ?? '',
        isOnline: true,
      )).toList();
    } else {
      throw Exception('Error en la búsqueda');
    }
  }
}