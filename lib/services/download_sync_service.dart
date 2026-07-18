import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../main.dart'; // Para acceder a DownloadedSong

class DownloadSyncService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // Guardar las descargas locales en Firestore
  static Future<void> syncLocalDownloadsToCloud() async {
    final user = _auth.currentUser;
    if (user == null) return;

    final localSongs = await DownloadManager.getLocalSongs();
    final deviceSongs = await DownloadManager.getDeviceSongs();

    final allDownloads = {
      'local': localSongs.map((s) => s.toJson()).toList(),
      'device': deviceSongs.map((s) => s.toJson()).toList(),
    };

    await _firestore
        .collection('users')
        .doc(user.uid)
        .set({'downloads': allDownloads}, SetOptions(merge: true));
  }

  // Cargar las descargas desde Firestore y guardarlas localmente
  static Future<void> loadDownloadsFromCloud() async {
    final user = _auth.currentUser;
    if (user == null) return;

    final doc = await _firestore.collection('users').doc(user.uid).get();
    if (!doc.exists) return;

    final data = doc.data();
    if (data == null || !data.containsKey('downloads')) return;

    final downloads = data['downloads'] as Map<String, dynamic>;
    
    // Limpiar descargas locales actuales
    // (cuidado: si quieres fusionar, hazlo con cuidado)
    // await DownloadManager.clearAll(); // Necesitarías agregar este método

    // Cargar locales
    final localList = (downloads['local'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    for (var item in localList) {
      final song = DownloadedSong.fromJson(item);
      await DownloadManager.addLocalSong(song);
    }

    // Cargar de dispositivo
    final deviceList = (downloads['device'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    for (var item in deviceList) {
      final song = DownloadedSong.fromJson(item);
      await DownloadManager.addDeviceSong(song);
    }
  }

  // Sincronizar cuando se agregue o elimine una descarga
  static Future<void> syncOnChange() async {
    await syncLocalDownloadsToCloud();
  }
}