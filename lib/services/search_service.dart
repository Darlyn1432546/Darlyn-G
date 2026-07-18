// services/search_service.dart
import '../models/song.dart';
import 'proxy_youtube_service.dart';

class SearchService {
  final ProxyYoutubeService _proxy = ProxyYoutubeService();

  // Búsqueda local (en la base de datos local)
  List<Song> searchLocal(String query) {
    // Si quieres, puedes implementar búsqueda local en database
    // Por ahora, devolvemos vacío
    return [];
  }

  // Búsqueda online usando el proxy
  Future<List<Song>> searchOnline(String query) async {
    try {
      return await _proxy.searchSongs(query);
    } catch (e) {
      print('Error en búsqueda online: $e');
      return [];
    }
  }

  // Método genérico (usado en SearchScreen)
  Future<List<Song>> search(String query) async {
    // Si es modo local, usa searchLocal; si es online, usa searchOnline
    // Pero SearchScreen ya maneja el modo, así que podemos dejar solo online
    return await searchOnline(query);
  }

  // Para obtener tendencias
  Future<List<Song>> getTopTracks() async {
    return await _proxy.getTrendingSongs();
  }

  // No necesitas dispose porque ProxyYoutubeService no tiene recursos internos
  void dispose() {}
}