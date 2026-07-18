import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'dart:async';
import 'dart:math';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:device_preview/device_preview.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'firebase_options.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:likeus/likeus.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'models/song.dart';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'services/proxy_youtube_service.dart';
import 'services/search_service.dart';
import 'pochita_loader.dart';
import 'dart:math' as math;
import 'dart:convert';
import 'package:permission_handler/permission_handler.dart';
import 'package:collection/collection.dart';
import 'services/download_sync_service.dart';

// ========== NUEVOS NOTIFICADORES GLOBALES ==========
// Estado de descarga (songId -> true si está descargado)
final ValueNotifier<Map<String, bool>> downloadStatusNotifier = ValueNotifier(
  {},
);

// Progreso de descarga (songId -> valor 0.0 a 1.0)
final ValueNotifier<Map<String, double>> downloadProgressNotifier =
    ValueNotifier({});

enum DownloadType { internal, public }

// Función para refrescar el estado de descargas desde el almacenamiento
Future<void> refreshDownloadStatus() async {
  final local = await DownloadManager.getLocalSongs();
  final device = await DownloadManager.getDeviceSongs();
  final allDownloaded = [...local, ...device];
  final statusMap = <String, bool>{};
  for (final song in allDownloaded) {
    statusMap[song.videoId] = true;
  }
  downloadStatusNotifier.value = statusMap;
}

Future<String> downloadSongWithProgress({
  required Song song,
  required bool isLocal,
  required Function(int progress, int total) onProgress,
}) async {
  // 1. Obtener la URL del audio
  final audioUrl = await ProxyYoutubeService().getAudioUrl(song.audioPath);
  if (audioUrl == null) {
    throw Exception('No se pudo obtener la URL del audio');
  }

  // 2. Determinar el directorio de destino
  Directory dir;
  if (isLocal) {
    dir = await getApplicationDocumentsDirectory();
  } else {
    if (Platform.isAndroid) {
      // Solicitar permiso de almacenamiento (simplificado)
      var status = await Permission.storage.status;
      if (!status.isGranted) {
        status = await Permission.storage.request();
      }
      if (!status.isGranted) {
        throw Exception('Permiso de almacenamiento denegado');
      }
      final musicDir = await getExternalStorageDirectories(
        type: StorageDirectory.music,
      );
      if (musicDir == null || musicDir.isEmpty) {
        throw Exception('No se puede acceder al directorio de música');
      }
      dir = musicDir.first;
    } else {
      dir = await getApplicationDocumentsDirectory();
    }
  }
  // 3. Generar nombre de archivo único (usamos el videoId)
  final extension = p.extension(Uri.parse(audioUrl).path);
  final fileName = '${song.audioPath}$extension';
  final filePath = p.join(dir.path, fileName);

  // 4. Verificar si ya existe (duplicado)
  final existingLocal = await DownloadManager.getLocalSongs();
  final existingDevice = await DownloadManager.getDeviceSongs();
  final allExisting = [...existingLocal, ...existingDevice];
  DownloadedSong? existing;
  try {
    existing = allExisting.firstWhere((s) => s.videoId == song.audioPath);
  } catch (_) {
    existing = null;
  }

  // 5. Descargar usando Dio con progreso
  final dio = Dio();
  await dio.download(
    audioUrl,
    filePath,
    onReceiveProgress: (received, total) {
      if (total != -1) {
        onProgress(received, total);
      }
    },
  );

  // 6. Guardar en DownloadManager
  final downloadedSong = DownloadedSong(
    videoId: song.audioPath,
    title: song.title,
    artist: song.artist,
    img: song.img,
    localPath: filePath,
    type: isLocal ? 'local' : 'device',
  );
  if (isLocal) {
    await DownloadManager.addLocalSong(downloadedSong);
  } else {
    await DownloadManager.addDeviceSong(downloadedSong);
  }
  await DownloadSyncService.syncOnChange();

  return filePath;
}

// Excepción personalizada para duplicados
class DuplicateSongException implements Exception {
  final String message;
  DuplicateSongException(this.message);
}

enum RepeatMode { none, all, one }

// Después de los imports, antes de final ValueNotifier...
late final AudioPlayerService audioPlayerService;
late final SearchService searchService;
final ValueNotifier<Set<String>> favoriteNotifier = ValueNotifier<Set<String>>(
  {},
);
// Servicio global para el perfil del usuario (se carga una sola vez)
final ValueNotifier<UserProfile> userProfileNotifier =
    ValueNotifier<UserProfile>(
      UserProfile(
        nickname: '',
        avatarUrl: '',
        avatarHasOwnCircle: false,
        isLoaded: false,
      ),
    );

class UserProfile {
  final String nickname;
  final String avatarUrl;
  final bool avatarHasOwnCircle;
  final bool isLoaded;

  UserProfile({
    required this.nickname,
    required this.avatarUrl,
    required this.avatarHasOwnCircle,
    required this.isLoaded,
  });

  UserProfile copyWith({
    String? nickname,
    String? avatarUrl,
    bool? avatarHasOwnCircle,
    bool? isLoaded,
  }) {
    return UserProfile(
      nickname: nickname ?? this.nickname,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      avatarHasOwnCircle: avatarHasOwnCircle ?? this.avatarHasOwnCircle,
      isLoaded: isLoaded ?? this.isLoaded,
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final session = await AudioSession.instance;
  await session.configure(AudioSessionConfiguration.music());

  audioPlayerService = AudioPlayerService();
  searchService = SearchService();

  // 🔥 Ya NO necesitamos dotenv.load ni inicializar YouTube
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await refreshDownloadStatus();
  initializeAllSongs();

  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
  );
  runApp(
    DevicePreview(
      enabled: !kReleaseMode,
      backgroundColor: const Color(0xFF121212),
      defaultDevice: Devices.ios.iPhone13,
      builder: (context) => const MusicApp(),
    ),
  );
}

Widget buildImage(
  String imageUrl, {
  double? width,
  double? height,
  BoxFit fit = BoxFit.cover,
}) {
  if (imageUrl.startsWith('assets/')) {
    return Image.asset(
      imageUrl,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (context, error, stackTrace) => Container(
        color: Colors.grey[800],
        child: Icon(Icons.broken_image, color: Colors.white54),
      ),
    );
  } else {
    return CachedNetworkImage(
      imageUrl: imageUrl,
      width: width,
      height: height,
      fit: fit,
      placeholder: (context, url) => Container(color: Colors.grey[800]),
      errorWidget: (context, url, error) => Container(
        color: Colors.grey[800],
        child: Icon(Icons.broken_image, color: Colors.white54),
      ),
    );
  }
}

class DownloadManager {
  static const String _localKey = 'downloaded_local_songs';
  static const String _deviceKey = 'downloaded_device_songs';

  // Obtener canciones locales
  static Future<List<DownloadedSong>> getLocalSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_localKey) ?? [];
    return list
        .map((jsonStr) => DownloadedSong.fromJson(jsonDecode(jsonStr)))
        .toList();
  }

  // Obtener canciones en dispositivo
  static Future<List<DownloadedSong>> getDeviceSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_deviceKey) ?? [];
    return list
        .map((jsonStr) => DownloadedSong.fromJson(jsonDecode(jsonStr)))
        .toList();
  }

  // Añadir canción local
  static Future<void> addLocalSong(DownloadedSong song) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await getLocalSongs();
    // Evitar duplicados por videoId
    list.removeWhere((s) => s.videoId == song.videoId);
    list.add(song);
    final jsonList = list.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList(_localKey, jsonList);
  }

  // Añadir canción en dispositivo
  static Future<void> addDeviceSong(DownloadedSong song) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await getDeviceSongs();
    list.removeWhere((s) => s.videoId == song.videoId);
    list.add(song);
    final jsonList = list.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList(_deviceKey, jsonList);
  }

  // Eliminar canción local por videoId
  static Future<void> removeLocalSong(String videoId) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await getLocalSongs();
    list.removeWhere((s) => s.videoId == videoId);
    final jsonList = list.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList(_localKey, jsonList);
  }

  // Eliminar canción en dispositivo por videoId
  static Future<void> removeDeviceSong(String videoId) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await getDeviceSongs();
    list.removeWhere((s) => s.videoId == videoId);
    final jsonList = list.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList(_deviceKey, jsonList);
  }

  // Verificar si una canción ya está descargada (local o device)
  static Future<bool> isSongDownloaded(String videoId) async {
    final local = await getLocalSongs();
    final device = await getDeviceSongs();
    return local.any((s) => s.videoId == videoId) ||
        device.any((s) => s.videoId == videoId);
  }
}

class AudioPlayerService {
  String? _currentPath;
  static final AudioPlayerService _instance = AudioPlayerService._internal();
  factory AudioPlayerService() => _instance;

  AudioPlayer _player = AudioPlayer();
  bool _isLoading = false;
  final ValueNotifier<bool> isPlayingNotifier = ValueNotifier(false);
  final ValueNotifier<bool> isBufferingNotifier = ValueNotifier(
    false,
  ); // ✅ Nuevo

  AudioPlayerService._internal() {
    _player.playerStateStream.listen((state) {
      final isPlaying = state.playing;
      isPlayingNotifier.value = isPlaying;

      // ✅ Actualizar estado de buffering
      final buffering =
          state.processingState == ProcessingState.loading ||
          state.processingState == ProcessingState.buffering;
      isBufferingNotifier.value = buffering;
    });
  }
  Future<File> _createTempFile(ByteData data) async {
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/temp_audio_${DateTime.now().millisecondsSinceEpoch}.mp3',
    );
    await file.writeAsBytes(data.buffer.asUint8List());
    return file;
  }

  AudioPlayer get player => _player;
  String? get currentPath => _currentPath;

  Future<void> loadSong(String assetPath, {bool autoPlay = false}) async {
    print('🔍 [loadSong] assetPath recibido: $assetPath');

    if (assetPath.isEmpty) {
      print('⚠️ Ruta vacía, ignorando');
      return;
    }

    if (_isLoading) {
      print('⚠️ Carga en curso, ignorando nueva solicitud');
      return;
    }
    _isLoading = true;

    try {
      await _player.stop();
      await Future.delayed(const Duration(milliseconds: 50));

      final session = await AudioSession.instance;
      final activated = await session.setActive(true);
      print('🎧 AudioSession activado: $activated');

      // 🆕 DETECCIÓN DE ARCHIVO LOCAL (descargado)
      bool isLocalFile = false;
      try {
        final uri = Uri.tryParse(assetPath);
        if (uri != null && uri.scheme == 'file') {
          isLocalFile = true;
        } else if (Platform.isAndroid && assetPath.startsWith('/')) {
          isLocalFile = true; // ruta absoluta en Android
        } else if (Platform.isWindows && assetPath.contains(':')) {
          isLocalFile = true; // ruta con letra de unidad (C:\...)
        } else if (Platform.isIOS && assetPath.startsWith('/var/')) {
          isLocalFile = true;
        }
      } catch (_) {}

      if (isLocalFile) {
        print('📂 Reproduciendo archivo LOCAL: $assetPath');
        await _player.setUrl(
          assetPath,
        ); // just_audio soporta file:// o rutas absolutas
        _currentPath = assetPath;
        if (autoPlay) {
          await _waitForPlayerReady();
          await _player.play();
          print('▶️ Reproducción iniciada (autoPlay)');
        }
        _isLoading = false;
        return;
      }

      // Si es canción de YouTube (ID)
      if (!assetPath.startsWith('http') && !assetPath.startsWith('assets/')) {
        print('🎵 Cargando canción de YouTube: $assetPath');
        final url = await ProxyYoutubeService().getAudioUrl(assetPath);
        print('🔗 URL generada: $url');
        if (url != null) {
          try {
            print('🎵 Intentando establecer URL en just_audio: $url');
            await _player.setUrl(url);
            print('✅ URL cargada con éxito en el reproductor');
            _currentPath = assetPath;
            if (autoPlay) {
              await _waitForPlayerReady();
              await _player.play();
              print('▶️ Reproducción iniciada (autoPlay)');
            }
            _isLoading = false;
            return;
          } on PlayerException catch (e) {
            print('❌ Error de JustAudio [Código]: ${e.code}');
            print('❌ Error de JustAudio [Mensaje]: ${e.message}');
            print('📊 Estado del player: ${_player.playerState}');
            _isLoading = false;
            return;
          } on PlayerInterruptedException catch (e) {
            print('⚠️ La carga fue interrumpida: ${e.message}');
            _isLoading = false;
            return;
          } catch (e) {
            print('❌ Error genérico al inicializar audio: $e');
            print('📊 Tipo de error: ${e.runtimeType}');
            _isLoading = false;
            return;
          }
        } else {
          print('⚠️ No se pudo obtener URL para $assetPath');
          _isLoading = false;
          return;
        }
      }

      // Resto del código para assets y URLs HTTP (sin cambios)
      if (assetPath.startsWith('http')) {
        await _player.setUrl(assetPath);
      } else if (kIsWeb) {
        final baseUrl = Uri.base.origin;
        final path = assetPath.startsWith('assets/')
            ? assetPath.substring(7)
            : assetPath;
        final fullUrl = '$baseUrl/assets/$path';
        await _player.setUrl(fullUrl);
      } else {
        // En Android, forzamos el uso de archivo temporal para assets
        print('📂 Cargando asset en Android con archivo temporal: $assetPath');
        try {
          final byteData = await rootBundle.load(assetPath);
          print(
            '📦 Asset cargado en memoria, tamaño: ${byteData.lengthInBytes} bytes',
          );
          final tempFile = await _createTempFile(byteData);
          print('📁 Archivo temporal creado: ${tempFile.path}');
          final fileUri = Uri.file(tempFile.path);
          await _player.setAudioSource(AudioSource.uri(fileUri));
          print('✅ setAudioSource con archivo temporal exitoso: $fileUri');
          _currentPath = assetPath;
          if (autoPlay) {
            await _waitForPlayerReady();
            await _player.play();
          }
          _isLoading = false;
          return;
        } catch (e) {
          print('❌ Error al cargar asset con archivo temporal: $e');
          await _player.dispose();
          print('♻️ Reiniciando AudioPlayer tras fallo');
          final newPlayer = AudioPlayer();
          _player = newPlayer;
          _player.playerStateStream.listen((state) {
            final isPlaying = state.playing;
            isPlayingNotifier.value = isPlaying;
            print('🎵 Listener: playing = $isPlaying');
          });
        }
      }

      _currentPath = assetPath;
      print('✅ Canción cargada: $assetPath');

      if (autoPlay) {
        await _waitForPlayerReady();
        await _player.play();
      } else {
        await _player.pause();
      }
    } catch (e) {
      print('❌ Error al cargar: $assetPath, $e');
      isPlayingNotifier.value = false;
    } finally {
      _isLoading = false;
    }
  }

  Future<void> _waitForPlayerReady() async {
    print('⏳ Esperando que el player esté listo...');
    Completer<void> completer = Completer();
    StreamSubscription<ProcessingState>? sub;
    sub = _player.processingStateStream.listen((state) {
      print('📊 Estado de procesamiento: $state');
      if (state == ProcessingState.ready ||
          state == ProcessingState.buffering ||
          state == ProcessingState.completed) {
        if (!completer.isCompleted) {
          print('✅ Player listo (state: $state)');
          completer.complete();
          sub?.cancel();
        }
      }
    });
    await completer.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        print('⚠️ Tiempo de espera agotado, reproduciendo de todos modos');
        if (!completer.isCompleted) completer.complete();
      },
    );
  }

  Future<void> play() async {
    try {
      await _player.play();
    } catch (e) {
      print('❌ Error al reproducir: $e');
    }
  }

  Future<void> pause() async {
    try {
      await _player.pause();
    } catch (e) {
      print('❌ Error al pausar: $e');
    }
  }

  Future<void> stop() => _player.stop();
  Future<void> seek(Duration position) => _player.seek(position);
  void dispose() => _player.dispose();
}

const List<Song> database = [
  Song(
    audioPath: 'assets/audios/soy_una_nina_remix.mp3',
    title: 'Soy una niña-Remix',
    artist: 'Alan Ortiz',
    img: 'assets/imagenes/nega.jpg',
  ),
  Song(
    audioPath: 'assets/audios/con_una_flor_amarilla.mp3',
    title: 'Con una flor amarilla',
    artist: 'Alan Ortiz',
    img: 'assets/imagenes/posa.jpg',
  ),
  Song(
    audioPath: 'assets/audios/dame_de_tu_vida.mp3',
    title: 'Dame de tu vida',
    artist: 'Alan Ortiz',
    img: 'assets/imagenes/dae.jpg',
  ),
  Song(
    audioPath: 'assets/audios/como_quieres_tu.mp3',
    title: 'Como quieres tu ',
    artist: 'Alan Ortiz',
    img: 'assets/imagenes/lol.jpg',
  ),
  Song(
    audioPath: 'assets/audios/le_va_a_doler.mp3',
    title: 'Le va a doler',
    artist: 'Alan Ortiz',
    img: 'assets/imagenes/su.jpg',
  ),
  Song(
    audioPath: 'assets/audios/soy_una_nina_cansada.mp3',
    title: 'Soy una niña cansada',
    artist: 'Alan Ortiz',
    img: 'assets/imagenes/ojo.jpg',
  ),
  Song(
    audioPath: 'assets/audios/por_que_jejej.mp3',
    title: 'Por que jejej',
    artist: 'Alan Ortiz',
    img: 'assets/imagenes/jeja.jpg',
  ),
  Song(
    audioPath: 'assets/audios/el_diablo.mp3',
    title: 'El Diablo',
    artist: 'Alan Ortiz',
    img: 'assets/imagenes/ico.jpg',
  ),
];
// Mapa global de todas las canciones (locales + online)
final ValueNotifier<Map<String, Song>> allSongsNotifier = ValueNotifier({});

void initializeAllSongs() {
  final map = <String, Song>{};
  for (var song in database) {
    map[song.audioPath] = song;
  }
  allSongsNotifier.value = map;
}

class AppColors {
  static const redPrimary = Color(0xFFE4192A);
  static const redLight = Color(0xFFFF4444);
  static const redDark = Color(0xFF8B0000);
  static const bgBase = Color(0xFF0D0D0D);
  static const orbeDark = Color(0xFF3D0000);
}

class MusicApp extends StatelessWidget {
  const MusicApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mi App Música',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.bgBase,
        fontFamily: 'Poppins', // Fuente por defecto
        textTheme: const TextTheme(
          displayLarge: TextStyle(fontFamily: 'Poppins'),
          displayMedium: TextStyle(fontFamily: 'Poppins'),
          displaySmall: TextStyle(fontFamily: 'Poppins'),
          headlineLarge: TextStyle(fontFamily: 'Poppins'),
          headlineMedium: TextStyle(fontFamily: 'Poppins'),
          headlineSmall: TextStyle(fontFamily: 'Poppins'),
          titleLarge: TextStyle(fontFamily: 'Poppins'),
          titleMedium: TextStyle(fontFamily: 'Poppins'),
          titleSmall: TextStyle(fontFamily: 'Poppins'),
          bodyLarge: TextStyle(fontFamily: 'Poppins'),
          bodyMedium: TextStyle(fontFamily: 'Poppins'),
          bodySmall: TextStyle(fontFamily: 'Poppins'),
          labelLarge: TextStyle(fontFamily: 'Poppins'),
          labelMedium: TextStyle(fontFamily: 'Poppins'),
          labelSmall: TextStyle(fontFamily: 'Poppins'),
        ),
      ),
      home: const AppShell(),
    );
  }
}

enum AppScreen {
  welcome,
  login,
  home,
  search,
  notifications,
  nowPlaying,
  online,
  estilos,
  profile,
  profileSetup,
  favorites,
  downloads,
}

class MiniPlayer extends StatelessWidget {
  final Song song;
  final bool isPlaying;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final VoidCallback onTap;
  // Los parámetros progress, currentTime, totalTime ya no son necesarios
  // pero los mantienes en el constructor para no romper llamadas existentes.
  // Si quieres limpiar, elimínalos de la definición y de las llamadas.

  const MiniPlayer({
    super.key,
    required this.song,
    required this.isPlaying,
    required this.onPlayPause,
    required this.onNext,
    required this.onPrev,
    required this.onTap,
    this.progress = 0.0,
    this.currentTime = '0:00',
    this.totalTime = '0:00',
  });

  // Puedes eliminar estos tres parámetros si también los quitas de las llamadas
  final double progress;
  final String currentTime;
  final String totalTime;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.85),
          borderRadius: BorderRadius.circular(
            16,
          ), // ← todas las esquinas redondeadas
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Row(
          children: [
            // Imagen
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: buildImage(
                song.img,
                width: 56,
                height: 56,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 12),
            // Título y artista
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            // Botones de control
            Row(
              children: [
                ScaleBtn(
                  onTap: onPrev,
                  child: SvgPicture.asset(
                    'assets/iconos/back.svg',
                    width: 20,
                    height: 20,
                  ),
                ),
                const SizedBox(width: 12),
                // Play/Pause
                ValueListenableBuilder<bool>(
                  valueListenable: audioPlayerService.isPlayingNotifier,
                  builder: (context, isPlaying, _) {
                    return ScaleBtn(
                      onTap: onPlayPause,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF16181E).withOpacity(0.95),
                        ),
                        child: Center(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            child: SvgPicture.asset(
                              isPlaying
                                  ? 'assets/iconos/Pause1.svg'
                                  : 'assets/iconos/Play1.svg',
                              key: ValueKey(isPlaying),
                              width: 22,
                              height: 22,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 12),
                // Siguiente
                ScaleBtn(
                  onTap: onNext,
                  child: SvgPicture.asset(
                    'assets/iconos/Next.svg',
                    width: 20,
                    height: 20,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  _AppShellState createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  AppScreen _current = AppScreen.welcome;
  int _navIndex = 0;
  Genre _currentHomeGenre = Genre.musica;
  bool _downloadsShowDeviceFiles = false;
  Song _currentSong = emptySong;
  bool _isPlaying = false;
  List<Song> _currentSongList = database;
  int _currentSongIndex = 0;
  bool _showMiniPlayer = false;
  final bool _forceHideBar = false;
  bool _hasStartedPlaying = false;
  DateTime? _lastBackPressTime;
  bool _isLoadingAuth = false;

  // Para la barra de progreso
  Duration _position = Duration.zero;
  Duration? _duration;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<ProcessingState>? _processingSubscription;

  // Modos de reproducción (puedes hacerlos modificables con setState si quieres)
  final RepeatMode _repeatMode = RepeatMode.all;
  final bool _isShuffle = false;
  late final ValueNotifier<AppScreen> _currentScreenNotifier;
  // ---------- Ciclo de vida ----------
  @override
  void initState() {
    super.initState();
    _currentScreenNotifier = ValueNotifier(AppScreen.welcome);

    // Sincronizar estado de reproducción
    _isPlaying = audioPlayerService.isPlayingNotifier.value;

    // Listener de autenticación
    FirebaseAuth.instance.authStateChanges().listen((User? user) async {
      print('🔐 authStateChanges: user = $user');

      if (user != null) {
        // 🔄 Mostrar overlay de carga
        _safeSetState(() => _isLoadingAuth = true);

        print('✅ Usuario autenticado: ${user.uid}');
        try {
          final doc = await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get();
          print('📄 Documento Firestore: ${doc.data()}');
          final hasCompleteProfile =
              doc.exists &&
              (doc.data()?['nickname']?.isNotEmpty == true) &&
              (doc.data()?['avatarUrl']?.isNotEmpty == true);
          print('✅ hasCompleteProfile = $hasCompleteProfile');

          if (hasCompleteProfile) {
            final nickname = doc.data()?['nickname'] ?? 'Usuario';
            final avatarUrl = doc.data()?['avatarUrl'] ?? '';
            final avatarHasOwnCircle =
                doc.data()?['avatarHasOwnCircle'] ?? false;
            userProfileNotifier.value = UserProfile(
              nickname: nickname,
              avatarUrl: avatarUrl,
              avatarHasOwnCircle: avatarHasOwnCircle,
              isLoaded: true,
            );
            await DownloadSyncService.loadDownloadsFromCloud();

            final favoritesList =
                (doc.data()?['favorites'] as List?)?.cast<String>() ?? [];
            favoriteNotifier.value = Set.of(favoritesList);
            favoriteNotifier.addListener(saveFavoritesToFirestore);

            // ✅ Ocultar overlay y navegar a Home
            _safeSetState(() => _isLoadingAuth = false);
            _resetPlayer();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              navigate(AppScreen.home);
              _updateMiniPlayerVisibility();
            });
          } else {
            // Perfil incompleto: ocultar overlay y navegar a ProfileSetup
            _safeSetState(() => _isLoadingAuth = false);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              navigate(AppScreen.profileSetup);
            });
          }
        } catch (e) {
          // ❌ Error: ocultar overlay y mostrar mensaje
          _safeSetState(() => _isLoadingAuth = false);
          print('❌ Error al cargar perfil: $e');
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Error al cargar perfil: $e')));
          // Opcional: navegar a login de nuevo? (ya estamos en login)
        }
      } else {
        // Usuario no autenticado: ocultar overlay y navegar a welcome
        _safeSetState(() => _isLoadingAuth = false);
        _resetPlayer();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _hasStartedPlaying = false;
          navigate(AppScreen.welcome);
        });
      }
    });

    // Suscripciones al reproductor (una sola vez, fuera del listener)
    _positionSubscription = audioPlayerService.player.positionStream.listen((
      pos,
    ) {
      if (mounted) setState(() => _position = pos);
    });
    _durationSubscription = audioPlayerService.player.durationStream.listen((
      dur,
    ) {
      if (mounted) setState(() => _duration = dur);
    });
    _processingSubscription = audioPlayerService.player.processingStateStream
        .listen((state) {
          if (state == ProcessingState.completed) _onSongFinished();
        });
    audioPlayerService.isPlayingNotifier.addListener(() {
      if (mounted) {
        setState(() {
          _isPlaying = audioPlayerService.isPlayingNotifier.value;
        });
      }
    });
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _processingSubscription?.cancel();
    super.dispose();
  }

  // ---------- Métodos de navegación y control ----------
  void navigate(
    AppScreen target, {
    int? navIndex,
    bool showDeviceFiles = false,
  }) {
    print(
      '🔀 navigate: target = $target, current = $_current',
    ); // 👈 Agrega esto
    if (_current == target) {
      print('⚠️ target es igual a current, no se navega');
      return;
    }
    _currentScreenNotifier.value = target;
    _safeSetState(() {
      _downloadsShowDeviceFiles = showDeviceFiles;
      _current = target;
      if (navIndex != null) _navIndex = navIndex;
    });
    _updateMiniPlayerVisibility();
  }

  // Cambiar la firma del método
  void playSongFromList(Song song, List<Song> songList) {
    final index = songList.indexWhere((s) => s.audioPath == song.audioPath);
    if (index == -1) return;
    _safeSetState(() {
      _currentSong = song;
      _currentSongList = songList;
      _currentSongIndex = index;
      _hasStartedPlaying = true;
    });
    navigate(AppScreen.nowPlaying);
  }

  void playSongFromFavorites(Song song) {
    final favoriteSongs = database
        .where((s) => favoriteNotifier.value.contains(s.audioPath))
        .toList();
    final index = favoriteSongs.indexWhere(
      (s) => s.audioPath == song.audioPath,
    );
    if (index == -1) return;
    _safeSetState(() {
      _currentSong = favoriteSongs[index];
      _currentSongList = favoriteSongs;
      _currentSongIndex = index;
      _isPlaying = false;
      _hasStartedPlaying = true;
    });
    audioPlayerService.loadSong(song.audioPath, autoPlay: false);
    navigate(AppScreen.nowPlaying);
  }

  void togglePlay() {
    final current = audioPlayerService.isPlayingNotifier.value;
    // 🔥 Actualización optimista: el icono cambia inmediatamente
    audioPlayerService.isPlayingNotifier.value = !current;

    // Ejecutar la acción real
    if (current) {
      audioPlayerService.pause();
    } else {
      audioPlayerService.play();
    }
  }

  void _openNowPlayingFromMini() {
    navigate(AppScreen.nowPlaying);
  }

  void _nextSong() {
    if (_currentSongList.isEmpty) return;
    int nextIndex = _currentSongIndex + 1;
    if (nextIndex >= _currentSongList.length) {
      if (_repeatMode == RepeatMode.all) {
        nextIndex = 0;
      } else {
        return;
      }
    }
    _changeSongByIndex(nextIndex);
  }

  void _prevSong() {
    if (_currentSongList.isEmpty) return;
    int prevIndex = _currentSongIndex - 1;
    if (prevIndex < 0) {
      if (_repeatMode == RepeatMode.all) {
        prevIndex = _currentSongList.length - 1;
      } else {
        return;
      }
    }
    _changeSongByIndex(prevIndex);
  }

  void _changeSongByIndex(int newIndex) {
    if (newIndex == _currentSongIndex) return;
    final newSong = _currentSongList[newIndex];
    _safeSetState(() {
      _currentSong = newSong;
      _currentSongIndex = newIndex;
    });
    audioPlayerService.loadSong(newSong.audioPath, autoPlay: _isPlaying);
    _updateMiniPlayerVisibility();
  }

  void _onSongFinished() {
    if (_repeatMode == RepeatMode.one) {
      audioPlayerService.seek(Duration.zero);
      audioPlayerService.play();
      return;
    }
    if (_isShuffle) {
      if (_currentSongList.length <= 1) return;
      int newIndex;
      do {
        newIndex = Random().nextInt(_currentSongList.length);
      } while (newIndex == _currentSongIndex);
      _changeSongByIndex(newIndex);
      return;
    }
    if (_currentSongIndex + 1 < _currentSongList.length) {
      _nextSong();
    } else if (_repeatMode == RepeatMode.all) {
      _changeSongByIndex(0);
    } else {
      audioPlayerService.stop();
      _safeSetState(() => _isPlaying = false);
    }
  }

  void _updateMiniPlayerVisibility() {
    final shouldShow =
        _hasStartedPlaying &&
        _currentSong.title.isNotEmpty &&
        _current != AppScreen.nowPlaying;
    if (shouldShow != _showMiniPlayer) {
      _safeSetState(() => _showMiniPlayer = shouldShow);
    }
  }

  void _resetPlayer() {
    _hasStartedPlaying = false;
    _currentSong = emptySong;
    _currentSongList = [];
    _currentSongIndex = -1;
    _isPlaying = false;
    _showMiniPlayer = false;
    audioPlayerService.stop();
    // Opcional: cargar una canción vacía para limpiar
    audioPlayerService.loadSong('', autoPlay: false);
  }

  String _fmt(Duration? d) {
    if (d == null) return '0:00';
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _safeSetState(VoidCallback fn) {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.idle) {
      setState(fn);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(fn);
      });
    }
  }

  Future<void> saveFavoritesToFirestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final favoritesList = favoriteNotifier.value.toList();
    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      'favorites': favoritesList,
    }, SetOptions(merge: true));
  }

  bool get _showNav =>
      !_forceHideBar &&
      _current != AppScreen.nowPlaying &&
      _current != AppScreen.notifications &&
      _current != AppScreen.login &&
      _current != AppScreen.welcome &&
      _current != AppScreen.profileSetup;

  Future<bool> _onWillPop() async {
    // Pantallas principales donde se muestra el mensaje de doble toque
    final List<AppScreen> mainScreens = [
      AppScreen.home,
      AppScreen.search,
      AppScreen.profile,
      AppScreen.favorites,
      AppScreen.downloads,
      AppScreen.notifications,
    ];

    if (mainScreens.contains(_current)) {
      if (_lastBackPressTime != null &&
          DateTime.now().difference(_lastBackPressTime!) <
              const Duration(seconds: 2)) {
        return true; // salir
      } else {
        _lastBackPressTime = DateTime.now();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Presiona de nuevo para salir'),
            duration: Duration(seconds: 2),
          ),
        );
        return false;
      }
    } else if (_current == AppScreen.nowPlaying) {
      navigate(AppScreen.home);
      return false;
    } else if (_current == AppScreen.profileSetup) {
      navigate(AppScreen.login);
      return false;
    } else if (_current == AppScreen.welcome || _current == AppScreen.login) {
      return true; // salir directamente
    } else {
      // Para otras pantallas (ej. search, notificaciones) ir a Home
      navigate(AppScreen.home);
      return false;
    }
  }

  // ---------- Build ----------
  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        backgroundColor: AppColors.bgBase,
        body: Stack(
          children: [
            // Fondo animado (solo en welcome/login)
            if (_current == AppScreen.welcome || _current == AppScreen.login)
              AnimatedBackground(currentScreenNotifier: _currentScreenNotifier),

            // Imagen de Pochita (solo en login)
            if (_current == AppScreen.login)
              Positioned(
                right: 3,
                top: 125,
                child: Image.asset(
                  'assets/imagenes/Pochitafinal.jpg',
                  width: 105,
                  height: 105,
                  fit: BoxFit.contain,
                ),
              ),

            // Contenido principal
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 500),
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position:
                        Tween<Offset>(
                          begin: const Offset(0, 0.2),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOutCubic,
                          ),
                        ),
                    child: child,
                  ),
                );
              },
              child: _buildScreen(),
            ),

            // Miniplayer y BottomNav
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInCubic,
              bottom: _showNav ? 0 : -200,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_showMiniPlayer)
                    Opacity(
                      opacity: _current == AppScreen.nowPlaying ? 0.0 : 1.0,
                      child: IgnorePointer(
                        ignoring: _current == AppScreen.nowPlaying,
                        child: MiniPlayer(
                          song: _currentSong,
                          isPlaying: _isPlaying,
                          onPlayPause: togglePlay,
                          onNext: _nextSong,
                          onPrev: _prevSong,
                          onTap: _openNowPlayingFromMini,
                          progress:
                              (_duration != null &&
                                  _duration!.inMilliseconds > 0)
                              ? _position.inMilliseconds /
                                    _duration!.inMilliseconds
                              : 0.0,
                          currentTime: _fmt(_position),
                          totalTime: _fmt(_duration),
                        ),
                      ),
                    ),
                  _BottomNav(
                    currentIndex: _navIndex,
                    onTap: (i) {
                      final targets = [
                        AppScreen.home,
                        AppScreen.search,
                        AppScreen.nowPlaying,
                        AppScreen.profile,
                      ];
                      if (i == 2) {
                        if (_currentSong == emptySong) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('No hay canción reproduciéndose'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                          return;
                        }
                        navigate(AppScreen.nowPlaying, navIndex: i);
                        return;
                      }
                      navigate(targets[i], navIndex: i);
                    },
                  ),
                ],
              ),
            ),

            // ✅ Overlay de carga (se superpone a todo)
            if (_isLoadingAuth)
              Container(
                width: double.infinity,
                height: double.infinity,
                color: const Color(0xFFE3806E).withOpacity(0.3),
                child: const Center(
                  child: MusicLoader(fillMax: true), // 👈 Ocupa todo lo posible
                ),
              ),
          ],
        ),
      ),
    );
  }

  double get _bottomOffset {
    if (_showNav) return 0;
    double totalHeight = 0;
    if (_showMiniPlayer && _currentSong.title.isNotEmpty) totalHeight += 56;
    totalHeight += 75; // BottomNav
    return -totalHeight - 20; // margen extra
  }

  Widget _buildScreen() {
    switch (_current) {
      case AppScreen.downloads:
        return DownloadsScreen(
          key: const ValueKey('downloads'),
          onBack: () => navigate(AppScreen.profile, navIndex: 3),
          showDeviceFiles: _downloadsShowDeviceFiles,
          onPlaySong: (song) {
            // ⭐ Reproducir la canción descargada
            playSongFromList(song, [song]);
          },
        );
      case AppScreen.welcome:
        return WelcomeScreen(
          key: const ValueKey('welcome'),
          onGetStarted: () => navigate(AppScreen.login),
        );
      case AppScreen.login:
        return LoginScreen(
          key: const ValueKey('login'),
          onLogin: () => navigate(AppScreen.home, navIndex: 0),
        );
      case AppScreen.home:
        return HomeScreen(
          key: const ValueKey('home'),
          initialGenre: _currentHomeGenre,
          onGenreChanged: (genre) => _currentHomeGenre = genre,
          onOpenNowPlaying: (song, songList) =>
              playSongFromList(song, songList),
          onNavigate: navigate,
        );
      case AppScreen.search:
        final searchMode = _currentHomeGenre == Genre.musica
            ? SearchMode.local
            : SearchMode.online;
        return SearchScreen(
          key: const ValueKey('search'),
          onBack: () => navigate(AppScreen.home, navIndex: 0),
          mode: searchMode,
          onPlay: (song, songList) => playSongFromList(song, songList),
        );
      case AppScreen.notifications:
        return NotificationsScreen(
          key: const ValueKey('noti'),
          onBack: () => navigate(AppScreen.home, navIndex: 0),
        );
      case AppScreen.nowPlaying:
        if (_currentSongList.isEmpty) {
          // Si la lista está vacía, redirige a Home
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) navigate(AppScreen.home);
          });
          return const SizedBox.shrink();
        }
        return NowPlayingScreen(
          key: const ValueKey('nowPlaying'),
          songs: _currentSongList,
          initialIndex: _currentSongIndex,
          isPlaying: _isPlaying,
          onTogglePlay: togglePlay,
          onNextSong: _nextSong,
          onPrevSong: _prevSong,
          onSongChange: (song, index) {
            _safeSetState(() {
              _currentSong = song;
              _currentSongIndex = index;
            });
          },
          onBack: () => navigate(AppScreen.home, navIndex: 0),
        );

      case AppScreen.online:
        return PlaceholderScreen(
          key: const ValueKey('online'),
          title: 'Online',
          onBack: () => navigate(AppScreen.home, navIndex: 0),
        );
      case AppScreen.estilos:
        return PlaceholderScreen(
          key: const ValueKey('estilos'),
          title: 'Estilos',
          onBack: () => navigate(AppScreen.home, navIndex: 0),
        );
      case AppScreen.profileSetup:
        return ProfileSetupScreen(
          key: const ValueKey('profileSetup'),
          onProfileSaved: () => navigate(AppScreen.home, navIndex: 0),
        );
      case AppScreen.profile:
        return ProfileScreen(
          key: const ValueKey('profile'),
          onLogout: () => navigate(AppScreen.welcome),
        );
      case AppScreen.favorites:
        return FavoritesScreen(
          key: const ValueKey('favorites'),
          onBack: () => navigate(AppScreen.profile, navIndex: 3),
          onPlaySong: playSongFromFavorites,
        );
    }
  }
}

const Song emptySong = Song(audioPath: '', title: '', artist: '', img: '');

// ==================== PANTALLA DE BIENVENIDA (GET STARTED) ====================
class WelcomeScreen extends StatelessWidget {
  final VoidCallback onGetStarted;
  const WelcomeScreen({super.key, required this.onGetStarted});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Transform.translate(
            offset: const Offset(0, -40),
            child: Text(
              'Bienvenido!',
              style: TextStyle(
                fontFamily: 'Tiny5',
                color: const Color.fromARGB(255, 224, 181, 161),
                fontSize: 50,
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Siente el ritmo en cada rincón',
            style: TextStyle(
              fontFamily: 'HappyMonkey',
              color: const Color(0xFF9A9A9A),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 40),
          ScaleBtn(
            onTap: onGetStarted,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(40),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x66000000),
                    borderRadius: BorderRadius.circular(40),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.2),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Empieza',
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(
                        Icons.arrow_forward_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== FONDO ANIMADO COMPARTIDO (CORREGIDO) ====================
class AnimatedBackground extends StatefulWidget {
  final ValueNotifier<AppScreen> currentScreenNotifier;
  const AnimatedBackground({super.key, required this.currentScreenNotifier});

  @override
  State<AnimatedBackground> createState() => _AnimatedBackgroundState();
}

class _AnimatedBackgroundState extends State<AnimatedBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bgController;
  late final Animation<Offset> _orbTopRightOffset;
  late final Animation<Offset> _orbBottomLeftOffset;
  late final Animation<Offset> _orbBottomRightOffset;
  late final Animation<Offset> _gradientPanelOffset;

  double _getGradientPanelTop() {
    final screen = widget.currentScreenNotifier.value;
    switch (screen) {
      case AppScreen.welcome:
        return -20; // Posición en WelcomeScreen
      case AppScreen.login:
        return 150; // Posición en LoginScreen
      default:
        return 180;
    }
  }

  @override
  void initState() {
    super.initState();
    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat(reverse: true);

    _orbTopRightOffset = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(12, -8),
    ).animate(CurvedAnimation(parent: _bgController, curve: Curves.easeInOut));

    _orbBottomLeftOffset = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(-10, 6),
    ).animate(CurvedAnimation(parent: _bgController, curve: Curves.easeInOut));

    _orbBottomRightOffset = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(8, -5),
    ).animate(CurvedAnimation(parent: _bgController, curve: Curves.easeInOut));

    _gradientPanelOffset = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(5, -6),
    ).animate(CurvedAnimation(parent: _bgController, curve: Curves.easeInOut));

    widget.currentScreenNotifier.addListener(_onScreenChanged);
  }

  void _onScreenChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.currentScreenNotifier.removeListener(_onScreenChanged);
    _bgController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gradientTop = _getGradientPanelTop();
    return Stack(
      children: [
        // CAMBIO AQUÍ: Se cambió Positioned por AnimatedPositioned para suavizar el cambio de 'top'
        AnimatedPositioned(
          duration: const Duration(
            milliseconds: 600,
          ), // Duración de la transformación de fondo
          curve:
              Curves.fastOutSlowIn, // Curva estética y fluida para el recorrido
          left: -2,
          top: gradientTop,
          right: -15,
          bottom: -50,
          child: AnimatedBuilder(
            animation: _bgController,
            builder: (context, child) {
              return Transform.translate(
                offset: _gradientPanelOffset.value,
                child: child,
              );
            },
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(59),
                gradient: RadialGradient(
                  center: const Alignment(-0.70, -0.58),
                  radius: 1.52,
                  colors: [
                    AppColors.redDark.withOpacity(0.85),
                    Colors.black.withOpacity(0.90),
                    AppColors.orbeDark.withOpacity(0.92),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Orbe rojo arriba derecha
        Positioned(
          right: -80,
          top: 60,
          child: AnimatedBuilder(
            animation: _bgController,
            builder: (context, child) {
              return Transform.translate(
                offset: _orbTopRightOffset.value,
                child: child,
              );
            },
            child: Opacity(
              opacity: 0.50,
              child: Container(
                width: 300,
                height: 300,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [AppColors.redPrimary, Colors.transparent],
                  ),
                ),
              ),
            ),
          ),
        ),
        // Orbe rojo abajo izquierda
        Positioned(
          left: -120,
          bottom: 0,
          child: AnimatedBuilder(
            animation: _bgController,
            builder: (context, child) {
              return Transform.translate(
                offset: _orbBottomLeftOffset.value,
                child: child,
              );
            },
            child: Opacity(
              opacity: 0.45,
              child: Container(
                width: 300,
                height: 300,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [AppColors.redDark, Colors.transparent],
                  ),
                ),
              ),
            ),
          ),
        ),
        // Orbe rojo abajo derecha
        Positioned(
          right: -60,
          bottom: 40,
          child: AnimatedBuilder(
            animation: _bgController,
            builder: (context, child) {
              return Transform.translate(
                offset: _orbBottomRightOffset.value,
                child: child,
              );
            },
            child: Opacity(
              opacity: 0.35,
              child: Container(
                width: 280,
                height: 280,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [AppColors.redPrimary, Colors.transparent],
                  ),
                ),
              ),
            ),
          ),
        ),
        // Notas musicales
        Positioned(
          left: -8,
          top: 230,
          child: Transform.rotate(
            angle: -1.17,
            child: Icon(
              Icons.music_note,
              size: 50,
              color: Colors.white.withOpacity(0.07),
            ),
          ),
        ),
        Positioned(
          right: -8,
          top: 250,
          child: Transform.rotate(
            angle: -0.33,
            child: Icon(
              Icons.music_note,
              size: 65,
              color: Colors.white.withOpacity(0.06),
            ),
          ),
        ),
        Positioned(
          right: 340,
          top: 495,
          child: Transform.rotate(
            angle: -0.6,
            child: Icon(
              Icons.headphones,
              size: 52,
              color: Colors.white.withOpacity(0.05),
            ),
          ),
        ),
      ],
    );
  }
}

class LoginScreen extends StatefulWidget {
  final VoidCallback onLogin;
  const LoginScreen({super.key, required this.onLogin});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with TickerProviderStateMixin {
  final _emailOrNickCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _obscurePass = true;
  String _msg = '';
  bool _isLoading = false;
  bool _isLoginMode = true;

  late final AnimationController _switchAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );
  late final Animation<double> _fadeAnim = CurvedAnimation(
    parent: _switchAnim,
    curve: Curves.easeInOut,
  );

  @override
  void initState() {
    super.initState();
    _switchAnim.forward();
  }

  @override
  void dispose() {
    _emailOrNickCtrl.dispose();
    _passCtrl.dispose();
    _switchAnim.dispose();
    super.dispose();
    audioPlayerService.isPlayingNotifier.addListener(() {
      if (mounted) setState(() {});
    });
  }

  // ========== AUTENTICACIÓN (todos los métodos sin cambios) ==========
  Future<void> _signInWithGoogle() async {
    setState(() {
      _isLoading = true;
      _msg = '';
    });

    try {
      if (kIsWeb) {
        // ---------- FLUJO WEB (con popup) ----------
        final GoogleAuthProvider googleProvider = GoogleAuthProvider();
        googleProvider.setCustomParameters({'prompt': 'select_account'});
        final UserCredential userCredential = await FirebaseAuth.instance
            .signInWithPopup(googleProvider);
        if (userCredential.user == null) {
          setState(() {
            _isLoading = false;
            _msg = 'Inicio de sesión cancelado';
          });
          return;
        }
        // El listener de authStateChanges navegará automáticamente.
      } else {
        // ---------- FLUJO ANDROID (simplificado) ---------
        final GoogleSignIn googleSignIn = GoogleSignIn.instance;
        await googleSignIn.initialize();
        final GoogleSignInAccount googleUser = await googleSignIn
            .authenticate();
        final GoogleSignInAuthentication googleAuth = googleUser.authentication;
        final credential = GoogleAuthProvider.credential(
          idToken: googleAuth.idToken,
        );
        await FirebaseAuth.instance.signInWithCredential(credential);
      }

      // Si llegamos aquí (solo Android, porque en Web con popup no se llega
      // si el popup se cierra sin error, pero igual)
      if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (kIsWeb && e is FirebaseAuthException) {
        if (e.code == 'popup-closed-by-user' ||
            e.code == 'auth/cancelled-popup-request') {
          setState(() {
            _msg = 'Inicio de sesión cancelado';
            _isLoading = false;
          });
          return;
        }
      }
      setState(() {
        _msg = 'Error al iniciar sesión con Google: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  Future<void> _loginWithEmailOrNickname() async {
    final input = _emailOrNickCtrl.text.trim();
    final password = _passCtrl.text.trim();

    if (input.isEmpty) {
      setState(() => _msg = 'Ingresa tu correo o apodo');
      return;
    }
    if (password.isEmpty) {
      setState(() => _msg = 'Ingresa tu contraseña');
      return;
    }

    setState(() {
      _isLoading = true;
      _msg = '';
    });

    try {
      String email;
      if (input.contains('@')) {
        email = input;
      } else {
        final query = await FirebaseFirestore.instance
            .collection('users')
            .where('nickname', isEqualTo: input)
            .limit(1)
            .get();
        if (query.docs.isEmpty) {
          setState(() {
            _msg = 'No hay usuario registrado con ese apodo.';
            _isLoading = false;
          });
          return;
        }
        final data = query.docs.first.data();
        email = data['email'] as String;
        if (email.isEmpty) {
          setState(() {
            _msg = 'Error: el apodo no tiene correo asociado.';
            _isLoading = false;
          });
          return;
        }
      }

      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      print('✅ Inicio de sesión exitoso para: $email');
    } on FirebaseAuthException catch (e) {
      String errorMsg;
      switch (e.code) {
        case 'user-not-found':
        case 'invalid-credential':
          errorMsg = 'Usuario o contraseña incorrectos.';
          break;
        case 'wrong-password':
          errorMsg = '❌ Contraseña incorrecta.';
          break;
        case 'invalid-email':
          errorMsg = 'El correo no es válido.';
          break;
        default:
          errorMsg = 'Error al iniciar sesión: ${e.message}';
      }
      setState(() {
        _msg = errorMsg;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _msg = 'Error inesperado: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  Future<void> _registerWithEmail() async {
    final email = _emailOrNickCtrl.text.trim();
    final password = _passCtrl.text.trim();

    if (email.isEmpty) {
      setState(() => _msg = 'Ingresa tu correo electrónico');
      return;
    }
    if (password.isEmpty) {
      setState(() => _msg = 'Ingresa una contraseña');
      return;
    }
    if (password.length < 6) {
      setState(() => _msg = 'La contraseña debe tener al menos 6 caracteres');
      return;
    }
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _msg = 'Correo electrónico no válido');
      return;
    }

    setState(() {
      _isLoading = true;
      _msg = '';
    });

    try {
      final userCredential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: password);
      final user = userCredential.user;
      if (user == null) throw Exception('No se pudo crear el usuario');

      // El listener de authStateChanges se encargará de navegar
      print('✅ Registro exitoso con email/password');
    } on FirebaseAuthException catch (e) {
      String errorMsg;
      switch (e.code) {
        case 'email-already-in-use':
          errorMsg =
              'Este correo ya está registrado. Intenta iniciar sesión o usa Google.';
          break;
        case 'invalid-email':
          errorMsg = 'El correo electrónico no es válido.';
          break;
        case 'weak-password':
          errorMsg =
              'Contraseña muy débil. Usa al menos 6 caracteres con letras y números.';
          break;
        default:
          errorMsg = 'Error al registrar: ${e.message}';
      }
      setState(() {
        _msg = errorMsg;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _msg = 'Error inesperado: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  void _toggleMode() {
    setState(() {
      _isLoginMode = !_isLoginMode;
      _msg = '';
      _emailOrNickCtrl.clear();
      _passCtrl.clear();
    });
  }

  InputDecoration _fieldDeco(
    String hint,
    String svgUrl, {
    bool isPass = false,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        fontFamily: 'HappyMonkey',
        color: const Color(0xFF9A9A9A),
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
      prefixIcon: Padding(
        padding: const EdgeInsets.all(12),
        child: SvgPicture.asset(
          svgUrl,
          width: 18,
          height: 18,
          colorFilter: const ColorFilter.mode(
            Color(0xFF9A9A9A),
            BlendMode.srcIn,
          ),
        ),
      ),
      suffixIcon: isPass
          ? GestureDetector(
              onTap: () => setState(() => _obscurePass = !_obscurePass),
              child: Icon(
                _obscurePass
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: const Color(0xFF9A9A9A),
                size: 18,
              ),
            )
          : null,
      filled: true,
      fillColor: AppColors.redDark.withOpacity(0.20),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(
          color: Colors.white.withOpacity(0.15),
          width: 0.5,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(
          color: Colors.white.withOpacity(0.15),
          width: 0.5,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.redLight, width: 1.2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: FadeTransition(
        opacity: _fadeAnim,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 260),
              Transform.translate(
                offset: Offset(0, -90),
                child: Text(
                  'Bienvenido!',
                  style: TextStyle(
                    fontFamily: 'Tiny5',
                    color: const Color.fromARGB(255, 224, 181, 161),
                    fontSize: 50,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Transform.translate(
                offset: Offset(0, -87),
                child: Text(
                  _isLoginMode
                      ? 'Inicia sesión con tu cuenta'
                      : 'Crea una nueva cuenta',
                  style: TextStyle(
                    fontFamily: 'HappyMonkey',
                    color: const Color(0xFF9A9A9A),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Transform.translate(
                offset: Offset(0, -80),
                child: Text(
                  _isLoginMode ? 'Correo o apodo' : 'Correo electrónico',
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    color: const Color(0xFF9A9A9A),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Transform.translate(
                offset: Offset(0, -78),
                child: TextField(
                  controller: _emailOrNickCtrl,
                  style: TextStyle(
                    fontFamily: 'Merienda',
                    color: Colors.white,
                    fontSize: 14,
                  ),
                  keyboardType: TextInputType.emailAddress,
                  decoration: _fieldDeco(
                    _isLoginMode
                        ? 'ejemplo@correo.com o tu apodo'
                        : 'tuemail@ejemplo.com',
                    _isLoginMode
                        ? 'assets/iconos/persona.svg'
                        : 'assets/iconos/correo.svg',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Transform.translate(
                offset: Offset(0, -70),
                child: Text(
                  'Contraseña',
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    color: const Color(0xFF9A9A9A),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Transform.translate(
                offset: Offset(0, -68),
                child: TextField(
                  controller: _passCtrl,
                  style: TextStyle(
                    fontFamily: 'HappyMonkey',
                    color: Colors.white,
                    fontSize: 14,
                  ),
                  obscureText: _obscurePass,
                  decoration: _fieldDeco(
                    'Contraseña',
                    'assets/iconos/contraseña.svg',
                    isPass: true,
                  ),
                ),
              ),
              if (_isLoginMode) ...[
                const SizedBox(height: 10),
                Transform.translate(
                  offset: Offset(0, -58),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '¿Olvidaste tu contraseña?',
                      style: TextStyle(
                        fontFamily: 'Merienda',
                        color: const Color(0xFF9A9A9A),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 22),
              if (_msg.isNotEmpty) ...[
                Text(
                  _msg,
                  style: TextStyle(
                    fontFamily: 'Merienda',
                    color: const Color(0xFFF87171),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Transform.translate(
                offset: Offset(0, -48),
                child: ShimmerBtn(
                  label: _isLoginMode ? 'Iniciar sesión' : 'Registrarse',
                  onTap: _isLoginMode
                      ? _loginWithEmailOrNickname
                      : _registerWithEmail,
                ),
              ),
              // Separador y botones sociales
              Transform.translate(
                offset: const Offset(0, -30),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 0.5,
                        color: Colors.white.withOpacity(0.15),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'O continuar con',
                        style: TextStyle(
                          fontFamily: 'Merienda',
                          color: const Color(0xFF9A9A9A),
                          fontSize: 11,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Container(
                        height: 0.5,
                        color: Colors.white.withOpacity(0.15),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Transform.translate(
                offset: const Offset(0, -15),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _SocialBtn(
                      icon: Icons.g_mobiledata_rounded,
                      iconColor: const Color(0xFFEA4335),
                      onTap: _signInWithGoogle,
                    ),
                    const SizedBox(width: 14),
                    _SocialBtn(
                      icon: Icons.apple_rounded,
                      iconColor: Colors.white,
                      onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Inicio con Apple próximo'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    _SocialBtn(
                      icon: Icons.facebook_rounded,
                      iconColor: const Color(0xFF1877F2),
                      onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Inicio con Facebook próximo'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 26),
              Transform.translate(
                offset: const Offset(0, 10),
                child: Center(
                  child: GestureDetector(
                    onTap: _toggleMode,
                    child: RichText(
                      text: TextSpan(
                        style: TextStyle(
                          fontFamily: 'Merienda',
                          color: const Color(0xFF9A9A9A),
                          fontSize: 13,
                        ),
                        children: [
                          TextSpan(
                            text: _isLoginMode
                                ? "¿No tienes una cuenta? "
                                : '¿Ya tienes una cuenta? ',
                          ),
                          TextSpan(
                            text: _isLoginMode
                                ? 'Registrarse'
                                : 'Iniciar sesión',
                            style: TextStyle(
                              fontFamily: 'Poppins',
                              color: AppColors.redLight,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 36),
            ],
          ),
        ),
      ),
    );
  }
}

class _SocialBtn extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final VoidCallback onTap;
  const _SocialBtn({
    required this.icon,
    required this.iconColor,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => ScaleBtn(
    onTap: onTap,
    child: Container(
      width: 58,
      height: 44,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white.withOpacity(0.15), width: 0.5),
      ),
      child: Center(child: Icon(icon, color: iconColor, size: 24)),
    ),
  );
}

// ==================== PANTALLA DE REGISTRO (APODO Y AVATAR) ====================
class ProfileSetupScreen extends StatefulWidget {
  final VoidCallback onProfileSaved;
  const ProfileSetupScreen({super.key, required this.onProfileSaved});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _AvatarOption {
  final String url;
  final bool hasOwnCircle; // true = ya trae su propio círculo (ej. pollo.svg)
  const _AvatarOption({required this.url, required this.hasOwnCircle});
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _nicknameController = TextEditingController();
  String _selectedAvatarUrl = '';
  bool _isSaving = false;
  String _error = '';

  final List<_AvatarOption> _avatarOptions = [
    // Este es el avatar especial (con círculo propio) - usa la URL de tu botón de perfil
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/principal/pollo.svg',
      hasOwnCircle: true,
    ),
    // Los demás son sin círculo propio (se mostrarán dentro de un círculo de fondo)
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%20120.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%20118.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%2019.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%2020.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%2021.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%2022.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%2023.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%2024.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%2025.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%2026.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%2027.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%203.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%2039.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%204.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%2041.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%2042.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%2043.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%205.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%206.svg',
      hasOwnCircle: false,
    ),
    _AvatarOption(
      url:
          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/377d45fae332ce4fc6d1c9e173bb90312470687e/Group%207.svg',
      hasOwnCircle: false,
    ),
  ];

  @override
  void initState() {
    super.initState();
    if (_avatarOptions.isNotEmpty) {
      _selectedAvatarUrl = _avatarOptions.first.url;
    }
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    final nickname = _nicknameController.text.trim();
    if (nickname.isEmpty) {
      setState(() => _error = 'Por favor ingresa un apodo');
      return;
    }
    if (_selectedAvatarUrl.isEmpty) {
      setState(() => _error = 'Por favor selecciona un avatar');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = '';
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Usuario no autenticado');

      final existingUser = await FirebaseFirestore.instance
          .collection('users')
          .where('nickname', isEqualTo: nickname)
          .limit(1)
          .get();
      if (existingUser.docs.isNotEmpty &&
          existingUser.docs.first.id != user.uid) {
        setState(() => _error = 'El apodo ya está en uso. Elige otro.');
        setState(() => _isSaving = false);
        return;
      }

      final selectedOption = _avatarOptions.firstWhere(
        (opt) => opt.url == _selectedAvatarUrl,
      );

      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'nickname': nickname,
        'avatarUrl': _selectedAvatarUrl,
        'avatarHasOwnCircle': selectedOption.hasOwnCircle,
        'email': user.email,
        'createdAt': FieldValue.serverTimestamp(),
      });

      // ✅ ACTUALIZAR EL NOTIFICADOR GLOBAL
      userProfileNotifier.value = UserProfile(
        nickname: nickname,
        avatarUrl: _selectedAvatarUrl,
        avatarHasOwnCircle: selectedOption.hasOwnCircle,
        isLoaded: true,
      );

      widget.onProfileSaved();
    } catch (e) {
      setState(() => _error = 'Error al guardar perfil: ${e.toString()}');
    } finally {
      setState(() => _isSaving = false);
    }
  }

  Widget _buildAvatarContent(_AvatarOption option) {
    if (option.hasOwnCircle) {
      // Avatar con círculo propio (pollo): se muestra directo, sin fondo adicional
      return ClipOval(
        child: SvgPicture.network(
          option.url,
          width: 60,
          height: 60,
          fit: BoxFit.cover, // Cambiado a cover para llenar el círculo
          placeholderBuilder: (context) => Container(
            color: const Color(0xFF3F3F46),
            child: const MusicLoader(), // 80% del ancho
          ),
          errorBuilder: (context, error, stackTrace) => Container(
            color: const Color(0xFF3F3F46),
            child: const Icon(Icons.person, color: Colors.white70),
          ),
        ),
      );
    } else {
      // Avatares sin círculo: fondo gris + padding
      return Container(
        width: 60,
        height: 60,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFF2C2C2E),
        ),
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: SvgPicture.network(
            option.url,
            width: 44,
            height: 44,
            fit: BoxFit.contain,
            placeholderBuilder: (context) => const Center(child: MusicLoader()),
            errorBuilder: (context, error, stackTrace) =>
                const Icon(Icons.person, color: Colors.white70),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgBase,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),
              Text(
                'Completa tu perfil',
                style: TextStyle(
                  fontFamily: 'Stylish',
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Elige cómo te llamaremos y tu avatar',
                style: TextStyle(
                  fontFamily: 'Poppins',
                  color: const Color(0xFF9A9A9A),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 32),
              Text(
                'Apodo',
                style: TextStyle(
                  fontFamily: 'Poppins',
                  color: const Color(0xFF9A9A9A),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              TextField(
                controller: _nicknameController,
                style: TextStyle(
                  fontFamily: 'HappyMonkey',
                  color: Colors.white,
                  fontSize: 14,
                ),
                decoration: InputDecoration(
                  hintText: 'Ej. Pepito',
                  hintStyle: TextStyle(
                    fontFamily: 'HappyMonkey',
                    color: const Color(0xFF9A9A9A),
                    fontSize: 14,
                  ),
                  filled: true,
                  fillColor: AppColors.redDark.withOpacity(0.20),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Avatar',
                style: TextStyle(
                  fontFamily: 'Poppins',
                  color: const Color(0xFF9A9A9A),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 100,
                child: GridView.builder(
                  shrinkWrap: true,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    childAspectRatio: 1,
                    crossAxisSpacing: 12,
                  ),
                  itemCount: _avatarOptions.length,
                  itemBuilder: (ctx, i) {
                    final option = _avatarOptions[i];
                    final isSelected = option.url == _selectedAvatarUrl;
                    return GestureDetector(
                      onTap: () =>
                          setState(() => _selectedAvatarUrl = option.url),
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected
                                ? AppColors.redLight
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                        child: _buildAvatarContent(option),
                      ),
                    );
                  },
                ),
              ),
              const Spacer(),
              if (_error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _error,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
              if (_isSaving)
                const Center(child: MusicLoader())
              else
                ShimmerBtn(label: 'Guardar perfil', onTap: _saveProfile),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== HOME SCREEN (con nickname y avatar sincronizados) ====================
enum Genre { online, musica, estilos }

enum SearchMode { local, online }

class HomeScreen extends StatefulWidget {
  final Genre initialGenre;
  final Function(Genre) onGenreChanged;
  final Function(Song, List<Song>) onOpenNowPlaying;
  final Function(AppScreen, {int? navIndex}) onNavigate;

  const HomeScreen({
    super.key,
    required this.initialGenre,
    required this.onGenreChanged,
    required this.onOpenNowPlaying,
    required this.onNavigate,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Genre _genre;
  bool _isLoading = false;
  bool _isConnected = true;
  List<Song> _onlineTracks = [];
  final List<Song> _estilosTracks = [];
  String? _onlineErrorMessage; // Mensaje de error específico


  String get _greeting {
    final h = DateTime.now().hour;
    if (h >= 5 && h < 12) return 'Buenos días';
    if (h >= 12 && h < 18) return 'Buenas tardes';
    return 'Buenas noches';
  }

  @override
  void initState() {
    super.initState();
    _genre = widget.initialGenre;
    _checkConnectivityAndLoadData();
  }

  Widget _buildRetryButton(VoidCallback onPressed) {
    return ScaleBtn(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppColors.redPrimary, // Borde rojo intenso
            width: 2,
          ),
          color: AppColors.redPrimary.withOpacity(
            0.25,
          ), // Fondo rojo claro con opacidad
          boxShadow: [
            BoxShadow(
              color: AppColors.redPrimary.withOpacity(0.15),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Text(
          'Reintentar',
          style: TextStyle(
            color: AppColors.redLight, // Texto rojo claro
            fontWeight: FontWeight.w600,
            fontSize: 14,
            fontFamily: 'Poppins',
          ),
        ),
      ),
    );
  }

  Future<void> _checkConnectivityAndLoadData() async {
    final connected = await ConnectivityService.isConnected();
    setState(() => _isConnected = connected);
    if (connected) {
      await _loadOnlineData();
    }
  }

Future<void> _loadOnlineData() async {
  setState(() {
    _isLoading = true;
    _onlineErrorMessage = null;
  });

  try {
    final tracks = await ProxyYoutubeService().getTrendingSongs();
    setState(() {
      _onlineTracks = tracks;
      _isLoading = false;
    });
    // 🔄 Actualizar mapa global
    final currentMap = Map<String, Song>.from(allSongsNotifier.value);
    for (var song in tracks) {
      currentMap[song.audioPath] = song;
    }
    allSongsNotifier.value = currentMap;
  } catch (e, stack) {
      print('Error cargando Online: $e');
      print('Stack: $stack');
      setState(() {
        _isLoading = false;
        _onlineTracks = [];
        _onlineErrorMessage = _parseErrorMessage(e);
      });
    }
  }

  /// Traduce errores a mensajes amigables para el usuario
  /// Traduce errores a mensajes amigables para el usuario
  /// Traduce errores a mensajes amigables para el usuario
  String _parseErrorMessage(dynamic error) {
    if (error is DioException) {
      return _parseDioError(error);
    } else if (error is SocketException) {
      return '🌐 No hay conexión a internet. Verifica tu red.';
    } else {
      // Para cualquier otro error, intentamos extraer información útil
      final errorString = error.toString();
      if (errorString.contains('Failed to fetch') ||
          errorString.contains('NetworkError')) {
        if (errorString.contains('localhost') ||
            errorString.contains('127.0.0.1')) {
          return 'No se puede conectar al servidor local. Asegúrate de que el servidor esté encendido.';
        }
        return 'No se pudo conectar al servidor. Puede estar apagado o la URL es incorrecta.';
      }
      // Si no podemos identificar el error, mostramos un mensaje genérico sin detalles técnicos
      return 'Error inesperado. Intenta de nuevo más tarde.';
    }
  }

  String _parseDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
        return '⏱️ El servidor no responde. Puede estar apagado o la red está lenta.';
      case DioExceptionType.connectionError:
        return '📡 No se pudo conectar al servidor. Revisa tu conexión.';
      case DioExceptionType.cancel:
        return 'La solicitud fue cancelada.';
      case DioExceptionType.unknown:
        if (e.error is SocketException) {
          return '🌐 No hay conexión a internet o el servidor no responde.';
        }
        // Si hay respuesta HTTP, mostramos el código
        if (e.response != null) {
          final status = e.response!.statusCode;
          if (status != null) {
            // 👈 Añade esta comprobación
            if (status == 404) {
              return '❌ El servidor no se encuentra (404). Verifica la URL.';
            } else if (status == 500) {
              return '⚠️ Error interno del servidor (500).';
            } else if (status == 502 || status == 503) {
              return '🔴 El servidor está caído o en mantenimiento.';
            } else if (status >= 400) {
              return '⚠️ Error del servidor (código $status).';
            }
          }
        }
        // Verificar si el mensaje contiene 'Failed to fetch' u otros típicos
        final msg = e.message ?? '';
        if (msg.contains('Failed to fetch') || msg.contains('NetworkError')) {
          if (msg.contains('localhost') || msg.contains('127.0.0.1')) {
            return '🔴 No se puede conectar al servidor local. Asegúrate de que el servidor esté encendido y accesible.';
          }
          return '🔴 No se pudo conectar al servidor. Puede estar apagado o la URL es incorrecta.';
        }
        return '⚠️ Error desconocido: ${e.message}';
      default:
        return '⚠️ Error de red: ${e.message}';
    }
  }

  // Widget para el contenido de la pestaña "Online"
  Widget _buildOnlineContent() {
    if (!_isConnected) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.wifi_off, color: Colors.white60, size: 64),
            const SizedBox(height: 16),
            Text(
              'No estás conectado a internet',
              style: TextStyle(
                fontFamily: 'Merienda',
                color: Colors.white60,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Conéctate para ver las canciones del mundo',
              style: TextStyle(
                fontFamily: 'Poppins',
                color: Color(0xFF71717A),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),
            _buildRetryButton(_checkConnectivityAndLoadData),
          ],
        ),
      );
    }

    if (_isLoading) {
      return const Center(child: MusicLoader(fillMax: true));
    }

    if (_onlineTracks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, color: Colors.white60, size: 64),
              const SizedBox(height: 16),
              Text(
                _onlineErrorMessage ?? 'No hay canciones disponibles',
                style: TextStyle(
                  fontFamily: 'Merienda',
                  color: Colors.white60,
                  fontSize: 18,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Intenta de nuevo más tarde',
                style: TextStyle(
                  fontFamily: 'Poppins',
                  color: Color(0xFF71717A),
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              _buildRetryButton(_loadOnlineData),
            ],
          ),
        ),
      );
    }

    // ✅ Contenido con scroll
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        children: [
          Text(
            'Lanzamientos más nuevos',
            style: TextStyle(
              fontFamily: 'Merienda',
              color: Color(0xFFE5E5E5),
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          AlbumCarousel(
            songs: _onlineTracks.take(4).toList(),
            cardWidth: 191,
            cardHeight: 202,
            onTap: (song) => widget.onOpenNowPlaying(song, _onlineTracks),
          ),
          const SizedBox(height: 28),
          Text(
            'Géneros',
            style: TextStyle(
              fontFamily: 'Merienda',
              color: Color(0xFFE5E5E5),
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          AlbumCarousel(
            songs: _onlineTracks.skip(4).take(4).toList(),
            cardWidth: 192,
            cardHeight: 208,
            onTap: (song) => widget.onOpenNowPlaying(song, _onlineTracks),
          ),
          // Espacio extra al final para separación
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  // Widget para la pestaña "Estilos"
  Widget _buildEstilosContent() {
    if (!_isConnected) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.wifi_off, color: Colors.white60, size: 64),
            const SizedBox(height: 16),
            Text(
              'No estás conectado a internet',
              style: TextStyle(
                fontFamily: 'Merienda',
                color: Colors.white60,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Conéctate para ver estilos musicales',
              style: TextStyle(
                fontFamily: 'Poppins',
                color: Color(0xFF71717A),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),
            _buildRetryButton(_checkConnectivityAndLoadData),
          ],
        ),
      );
    }

    if (_isLoading) {
      return const Center(child: MusicLoader());
    }
    if (_estilosTracks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.music_off, color: Colors.white60, size: 64),
            const SizedBox(height: 16),
            Text(
              'No hay estilos disponibles',
              style: TextStyle(
                fontFamily: 'Merienda',
                color: Colors.white60,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Intenta de nuevo más tarde',
              style: TextStyle(
                fontFamily: 'Poppins',
                color: Color(0xFF71717A),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),
            _buildRetryButton(_loadOnlineData),
          ],
        ),
      );
    }
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        children: [
          Text(
            'Estilos populares',
            style: TextStyle(
              fontFamily: 'Merienda',
              color: Color(0xFFE5E5E5),
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          AlbumCarousel(
            songs: _estilosTracks.take(4).toList(),
            cardWidth: 191,
            cardHeight: 202,
            onTap: (song) => widget.onOpenNowPlaying(song, _estilosTracks),
          ),
          const SizedBox(height: 28),
          Text(
            'Recomendados',
            style: TextStyle(
              fontFamily: 'Merienda',
              color: Color(0xFFE5E5E5),
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          AlbumCarousel(
            songs: _estilosTracks.skip(4).take(4).toList(),
            cardWidth: 192,
            cardHeight: 208,
            onTap: (song) => widget.onOpenNowPlaying(song, _estilosTracks),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildAvatarWidget(String? avatarUrl, bool? avatarHasOwnCircle) {
    // (sin cambios, igual que antes)
    if (avatarUrl == null || avatarUrl.isEmpty) {
      return const Icon(Icons.person, color: Colors.white70, size: 16);
    }
    if (avatarHasOwnCircle == true) {
      return ClipOval(
        child: SvgPicture.network(
          avatarUrl,
          width: 24,
          height: 24,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) =>
              const Icon(Icons.person, color: Colors.white70, size: 16),
        ),
      );
    } else {
      return Container(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFF2C2C2E),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4.0),
          child: SvgPicture.network(
            avatarUrl,
            width: 16,
            height: 16,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) =>
                const Icon(Icons.person, color: Colors.white70, size: 16),
          ),
        ),
      );
    }
  }

  // Widget para el contenido de la pestaña "Musica"
  Widget _buildMusicaContent() {
    return Column(
      children: [
        AlbumCarousel(
          songs: database.sublist(0, 4), // ✅ usa database
          cardWidth: 191,
          cardHeight: 202,
          onTap: (song) =>
              widget.onOpenNowPlaying(song, database), // ✅ pasa database
        ),
        const SizedBox(height: 28),
        Text(
          'Introduciones Cortas',
          style: TextStyle(
            fontFamily: 'Merienda',
            color: Color(0xFFE5E5E5),
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        AlbumCarousel(
          songs: database.sublist(4, 8), // ✅ usa database
          cardWidth: 192,
          cardHeight: 208,
          onTap: (song) =>
              widget.onOpenNowPlaying(song, database), // ✅ pasa database
        ),
      ],
    );
  }

  // Widget para contenido placeholder (Online y Estilos)
  Widget _buildPlaceholderContent(String title1, String title2) {
    return Column(
      children: [
        // Primer carrusel vacío
        Text(
          title1,
          style: TextStyle(
            fontFamily: 'Merienda',
            color: Color(0xFFE5E5E5),
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        _EmptyAlbumCarousel(),
        const SizedBox(height: 28),
        // Segundo carrusel vacío
        Text(
          title2,
          style: TextStyle(
            fontFamily: 'Merienda',
            color: Color(0xFFE5E5E5),
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        _EmptyAlbumCarousel(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UserProfile>(
      valueListenable: userProfileNotifier,
      builder: (context, profile, _) {
        final nickname = profile.isLoaded ? profile.nickname : 'Cargando...';
        final avatarUrl = profile.avatarUrl;
        final avatarHasOwnCircle = profile.avatarHasOwnCircle;

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header (saludo, avatar, íconos)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _greeting,
                          style: TextStyle(
                            fontFamily: 'HappyMonkey',
                            color: Color(0xFFD6D3D1),
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          nickname,
                          style: TextStyle(
                            fontFamily: 'Merienda',
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        ScaleBtn(
                          onTap: () =>
                              widget.onNavigate(AppScreen.profile, navIndex: 3),
                          child: ClipOval(
                            child: Container(
                              width: 24,
                              height: 24,
                              color: const Color(0xFF3F3F46),
                              child: _buildAvatarWidget(
                                avatarUrl,
                                avatarHasOwnCircle,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        ScaleBtn(
                          onTap: () =>
                              widget.onNavigate(AppScreen.search, navIndex: 1),
                          child: RepaintBoundary(
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: Center(
                                child: SvgPicture.asset(
                                  'assets/iconos/busqueda.svg',
                                  width: 20,
                                  height: 20,
                                  fit: BoxFit.contain,
                                  colorFilter: const ColorFilter.mode(
                                    Colors.white,
                                    BlendMode.srcIn,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        ScaleBtn(
                          onTap: () =>
                              widget.onNavigate(AppScreen.notifications),
                          child: RepaintBoundary(
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: Center(
                                child: SvgPicture.asset(
                                  'assets/iconos/notifi.svg',
                                  width: 19,
                                  height: 19,
                                  fit: BoxFit.contain,
                                  colorFilter: const ColorFilter.mode(
                                    Colors.white,
                                    BlendMode.srcIn,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Pestañas (tabs)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _GenreTab(
                      label: 'Online',
                      active: _genre == Genre.online,
                      large: false,
                      onTap: () {
                        setState(() => _genre = Genre.online);
                        widget.onGenreChanged(_genre);
                      },
                    ),
                    _GenreTab(
                      label: 'Musica',
                      active: _genre == Genre.musica,
                      large: true,
                      onTap: () {
                        setState(() => _genre = Genre.musica);
                        widget.onGenreChanged(_genre);
                      },
                    ),
                    _GenreTab(
                      label: 'Estilos',
                      active: _genre == Genre.estilos,
                      large: false,
                      onTap: () {
                        setState(() => _genre = Genre.estilos);
                        widget.onGenreChanged(_genre);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // ✅ UN SOLO AnimatedSwitcher que ocupa todo el espacio restante
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: _buildContentForGenre(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // Modificar _buildContentForGenre para usar los nuevos métodos
  Widget _buildContentForGenre() {
    switch (_genre) {
      case Genre.online:
        return _buildOnlineContent();
      case Genre.musica:
        return _buildMusicaContent();
      case Genre.estilos:
        return _buildEstilosContent();
    }
  }
}

class _GenreTab extends StatelessWidget {
  final String label;
  final bool active, large;
  final VoidCallback onTap;
  const _GenreTab({
    required this.label,
    required this.active,
    required this.large,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 300),
        style: TextStyle(
          fontFamily: TextStyle(fontFamily: 'Stylish').fontFamily,
          color: active ? Colors.white : const Color(0xFF71717A),
          fontSize: active ? (large ? 24 : 22) : 20,
          fontWeight: active ? FontWeight.w600 : FontWeight.normal,
        ),
        child: Text(label),
      ),
    );
  }
}

// ==================== CARRUSEL DE ÁLBUMES ====================
class AlbumCarousel extends StatefulWidget {
  final List<Song> songs;
  final double cardWidth, cardHeight;
  final Function(Song) onTap;
  const AlbumCarousel({
    super.key,
    required this.songs,
    required this.cardWidth,
    required this.cardHeight,
    required this.onTap,
  });
  @override
  State<AlbumCarousel> createState() => _AlbumCarouselState();
}

class _AlbumCarouselState extends State<AlbumCarousel> {
  int _center = 0;
  late final ScrollController _sc;
  @override
  void initState() {
    super.initState();
    _sc = ScrollController()..addListener(_updateCenter);
    // ✅ Forzar actualización inicial después del primer build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateCenter();
    });
  }

  void _updateCenter() {
    if (!_sc.hasClients) return;
    final viewCenter = _sc.offset + _sc.position.viewportDimension / 2;
    int closest = 0;
    double minDist = double.infinity;
    for (int i = 0; i < widget.songs.length; i++) {
      final itemCenter =
          40.0 + i * (widget.cardWidth + 16) + widget.cardWidth / 2;
      final dist = (viewCenter - itemCenter).abs();
      if (dist < minDist) {
        minDist = dist;
        closest = i;
      }
    }
    if (closest != _center) setState(() => _center = closest);
  }

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        height: widget.cardHeight + 48,
        child: ListView.builder(
          controller: _sc,
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
          itemCount: widget.songs.length,
          itemBuilder: (ctx, i) {
            final isCenter = i == _center;
            final isAdjacent = (i - _center).abs() == 1;
            final scale = isCenter ? 1.10 : (isAdjacent ? 0.92 : 0.85);
            final opacity = isCenter ? 1.0 : (isAdjacent ? 0.85 : 0.50);
            final bright = isCenter ? 1.0 : (isAdjacent ? 0.85 : 0.60);
            return GestureDetector(
              onTap: () => widget.onTap(widget.songs[i]),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                curve: const Cubic(0.4, 0.0, 0.2, 1.0), // Curva más fluida
                width: widget.cardWidth,
                margin: EdgeInsets.only(
                  right: 16,
                  top: isCenter ? 0 : 4,
                  bottom: isCenter ? 4 : 0,
                ),
                transform: Matrix4.identity()..scale(scale),
                transformAlignment: Alignment.center,
                child: Opacity(
                  opacity: opacity,
                  child: AlbumCard(
                    song: widget.songs[i],
                    width: widget.cardWidth,
                    height: widget.cardHeight,
                    isCenter: isCenter,
                    brightness: bright,
                    onPlay: () => widget.onTap(widget.songs[i]),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class AlbumCard extends StatelessWidget {
  final Song song;
  final double width, height;
  final bool isCenter;
  final double brightness;
  final VoidCallback onPlay;
  const AlbumCard({
    super.key,
    required this.song,
    required this.width,
    required this.height,
    required this.isCenter,
    required this.brightness,
    required this.onPlay,
  });
  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(36),
          boxShadow: [
            if (isCenter)
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 15,
                offset: const Offset(0, 8),
              ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(36),
          clipBehavior: Clip
              .antiAliasWithSaveLayer, // Solución 3: Recorte de alta precisión
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Imagen de fondo (cubre todo)
              Positioned.fill(
                child: ColorFiltered(
                  colorFilter: ColorFilter.matrix([
                    brightness,
                    0,
                    0,
                    0,
                    0,
                    0,
                    brightness,
                    0,
                    0,
                    0,
                    0,
                    0,
                    brightness,
                    0,
                    0,
                    0,
                    0,
                    0,
                    1,
                    0,
                  ]),
                  child: buildImage(
                    song.img,
                    width: width,
                    height: height,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              // Recuadro inferior con gradiente y blur (siempre con blur alto para evitar parpadeo)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(36),
                    bottomRight: Radius.circular(36),
                  ),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
                    child: Container(
                      width: width,
                      // height: 61,  ← ELIMINA esta línea
                      decoration: const ShapeDecoration(
                        color: Color(0x66000000),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.only(
                            bottomLeft: Radius.circular(36),
                            bottomRight: Radius.circular(36),
                          ),
                        ),
                      ),
                      padding: const EdgeInsets.only(
                        left: 18,
                        top: 14,
                        bottom: 8,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            maxLines: 2, // 👈 permite hasta 2 líneas
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              height: 1.2, // opcional, mejor espaciado
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF71717A),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // Botón de play (Escalado suave para mantener el blur estable)
              Positioned(
                top: 15,
                right: 15,
                child: IgnorePointer(
                  ignoring: !isCenter,
                  child: AnimatedScale(
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOutBack,
                    scale: isCenter ? 1.0 : 0.0,
                    child: LiquidButton(
                      onTap: onPlay,
                      size: 40,
                      child: Center(
                        child: SvgPicture.asset(
                          'assets/iconos/play.svg',
                          width: 22,
                          height: 22,
                          fit: BoxFit.contain,
                          alignment: Alignment.center,
                          colorFilter: const ColorFilter.mode(
                            Colors.white,
                            BlendMode.srcIn,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== PANTALLA DE PERFIL (usando ValueNotifier global) ====================
class ProfileScreen extends StatefulWidget {
  final VoidCallback onLogout;
  const ProfileScreen({super.key, required this.onLogout});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  void _showComingSoon() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Próximamente disponible')));
  }

  void _loadLikedSongs() async {
    final likedSongs = await ProxyYoutubeService().getLikedSongs();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Cargadas ${likedSongs.length} canciones de "Me gusta"'),
      ),
    );
  }

  Widget _buildProfileAvatar(String? avatarUrl, bool? hasOwnCircle) {
    if (avatarUrl == null || avatarUrl.isEmpty) {
      return Container(
        width: 100,
        height: 100,
        color: const Color(0xFF3F3F46),
        child: const Icon(Icons.person, size: 50, color: Colors.white70),
      );
    }
    if (hasOwnCircle == true) {
      // Avatar con círculo propio (pollo)
      return ClipOval(
        child: SvgPicture.network(
          avatarUrl,
          width: 100,
          height: 100,
          fit: BoxFit.cover,
          placeholderBuilder: (context) => const MusicLoader(),
          errorBuilder: (_, _, _) =>
              const Icon(Icons.person, color: Colors.white70),
        ),
      );
    } else {
      // Avatares sin círculo
      return Container(
        width: 100,
        height: 100,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFF2C2C2E),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: SvgPicture.network(
            avatarUrl,
            width: 76,
            height: 76,
            fit: BoxFit.contain,
            placeholderBuilder: (context) => const MusicLoader(),
            errorBuilder: (_, _, _) =>
                const Icon(Icons.person, color: Colors.white70),
          ),
        ),
      );
    }
  }

  Widget _buildMenuItem({
    required String svgUrl,
    required String title,
    required VoidCallback onTap,
    TextStyle? style,
    bool isDestructive = false,
  }) {
    return Column(
      children: [
        ScaleBtn(
          onTap: onTap,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: SvgPicture.asset(
              svgUrl, // ← pero svgUrl ahora será la ruta local
              width: 24,
              height: 24,
              colorFilter: ColorFilter.mode(
                isDestructive
                    ? Colors.redAccent
                    : Colors.white.withOpacity(0.7),
                BlendMode.srcIn,
              ),
            ),
            title: Text(
              title,
              style:
                  style ??
                  TextStyle(
                    color: isDestructive ? Colors.redAccent : Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
            ),
            trailing: Icon(
              Icons.chevron_right,
              color: Colors.white54,
              size: 20,
            ),
          ),
        ),
        const Divider(color: Color(0x20FFFFFF), thickness: 1),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = userProfileNotifier.value;
    final nickname = profile.nickname;
    final avatarUrl = profile.avatarUrl;
    final avatarHasOwnCircle = profile.avatarHasOwnCircle;
    final user = FirebaseAuth.instance.currentUser;
    final email = user?.email ?? '';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: () {
                    final appShell = context
                        .findAncestorStateOfType<_AppShellState>();
                    appShell?.navigate(AppScreen.home, navIndex: 0);
                  },
                  child: SvgPicture.asset(
                    'assets/iconos/Vector.svg',
                    width: 20,
                    height: 20,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Mi Perfil',
                  style: TextStyle(
                    fontFamily: 'Stylish',
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            // Mostrar los datos directamente (ya no hay isLoading porque el perfil ya está cargado globalmente)
            Center(
              child: Column(
                children: [
                  ClipOval(
                    child: SizedBox(
                      width: 100,
                      height: 100,
                      child: _buildProfileAvatar(avatarUrl, avatarHasOwnCircle),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    nickname,
                    style: TextStyle(
                      fontFamily: 'Stylish',
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    email,
                    style: TextStyle(
                      fontFamily: 'Merienda',
                      color: Color(0xFF9A9A9A),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            _buildMenuItem(
              style: TextStyle(
                fontFamily: 'HappyMonkey',
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
              svgUrl: 'assets/iconos/favoritos.svg',
              title: 'Mis favoritos',
              onTap: () {
                final appShell = context
                    .findAncestorStateOfType<_AppShellState>();
                appShell?.navigate(AppScreen.favorites);
              },
            ),
            _buildMenuItem(
              style: TextStyle(
                fontFamily: 'HappyMonkey',
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
              svgUrl: 'assets/iconos/descargas.svg',
              title: 'Descargas',
              onTap: () {
                final appShell = context
                    .findAncestorStateOfType<_AppShellState>();
                appShell?.navigate(AppScreen.downloads);
              },
            ),
            _buildMenuItem(
              style: TextStyle(
                fontFamily: 'HappyMonkey',
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
              svgUrl: 'assets/iconos/playlist.svg',
              title: 'Mis Playlists',
              onTap: _showComingSoon,
            ),
            _buildMenuItem(
              style: TextStyle(
                fontFamily: 'HappyMonkey',
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
              svgUrl: 'assets/iconos/recientes.svg',
              title: 'Recientes',
              onTap: _showComingSoon,
            ),
            _buildMenuItem(
              style: TextStyle(
                fontFamily: 'HappyMonkey',
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
              svgUrl: 'assets/iconos/salir.svg',
              title: 'Cerrar sesión',
              onTap: () async {
                await FirebaseAuth.instance.signOut();
                // Reiniciar el perfil global al cerrar sesión
                userProfileNotifier.value = UserProfile(
                  nickname: '',
                  avatarUrl: '',
                  avatarHasOwnCircle: false,
                  isLoaded: false,
                );
                widget.onLogout();
              },
              isDestructive: true,
            ),
          ],
        ),
      ),
    );
  }
}

// Modelo para canciones descargadas
class DownloadedSong {
  final String videoId; // El audioPath (ID de YouTube)
  final String title;
  final String artist;
  final String img; // URL de la imagen
  final String localPath; // Ruta absoluta del archivo descargado
  final String type; // 'local' o 'device'

  DownloadedSong({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.img,
    required this.localPath,
    required this.type,
  });

  Map<String, dynamic> toJson() => {
    'videoId': videoId,
    'title': title,
    'artist': artist,
    'img': img,
    'localPath': localPath,
    'type': type,
  };

  factory DownloadedSong.fromJson(Map<String, dynamic> json) => DownloadedSong(
    videoId: json['videoId'],
    title: json['title'],
    artist: json['artist'],
    img: json['img'],
    localPath: json['localPath'],
    type: json['type'],
  );
}

// En ProfileScreen
// ==================== NOW PLAYING (con audio real, seek, shuffle, repeat corregidos) ====================
class NowPlayingScreen extends StatefulWidget {
  final List<Song> songs;
  final int initialIndex;
  final bool isPlaying;
  final VoidCallback onTogglePlay;
  final VoidCallback onNextSong;
  final VoidCallback onPrevSong;
  final Function(Song, int) onSongChange;
  final VoidCallback onBack;

  const NowPlayingScreen({
    super.key,
    required this.songs,
    required this.initialIndex,
    required this.isPlaying,
    required this.onTogglePlay,
    required this.onNextSong,
    required this.onPrevSong,
    required this.onSongChange,
    required this.onBack,
  });

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen>
    with TickerProviderStateMixin {
  late PageController _pc;
  int _idx = 0;

  bool _isShuffle = false;
  RepeatMode _repeatMode = RepeatMode.none;

  // URLs de los iconos
  final String _shuffleIconUrl = 'assets/iconos/aleatorio.svg';
  final String _repeatAllIconUrl = 'assets/iconos/Repetir.svg';
  final String _repeatOneIconUrl = 'assets/iconos/Repetir1.svg';

  // Estado de reproducción
  Duration? _duration;
  Duration _position = Duration.zero;
  bool _isPlayingInternal = false; // control interno para evitar conflictos

  // Suscripciones a streams
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<ProcessingState>? _processingStateSubscription;

  Song get _activeSong => widget.songs[_idx];
  bool get _isFavorite =>
      favoriteNotifier.value.contains(_activeSong.audioPath);

  void _toggleFavorite() {
    final key = _activeSong.audioPath;
    final current = favoriteNotifier.value;
    if (current.contains(key)) {
      favoriteNotifier.value = Set.of(current)..remove(key);
    } else {
      favoriteNotifier.value = Set.of(current)..add(key);
    }
    setState(() {});
void toggleFavorite() async {
  final key = _activeSong.audioPath;
  final current = favoriteNotifier.value;

  // Si la canción no está en el mapa global, la añadimos
  if (!allSongsNotifier.value.containsKey(key)) {
    final currentMap = Map<String, Song>.from(allSongsNotifier.value);
    currentMap[key] = _activeSong;
    allSongsNotifier.value = currentMap;
  }

  // Resto del código (agregar/remover de favoritos, etc.)
  if (current.contains(key)) {
    // Si se va a quitar de favoritos, verificar si está descargada
    final isDownloaded = await DownloadManager.isSongDownloaded(key);
    if (isDownloaded) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Eliminar archivo descargado'),
          content: const Text('Esta canción tiene un archivo descargado. ¿Deseas eliminarlo también?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sí')),
          ],
        ),
      );
      if (confirm == true) {
        // Eliminar archivo
        final localSongs = await DownloadManager.getLocalSongs();
        final deviceSongs = await DownloadManager.getDeviceSongs();
        final local = localSongs.firstWhereOrNull((s) => s.videoId == key);
        final device = deviceSongs.firstWhereOrNull((s) => s.videoId == key);
        if (local != null) {
          try { await File(local.localPath).delete(); } catch (_) {}
          await DownloadManager.removeLocalSong(key);
        }
        if (device != null) {
          try { await File(device.localPath).delete(); } catch (_) {}
          await DownloadManager.removeDeviceSong(key);
        }
        await DownloadSyncService.syncOnChange();
        await refreshDownloadStatus();
      }
    }
    favoriteNotifier.value = Set.of(current)..remove(key);
  } else {
    favoriteNotifier.value = Set.of(current)..add(key);
  }
  setState(() {});
}
  }

  late AnimationController _waveController;
  late Animation<double> _waveAnimation;

  @override
  void initState() {
    super.initState();
    if (widget.songs.isEmpty) {
      // Si no hay canciones, redirigir a Home
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onBack(); // o navegar directamente
      });
      return;
    }
    _idx = widget.initialIndex.clamp(0, widget.songs.length - 1);
    _pc = PageController(initialPage: _idx, viewportFraction: 0.65);

    // Suscribirse a los streams (usa audioPlayerService global)
    _positionSubscription = audioPlayerService.player.positionStream.listen((
      pos,
    ) {
      if (mounted) setState(() => _position = pos);
    });
    _durationSubscription = audioPlayerService.player.durationStream.listen((
      dur,
    ) {
      if (mounted) setState(() => _duration = dur);
    });

    final currentPath = audioPlayerService.currentPath;
    final isSameSong = currentPath == widget.songs[_idx].audioPath;
    if (!isSameSong) {
      _loadAndPlay(widget.songs[_idx]).then((_) {
        if (widget.isPlaying) {
          audioPlayerService.play();
        }
      });
    } else {
      if (widget.isPlaying) {
        audioPlayerService.play();
      }
    }
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _waveAnimation = Tween<double>(
      begin: 0.0,
      end: 2 * pi,
    ).animate(_waveController);

    // Escuchar cambios en el estado de buffering
    _processingStateSubscription = audioPlayerService
        .player
        .processingStateStream
        .listen((state) {
          if (state == ProcessingState.completed) {
            _onSongFinished();
          }
        });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
  }

  @override
  void didUpdateWidget(NowPlayingScreen old) {
    super.didUpdateWidget(old);
    if (widget.isPlaying != old.isPlaying) {
      if (widget.isPlaying) {
        audioPlayerService.play();
      } else {
        audioPlayerService.pause();
      }
    }
    if (widget.initialIndex != old.initialIndex) {
      _idx = widget.initialIndex.clamp(0, widget.songs.length - 1);
      _pc.jumpToPage(_idx);
      _loadSong(_activeSong.audioPath).then((_) {
        if (widget.isPlaying) audioPlayerService.play();
      });
    }
  }

  @override
  void dispose() {
    _waveController.dispose();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _processingStateSubscription?.cancel();
    // No llamar a audioPlayerService.dispose()
    super.dispose();
  }

  bool _isLoading = false;

  Future<void> _loadSong(String path) async {
    if (_isLoading) return;
    _isLoading = true;
    await audioPlayerService.loadSong(path, autoPlay: widget.isPlaying);
    _isLoading = false;
  }

  String _fmt(Duration? d) {
    if (d == null) return '0:00';
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _changePage(int index) async {
    if (index == _idx) return;
    _idx = index;
    // Primero cambia la página visualmente
    await _pc.animateToPage(
      index,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
    // Ahora carga y reproduce la nueva canción
    await _loadAndPlay(widget.songs[_idx]);
  }

  Future<void> _loadAndPlay(Song song) async {
    await audioPlayerService.loadSong(
      song.audioPath,
      autoPlay: widget.isPlaying,
    );
    widget.onSongChange(song, _idx);
  }

  void _onSongFinished() {
    // Comportamiento al terminar la canción
    if (_repeatMode == RepeatMode.one) {
      // Repetir la misma canción
      audioPlayerService.seek(Duration.zero);
      audioPlayerService.play();
      return;
    }

    if (_isShuffle) {
      int newIndex;
      do {
        newIndex = Random().nextInt(widget.songs.length);
      } while (newIndex == _idx && widget.songs.length > 1);
      _changePage(newIndex);
      return;
    }

    if (_idx < widget.songs.length - 1) {
      _changePage(_idx + 1);
    } else if (_repeatMode == RepeatMode.all) {
      _changePage(0);
    } else {
      // Fin de la lista, detener reproducción
      audioPlayerService.stop();
      if (mounted) setState(() => _isPlayingInternal = false);
    }
  }

  void _updateProgress(double dx, BoxConstraints constraints) {
    if (_duration == null) return;
    final width = constraints.maxWidth;
    double progress = (dx / width).clamp(0.0, 1.0);
    final newPosition = _duration! * progress;
    audioPlayerService.seek(newPosition);
    // Si estaba sonando, al arrastrar se pausa momentáneamente
    if (audioPlayerService.player.playing) {
      audioPlayerService.pause();
    }
  }

  void _resumeAfterSeek() {
    if (widget.isPlaying && !audioPlayerService.player.playing) {
      audioPlayerService.play();
    }
  }

  void _showDownloadOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: SvgPicture.asset(
                  'assets/iconos/descargas.svg',
                  width: 24,
                  height: 24,
                  colorFilter: const ColorFilter.mode(
                    Colors.white,
                    BlendMode.srcIn,
                  ),
                ),
                title: Text(
                  'Descarga',
                  style: TextStyle(
                    fontFamily: 'Merienda',
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _downloadCurrentSong();
                },
              ),
              ListTile(
                leading: SvgPicture.asset(
                  'assets/iconos/archivo.svg',
                  width: 24,
                  height: 24,
                  colorFilter: const ColorFilter.mode(
                    Colors.white,
                    BlendMode.srcIn,
                  ),
                ),
                title: Text(
                  'Descarga local',
                  style: TextStyle(
                    fontFamily: 'Merienda',
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _navigateToDeviceDownloads();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _downloadCurrentSong({bool isLocal = true}) async {
    final song = _activeSong;
    // Verificar duplicados antes de iniciar
    final isDownloaded = await DownloadManager.isSongDownloaded(song.audioPath);
    if (isDownloaded) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Ya descargada'),
          content: Text(
            'La canción "${song.title}" ya está descargada. ¿Deseas sobrescribirla?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sobrescribir'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
      // Si sobrescribe, eliminar la descarga anterior
      // Buscar en ambas listas y eliminar
      final localSongs = await DownloadManager.getLocalSongs();
      final deviceSongs = await DownloadManager.getDeviceSongs();
      final existingLocal = localSongs.firstWhereOrNull(
        (s) => s.videoId == song.audioPath,
      );
      final existingDevice = deviceSongs.firstWhereOrNull(
        (s) => s.videoId == song.audioPath,
      );
      if (existingLocal != null) {
        await DownloadManager.removeLocalSong(song.audioPath);
        await DownloadSyncService.syncOnChange();
        // Eliminar archivo físico
        try {
          await File(existingLocal.localPath).delete();
        } catch (_) {}
      } else if (existingDevice != null) {
        await DownloadManager.removeDeviceSong(song.audioPath);
        try {
          await File(existingDevice.localPath).delete();
        } catch (_) {}
      }
    }

    // Mostrar diálogo de progreso
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _DownloadProgressDialog(song: song, isLocal: isLocal),
    );
  }

  void _navigateToDeviceDownloads() {
    final appShell = context.findAncestorStateOfType<_AppShellState>();
    appShell?.navigate(AppScreen.downloads, showDeviceFiles: true);
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final compact = screenHeight < 760;
    final artworkSectionHeight = compact ? 280.0 : 320.0;
    final artworkHeight = compact ? 230.0 : 258.0;
    final artworkMargin = compact ? 10.0 : 16.0;
    final titleGap = compact ? 4.0 : 6.0;
    final favoriteGap = compact ? 12.0 : 18.0;
    final heartTopOffset = compact ? -7.0 : -10.0;
    final waveHeight = compact ? 96.0 : 112.0;
    final controlsBottomPadding = compact ? 4.0 : 10.0;
    final playButtonSize = compact ? 72.0 : 76.0;
    final sideIconSize = compact ? 26.0 : 28.0;
    final extraIconSize = compact ? 20.0 : 22.0;

    return SafeArea(
      child: Container(
        color: AppColors.bgBase, // o Colors.black
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, compact ? 8 : 12, 16, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Botón de retroceso (izquierda)
                  GestureDetector(
                    onTap: widget.onBack,
                    child: RepaintBoundary(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: SvgPicture.asset(
                          'assets/iconos/Vector.svg',
                          width: 20,
                          height: 20,
                          colorFilter: const ColorFilter.mode(
                            Colors.white,
                            BlendMode.srcIn,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Botón de descarga (derecha)
                  ScaleBtn(
                    onTap: _showDownloadOptions,
                    child: RepaintBoundary(
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: SvgPicture.asset(
                          'assets/iconos/descargas.svg',
                          width: 28,
                          height: 28,
                          colorFilter: const ColorFilter.mode(
                            Colors.white,
                            BlendMode.srcIn,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: artworkSectionHeight,
              child: PageView.builder(
                controller: _pc,
                itemCount: widget.songs.length,
                onPageChanged: (i) async {
                  if (i == _idx) return;
                  _idx = i;
                  await _loadAndPlay(widget.songs[_idx]);
                },
                itemBuilder: (ctx, i) => AnimatedBuilder(
                  animation: _pc,
                  builder: (ctx, child) {
                    double page = _idx.toDouble();
                    try {
                      page = _pc.page ?? _idx.toDouble();
                    } catch (_) {}
                    final diff = (i - page).abs();
                    final scale = (1.0 - diff * 0.20).clamp(0.75, 1.0);
                    final opac = (1.0 - diff * 0.35).clamp(0.40, 1.0);
                    final bright = (1.0 - diff * 0.35).clamp(0.55, 1.0);
                    return Transform.scale(
                      scale: scale,
                      child: Opacity(
                        opacity: opac,
                        child: ColorFiltered(
                          colorFilter: ColorFilter.matrix([
                            bright,
                            0,
                            0,
                            0,
                            0,
                            0,
                            bright,
                            0,
                            0,
                            0,
                            0,
                            0,
                            bright,
                            0,
                            0,
                            0,
                            0,
                            0,
                            1,
                            0,
                          ]),
                          child: child,
                        ),
                      ),
                    );
                  },
                  child: Container(
                    width: 240,
                    height: artworkHeight,
                    margin: EdgeInsets.symmetric(vertical: artworkMargin),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(32),
                      boxShadow: i == _idx
                          ? [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.6),
                                blurRadius: 32,
                              ),
                            ]
                          : [],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(32),
                      child: buildImage(
                        widget.songs[i].img,
                        width: 240,
                        height: artworkHeight,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: compact ? 6 : 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  Text(
                    _activeSong.title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 23,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: titleGap),
                  Text(
                    _activeSong.artist,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 17),
                  ),
                  SizedBox(height: favoriteGap),
                  Transform.translate(
                    offset: Offset(0, heartTopOffset),
                    child: LikeButton(
                      size: 80,
                      isLiked: _isFavorite,
                      likeBuilder: (isLiked) => Icon(
                        isLiked ? Icons.favorite : Icons.favorite_border,
                        color: isLiked ? AppColors.redPrimary : Colors.white,
                        size: 28,
                      ),
                      onTap: (isLiked) async {
                        _toggleFavorite();
                        return !isLiked;
                      },
                    ),
                  ),
                  const SizedBox(height: 6),
                  Column(
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final progress =
                              (_duration != null &&
                                  _duration!.inMilliseconds > 0)
                              ? _position.inMilliseconds /
                                    _duration!.inMilliseconds
                              : 0.0;
                          final isBuffering =
                              audioPlayerService.isBufferingNotifier.value;

                          return GestureDetector(
                            onHorizontalDragUpdate: (details) {
                              _updateProgress(
                                details.localPosition.dx,
                                constraints,
                              );
                            },
                            onHorizontalDragEnd: (details) {
                              _resumeAfterSeek();
                            },
                            child: SizedBox(
                              height: waveHeight,
                              width: double.infinity,
                              child: AnimatedBuilder(
                                animation: _waveAnimation,
                                builder: (context, child) {
                                  return CustomPaint(
                                    painter: WaveProgressPainter(
                                      progress: progress,
                                      phase: _waveAnimation.value,
                                      isBuffering: isBuffering,
                                    ),
                                  );
                                },
                              ),
                            ),
                          );
                        },
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          0,
                          compact ? 0 : 2,
                          0,
                          controlsBottomPadding,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _fmt(_position),
                                style: const TextStyle(
                                  color: Color(0xFF71717A),
                                  fontSize: 12,
                                ),
                                textAlign: TextAlign.start,
                              ),
                            ),
                            ScaleBtn(
                              onTap: () =>
                                  setState(() => _isShuffle = !_isShuffle),
                              child: SvgPicture.asset(
                                _shuffleIconUrl,
                                width: extraIconSize,
                                height: extraIconSize,
                                colorFilter: ColorFilter.mode(
                                  _isShuffle
                                      ? AppColors.redPrimary
                                      : Colors.white54,
                                  BlendMode.srcIn,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            ScaleBtn(
                              onTap: widget.onPrevSong,
                              child: SvgPicture.asset(
                                'assets/iconos/back.svg',
                                width: sideIconSize,
                                height: sideIconSize,
                              ),
                            ),
                            const SizedBox(width: 14),
                            ValueListenableBuilder<bool>(
                              valueListenable:
                                  audioPlayerService.isPlayingNotifier,
                              builder: (context, isPlaying, _) {
                                return ScaleBtn(
                                  onTap: widget.onTogglePlay,
                                  child: Container(
                                    width: playButtonSize,
                                    height: playButtonSize,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: const Color(
                                        0xFF16181E,
                                      ).withOpacity(0.95),
                                    ),
                                    child: Center(
                                      child: SvgPicture.asset(
                                        isPlaying
                                            ? 'assets/iconos/Pause1.svg'
                                            : 'assets/iconos/Play1.svg',
                                        key: ValueKey(isPlaying),
                                        width: 34,
                                        height: 34,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                            const SizedBox(width: 14),
                            ScaleBtn(
                              onTap: widget.onNextSong,
                              child: SvgPicture.asset(
                                'assets/iconos/Next.svg',
                                width: sideIconSize,
                                height: sideIconSize,
                              ),
                            ),

                            const SizedBox(width: 12),
                            ScaleBtn(
                              onTap: () {
                                setState(() {
                                  _repeatMode = {
                                    RepeatMode.none: RepeatMode.all,
                                    RepeatMode.all: RepeatMode.one,
                                    RepeatMode.one: RepeatMode.none,
                                  }[_repeatMode]!;
                                });
                              },
                              child: SvgPicture.asset(
                                _repeatMode == RepeatMode.one
                                    ? _repeatOneIconUrl
                                    : _repeatAllIconUrl,
                                width: extraIconSize,
                                height: extraIconSize,
                                colorFilter: ColorFilter.mode(
                                  _repeatMode != RepeatMode.none
                                      ? AppColors.redPrimary
                                      : Colors.white54,
                                  BlendMode.srcIn,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                _fmt(_duration),
                                style: const TextStyle(
                                  color: Color(0xFF71717A),
                                  fontSize: 12,
                                ),
                                textAlign: TextAlign.end,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class WaveProgressPainter extends CustomPainter {
  final double progress;
  final double phase;
  final bool isBuffering;

  const WaveProgressPainter({
    required this.progress,
    this.phase = 0.0,
    this.isBuffering = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Puntos de control de la curva base
    final p0x = 0.0;
    final p0y = h * 0.90;
    final p1x = w * 0.22;
    final p1y = h * 0.06;
    final p2x = w * 0.78;
    final p2y = h * 0.06;
    final p3x = w;
    final p3y = h * 0.90;

    // Parámetros de la onda
    final baseAmplitude = 4.0;
    final bufferingAmplitude = 10.0;
    final maxAmplitude = isBuffering ? bufferingAmplitude : baseAmplitude;
    final frequency = 0.06;

    // Crear el path completo de la curva
    final fullPath = Path()
      ..moveTo(p0x, p0y)
      ..cubicTo(p1x, p1y, p2x, p2y, p3x, p3y);
    final metrics = fullPath.computeMetrics().first;
    final totalLength = metrics.length;
    final playedLength = totalLength * progress.clamp(0.0, 1.0);

    // --- 1. Dibujar la línea gris de fondo SOLO en la parte NO recorrida ---
    if (playedLength < totalLength) {
      final remainingPath = metrics.extractPath(playedLength, totalLength);
      final bgPaint = Paint()
        ..color = const Color(0xFF27272A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(remainingPath, bgPaint);
    }

    if (progress <= 0) return;

    // --- 2. Dibujar la línea de progreso con ondulación desde 0 hasta playedLength ---
    final wavePath = Path();
    bool first = true;
    final steps = 150;

    for (int i = 0; i <= steps; i++) {
      final t = i / steps;
      final distance = t * playedLength;

      final pos = metrics.getTangentForOffset(distance)?.position;
      if (pos == null) continue;

      final tangentAtPos = metrics.getTangentForOffset(distance);
      if (tangentAtPos == null) continue;

      final dx = tangentAtPos.vector.dx;
      final dy = tangentAtPos.vector.dy;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len == 0) continue;

      final nx = -dy / len;
      final ny = dx / len;

      final anchorFactor = 1.0 - (distance / playedLength);
      final offset =
          math.sin(frequency * distance + phase) * maxAmplitude * anchorFactor;

      final waveX = pos.dx + nx * offset;
      final waveY = pos.dy + ny * offset;

      if (first) {
        wavePath.moveTo(waveX, waveY);
        first = false;
      } else {
        wavePath.lineTo(waveX, waveY);
      }
    }

    final fgPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Colors.white.withOpacity(0.0),
          Colors.white.withOpacity(0.42),
          Colors.white.withOpacity(0.92),
          Colors.white,
        ],
        stops: const [0.0, 0.10, 0.22, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, w, h))
      ..style = PaintingStyle.stroke
      ..strokeWidth = isBuffering ? 3.0 : 2.3
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(wavePath, fgPaint);

    // --- 3. Círculo de progreso en la posición exacta de playedLength ---
    final circlePos = metrics.getTangentForOffset(playedLength)?.position;
    if (circlePos != null) {
      canvas.drawCircle(circlePos, 5.0, Paint()..color = Colors.white);
      canvas.drawCircle(
        circlePos,
        7.0,
        Paint()
          ..color = Colors.white.withOpacity(0.3)
          ..style = PaintingStyle.fill,
      );
    }
  }

  @override
  bool shouldRepaint(WaveProgressPainter old) =>
      old.progress != progress ||
      old.phase != phase ||
      old.isBuffering != isBuffering;
}

class SongListCard extends StatelessWidget {
  final String imageUrl;
  final String songTitle;
  final String artistLabel;
  final String albumName;
  final bool isFavorite;
  final bool isDownloaded;
  final double downloadProgress; // -1 si no está descargando
  final bool showCheckbox;
  final bool isChecked;
  final VoidCallback? onCheckboxChanged;
  final VoidCallback? onTap;

  const SongListCard({
    super.key,
    required this.imageUrl,
    required this.songTitle,
    required this.artistLabel,
    required this.albumName,
    required this.isFavorite,
    this.isDownloaded = false,
    this.downloadProgress = -1,
    this.showCheckbox = false,
    this.isChecked = false,
    this.onCheckboxChanged,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF131313),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white12),
        ),
        child: Stack(
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: buildImage(
                    imageUrl,
                    width: 72,
                    height: 72,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        songTitle,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        artistLabel,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        albumName,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: isFavorite ? AppColors.redPrimary : Colors.white54,
                  size: 22,
                ),
              ],
            ),
            // Badge "descargado"
            if (isDownloaded)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check, size: 16, color: Colors.white),
                ),
              ),
            // Checkbox de selección
            if (showCheckbox)
              Positioned(
                left: 8,
                top: 8,
                child: Checkbox(
                  value: isChecked,
                  onChanged: (val) => onCheckboxChanged?.call(),
                ),
              ),
            // Progreso de descarga
            if (downloadProgress > 0 && downloadProgress < 1)
              Positioned(
                right: 8,
                bottom: 8,
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    value: downloadProgress,
                    strokeWidth: 3,
                    color: AppColors.redPrimary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ==================== BÚSQUEDA (con modo local/online) ====================
class SearchScreen extends StatefulWidget {
  final VoidCallback onBack;
  final SearchMode mode;
  final Function(Song, List<Song>)
  onPlay; // recibe canción y lista de resultados

  const SearchScreen({
    super.key,
    required this.onBack,
    required this.mode,
    required this.onPlay,
  });

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();
  List<Song> _results = [];
  bool _hasSearch = false;
  bool _isLoading = false;

  void _search(String term) async {
    final t = term.trim();
    if (t.isEmpty) {
      setState(() {
        _results = [];
        _hasSearch = false;
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _hasSearch = true;
      _isLoading = true;
    });

    try {
      List<Song> found;
      if (widget.mode == SearchMode.local) {
        found = database.where((s) {
          return s.title.toLowerCase().contains(t.toLowerCase()) ||
              s.artist.toLowerCase().contains(t.toLowerCase());
        }).toList();
     } else {
      found = await searchService.search(t);
      // 🔄 Actualizar mapa global con las canciones encontradas
      final currentMap = Map<String, Song>.from(allSongsNotifier.value);
      for (var song in found) {
        currentMap[song.audioPath] = song;
      }
      allSongsNotifier.value = currentMap;
    }

      setState(() {
        _results = found;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _results = [];
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error al buscar: $e')));
    }
  }

  void _showDownloadOptions() {
    // (sin cambios, igual que antes)
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (_) => SizedBox(
        height: 140,
        child: Column(
          children: [
            ListTile(
              leading: const Icon(
                Icons.file_download_outlined,
                color: Colors.white,
              ),
              title: const Text(
                'Descargar resultados',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Función de descarga no implementada'),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.cancel, color: Colors.white),
              title: const Text(
                'Cancelar',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: widget.onBack,
                  child: RepaintBoundary(
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: SvgPicture.asset(
                          'assets/iconos/Vector.svg',
                          fit: BoxFit.contain,
                          alignment: Alignment.center,
                          colorFilter: const ColorFilter.mode(
                            Colors.white,
                            BlendMode.srcIn,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          const Icon(Icons.search, color: Colors.white70),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _ctrl,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                border: InputBorder.none,
                                hintText: widget.mode == SearchMode.local
                                    ? 'Buscar en tu música...'
                                    : 'Buscar en todo el mundo...',
                                hintStyle: const TextStyle(
                                  color: Colors.white54,
                                ),
                              ),
                              onChanged: _search,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(
                    Icons.file_download_outlined,
                    color: Colors.white,
                  ),
                  onPressed: _showDownloadOptions,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _hasSearch
                  ? (_isLoading
                        ? const Center(child: MusicLoader())
                        : (_results.isEmpty
                              ? Center(
                                  child: Opacity(
                                    opacity: 0.8,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Image.asset(
                                          'assets/imagenes/tefalla.png',
                                          width: 128,
                                          height: 128,
                                          fit: BoxFit.contain,
                                        ),
                                        const SizedBox(height: 16),
                                        const Text(
                                          'Eso no ta',
                                          style: TextStyle(
                                            color: Color(0xFFA1A1AA),
                                            fontSize: 18,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        const Text(
                                          'Revisa la lista pe causa',
                                          style: TextStyle(
                                            color: Color(0xFF52525B),
                                            fontSize: 14,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: _results.length,
                                  itemBuilder: (ctx, i) {
                                    final s = _results[i];
                                    return GestureDetector(
                                      onTap: () => widget.onPlay(s, _results),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 4,
                                        ),
                                        child: Row(
                                          children: [
                                            ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              child: buildImage(
                                                s.img,
                                                width: 56,
                                                height: 56,
                                                fit: BoxFit.cover,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  s.title,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                                Text(
                                                  s.artist,
                                                  style: const TextStyle(
                                                    color: Color(0xFF71717A),
                                                    fontSize: 13,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                )))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Búsquedas Recientes',
                              style: TextStyle(
                                fontFamily: 'HappyMonkey',
                                color: const Color(0xFFE5E5E5),
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              'Limpiar',
                              style: TextStyle(
                                fontFamily: 'Merienda',
                                color: const Color(0xFF71717A),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        // Aquí podrías mostrar búsquedas recientes guardadas en SharedPreferences
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== NOTIFICACIONES ====================
class NotificationsScreen extends StatelessWidget {
  final VoidCallback onBack;
  const NotificationsScreen({super.key, required this.onBack});
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    GestureDetector(
                      onTap: onBack,
                      child: RepaintBoundary(
                        child: Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: SvgPicture.asset(
                              'assets/iconos/Vector.svg',
                              fit: BoxFit.contain,
                              alignment: Alignment.center,
                              colorFilter: const ColorFilter.mode(
                                Colors.white,
                                BlendMode.srcIn,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Notificaciones',
                      style: TextStyle(
                        fontFamily: 'Stylish',
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Text(
                  'Leídas',
                  style: TextStyle(
                    fontFamily: 'Merienda',
                    color: Color(0xFF71717A),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0x0DFFFFFF))),
              ),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          AppColors.redPrimary.withOpacity(0.4),
                          AppColors.redDark.withOpacity(0.4),
                        ],
                      ),
                    ),
                    child: const Icon(
                      Icons.music_note,
                      color: Colors.white70,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Mensaje de actualidad',
                        style: TextStyle(
                          fontFamily: 'Stylish',
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'No se ha mandado más audios',
                        style: TextStyle(
                          color: Color(0xFFD4D4D8),
                          fontSize: 13,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Hasta próximas actualizaciones',
                        style: TextStyle(
                          color: Color(0xFF71717A),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== PLACEHOLDER ====================
class PlaceholderScreen extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  const PlaceholderScreen({
    super.key,
    required this.title,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: onBack,
                  child: RepaintBoundary(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: SvgPicture.asset(
                        'assets/iconos/Vector.svg',
                        fit: BoxFit.contain,
                        colorFilter: const ColorFilter.mode(
                          Colors.white,
                          BlendMode.srcIn,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'No hay contenido disponible',
                      style: TextStyle(color: Color(0xFFA1A1AA), fontSize: 17),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'En esta sección próximamente',
                      style: TextStyle(color: Color(0xFF71717A), fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== BOTTOM NAVIGATION ====================
class _BottomNav extends StatelessWidget {
  final int currentIndex;
  final Function(int) onTap;
  const _BottomNav({required this.currentIndex, required this.onTap});

  static const _iconsActive = [
    'assets/iconos/2-homeB11.svg',
    'assets/iconos/42-exploreB.svg',
    'assets/iconos/30-playB.svg',
    'assets/iconos/11-profileB.svg',
  ];
  static const _iconsInactive = [
    'assets/iconos/2-home-11.svg',
    'assets/iconos/42-explore.svg',
    'assets/iconos/30-play.svg',
    'assets/iconos/11-profile.svg',
  ];

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    const horizontalPadding = 25.0;
    final totalWidth = screenWidth - (horizontalPadding * 2);
    final sectionWidth = totalWidth / 4;
    final indicatorWidth = 36.0;
    final buttonCenter = (currentIndex * sectionWidth) + (sectionWidth / 2);
    double left = buttonCenter - (indicatorWidth / 2);
    // Opcional: clamp para evitar que se salga de los bordes
    left = left.clamp(0.0, totalWidth - indicatorWidth);

    return Container(
      height: 75,
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
      ), // ← padding interno
      decoration: BoxDecoration(
        color: const Color(0xF20A0A0A), // ← este es el original
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 20),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeInOut,
            top: 0,
            left: left,
            child: SizedBox(
              width: indicatorWidth,
              height: 24,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: indicatorWidth,
                    height: 4,
                    decoration: const BoxDecoration(
                      borderRadius: BorderRadius.vertical(
                        bottom: Radius.circular(20),
                      ),
                      color: Colors.white,
                    ),
                  ),
                  Positioned(
                    top: 2,
                    left: -12,
                    child: CustomPaint(
                      size: const Size(60, 15),
                      painter: _TriangleGlowPainter(
                        color: Colors.white,
                        intensity: 0.3,
                        blurSigma: 8.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Row(
            mainAxisAlignment:
                MainAxisAlignment.spaceBetween, // ← cambio importante
            children: List.generate(4, (i) {
              final active = i == currentIndex;
              return GestureDetector(
                onTap: () => onTap(i),
                child: SizedBox(
                  width: sectionWidth, // antes era sectionWidth * 1.0 (igual)
                  height: 75,
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        key: ValueKey('${i}_$active'),
                        child: SvgPicture.asset(
                          active ? _iconsActive[i] : _iconsInactive[i],
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

// ==================== SCALE BUTTON ====================
class ScaleBtn extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const ScaleBtn({super.key, required this.child, required this.onTap});
  @override
  State<ScaleBtn> createState() => _ScaleBtnState();
}

class _ScaleBtnState extends State<ScaleBtn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );
  late final Animation<double> _scale = Tween<double>(
    begin: 1.0,
    end: 1.05,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) {
        _controller.reverse();
        widget.onTap();
      },
      onTapCancel: () => _controller.reverse(),
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}

// ==================== BOTÓN CON GRADIENTE Y ESCALA AL HOVER
class LiquidButton extends StatefulWidget {
  final VoidCallback onTap;
  final Widget child;
  final double size;
  const LiquidButton({
    super.key,
    required this.onTap,
    required this.child,
    this.size = 40,
  });
  @override
  State<LiquidButton> createState() => _LiquidButtonState();
}

class _LiquidButtonState extends State<LiquidButton>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  late final AnimationController _scaleController;
  late final Animation<double> _scale;
  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _scale = Tween<double>(
      begin: 1.0,
      end: 1.15,
    ).animate(CurvedAnimation(parent: _scaleController, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails details) {
    _scaleController.forward();
  }

  void _handleTapUp(TapUpDetails details) {
    _scaleController.reverse();
    widget.onTap();
  }

  void _handleTapCancel() {
    _scaleController.reverse();
  }

  void _handleHover(bool hovering) {
    setState(() => _isHovered = hovering);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _handleHover(true),
      onExit: (_) => _handleHover(false),
      child: GestureDetector(
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onTapCancel: _handleTapCancel,
        child: RepaintBoundary(
          child: AnimatedScale(
            scale: _isHovered ? 1.1 : 1.0,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            child: AnimatedBuilder(
              animation: _scaleController,
              builder: (context, child) {
                return Transform.scale(
                  scale: _scale.value,
                  child: Container(
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 10,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(sigmaX: 8.0, sigmaY: 8.0),
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black.withOpacity(0.3),
                          ),
                          child: Center(child: widget.child),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// La clase _LiquidBlurAnimation permanece igual (no se modifica)
class _LiquidBlurAnimation extends StatefulWidget {
  final double size;
  final RadialGradient gradient;
  final int duration;
  final bool reverse;
  const _LiquidBlurAnimation({
    required this.size,
    required this.gradient,
    required this.duration,
    required this.reverse,
  });
  @override
  State<_LiquidBlurAnimation> createState() => _LiquidBlurAnimationState();
}

class _LiquidBlurAnimationState extends State<_LiquidBlurAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.duration),
    )..repeat(reverse: widget.reverse);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final angle = _controller.value * 360 * 2;
        final scale = 1.0 + (_controller.value * 0.05);
        return Transform.rotate(
          angle: angle * 3.14159 / 180,
          child: Transform.scale(
            scale: scale,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.size / 2),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: widget.gradient,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ==================== SHIMMER BUTTON ====================
class ShimmerBtn extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const ShimmerBtn({super.key, required this.label, required this.onTap});
  @override
  State<ShimmerBtn> createState() => _ShimmerBtnState();
}

class _ShimmerBtnState extends State<ShimmerBtn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _handleTap() {
    _ctrl.forward(from: 0.0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleBtn(
      onTap: _handleTap,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, child) {
          final shimmerProgress = (_ctrl.value * 3.5) - 1.5;
          return ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: ShaderMask(
              blendMode: BlendMode.srcATop,
              shaderCallback: (bounds) =>
                  LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withOpacity(0.0),
                      Colors.white.withOpacity(0.35),
                      Colors.white.withOpacity(0.0),
                    ],
                    stops: const [0.3, 0.5, 0.7],
                  ).createShader(
                    Rect.fromLTWH(
                      bounds.width * shimmerProgress,
                      0,
                      bounds.width,
                      bounds.height,
                    ),
                  ),
              child: Container(
                width: double.infinity,
                height: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: const LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [AppColors.redPrimary, AppColors.redLight],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.redPrimary.withOpacity(0.40),
                      blurRadius: 15,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ==================== INDICADOR DE CARGA PERSONALIZADO ====================// Asegúrate de importar al inicio

// MusicLoader con frames SVG
class MusicLoader extends StatelessWidget {
  final double scaleFactor;
  final double fixedSize;
  final bool fillMax;

  const MusicLoader({
    super.key,
    this.scaleFactor = 0.4,
    this.fixedSize = 0,
    this.fillMax = false,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    double size;
    if (fillMax) {
      size = screenWidth < screenHeight ? screenWidth : screenHeight;
    } else if (fixedSize > 0) {
      size = fixedSize;
    } else {
      size = screenWidth * scaleFactor.clamp(0.0, 1.0);
    }

    return Center(
      child: SizedBox(
        width: size,
        height: size,
        child: PochitaReproductor(size: size),
      ),
    );
  }
}

class _TriangleGlowPainter extends CustomPainter {
  final Color color;
  final double intensity;
  final double blurSigma;

  _TriangleGlowPainter({
    this.color = Colors.white,
    this.intensity = 0.7,
    this.blurSigma = 6.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withOpacity(intensity)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blurSigma);

    final path = Path();
    path.moveTo(0, 0); // esquina superior izquierda
    path.lineTo(size.width, 0); // esquina superior derecha
    path.lineTo(size.width / 2, size.height); // punta inferior central

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ==================== PANTALLA DE DESCARGAS (ESTILO NEGRO Y ROJO) ====================
class DownloadsScreen extends StatefulWidget {
  final VoidCallback onBack;
  final bool showDeviceFiles;
  final Function(Song) onPlaySong; // ← NUEVO
  const DownloadsScreen({
    super.key,
    required this.onBack,
    this.showDeviceFiles = false,
    required this.onPlaySong, // ← OBLIGATORIO
  });

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  List<Song> _songs = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadSongs();
  }

  Future<void> _loadSongs() async {
    setState(() => _isLoading = true);
    try {
      if (widget.showDeviceFiles) {
        final deviceSongs = await DownloadManager.getDeviceSongs();
        setState(
          () => _songs = deviceSongs
              .map(
                (ds) => Song(
                  audioPath: ds.localPath,
                  title: ds.title,
                  artist: ds.artist,
                  img: ds.img,
                  isOnline: false,
                ),
              )
              .toList(),
        );
      } else {
        final localSongs = await DownloadManager.getLocalSongs();
        setState(
          () => _songs = localSongs
              .map(
                (ds) => Song(
                  audioPath: ds.localPath,
                  title: ds.title,
                  artist: ds.artist,
                  img: ds.img,
                  isOnline: false,
                ),
              )
              .toList(),
        );
      }
    } catch (e) {
      print('Error cargando canciones: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.showDeviceFiles ? 'En el dispositivo' : 'Descargas';

    return Scaffold(
      backgroundColor: AppColors.bgBase,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header con retroceso y título
              Row(
                children: [
                  GestureDetector(
                    onTap: widget.onBack,
                    child: SvgPicture.asset(
                      'assets/iconos/Vector.svg',
                      width: 20,
                      height: 20,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: 'Stylish',
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  // Botón para limpiar (opcional)
                  ScaleBtn(
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Próximamente')),
                      );
                    },
                    child: const Icon(
                      Icons.delete_outline,
                      color: Color(0xFF71717A),
                      size: 24,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              if (widget.showDeviceFiles) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1F1F1F),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Mostrando archivos del dispositivo',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              // Estado de carga
              if (_isLoading)
                const Expanded(child: Center(child: MusicLoader()))
              // Estado vacío o lista
              else if (_songs.isEmpty) ...[
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.cloud_off,
                          color: Color(0xFF71717A),
                          size: 64,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No hay ${widget.showDeviceFiles ? 'archivos' : 'descargas'}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          widget.showDeviceFiles
                              ? 'No se encontraron archivos en el dispositivo'
                              : 'Las canciones que descargues aparecerán aquí',
                          style: const TextStyle(
                            color: Color(0xFF71717A),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ] else ...[
                Expanded(
                  child: ListView.builder(
                    itemCount: _songs.length,
                    itemBuilder: (context, index) {
                      final song = _songs[index];
                      return GestureDetector(
                        onTap: () => widget.onPlaySong(song),
                        child: _DownloadCard(song: song),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== TARJETA DE CANCIÓN DESCARGADA ====================
class _DownloadCard extends StatelessWidget {
  final Song song;
  const _DownloadCard({required this.song});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Row(
        children: [
          // Imagen
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: CachedNetworkImage(
              imageUrl: song.img,
              width: 60,
              height: 60,
              fit: BoxFit.cover,
              placeholder: (context, url) => Container(
                width: 60,
                height: 60,
                color: const Color(0xFF27272A),
                child: const Icon(Icons.music_note, color: Color(0xFF71717A)),
              ),
              errorWidget: (context, url, error) => Container(
                width: 60,
                height: 60,
                color: const Color(0xFF27272A),
                child: const Icon(Icons.music_note, color: Color(0xFF71717A)),
              ),
            ),
          ),
          const SizedBox(width: 14),
          // Información
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  song.artist,
                  style: const TextStyle(
                    color: Color(0xFF71717A),
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // Icono de descargado
          const Icon(Icons.check_circle, color: AppColors.redPrimary, size: 24),
        ],
      ),
    );
  }
}

// ==================== PANTALLA DE FAVORITOS ====================
class FavoritesScreen extends StatefulWidget {
  final VoidCallback onBack;
  final Function(Song) onPlaySong;

  const FavoritesScreen({
    super.key,
    required this.onBack,
    required this.onPlaySong,
  });

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  // Estado de selección múltiple
  bool _selectionModeEnabled = false;
  final Set<String> _selectedIds = {};

  // Estado de reproducción (aleatorio, repetición)
  final bool _isShuffle = false;
  RepeatMode _repeatMode = RepeatMode.none;

  // Para el progreso de descarga (local, no global)
  final ValueNotifier<Map<String, double>> _localDownloadProgress =
      ValueNotifier({});

  @override
  void initState() {
    super.initState();
    // Cargar estado de descargas al entrar
    WidgetsBinding.instance.addPostFrameCallback((_) {
      refreshDownloadStatus();
    });
  }

  @override
  void dispose() {
    _localDownloadProgress.dispose();
    super.dispose();
  }


  // ---------- Menú de papelera ----------

  void _showDeleteMenu() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_sweep, color: Colors.red),
              title: const Text('Borrar todo'),
              onTap: () {
                Navigator.pop(context);
                _deleteAllFavorites();
              },
            ),
            ListTile(
              leading: const Icon(Icons.checklist),
              title: const Text('Seleccionar'),
              onTap: () {
                Navigator.pop(context);
                _enableSelectionMode();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteAllFavorites() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar todos los favoritos'),
        content: const Text(
          'Esta acción borrará todas las canciones de tus favoritos y eliminará los archivos descargados. ¿Continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final currentFavorites = favoriteNotifier.value.toList();
    if (currentFavorites.isEmpty) return;

    // Eliminar archivos físicos
    for (final songId in currentFavorites) {
      final localSongs = await DownloadManager.getLocalSongs();
      final deviceSongs = await DownloadManager.getDeviceSongs();
      final local = localSongs.firstWhereOrNull((s) => s.videoId == songId);
      final device = deviceSongs.firstWhereOrNull((s) => s.videoId == songId);
      if (local != null) {
        try {
          await File(local.localPath).delete();
        } catch (_) {}
        await DownloadManager.removeLocalSong(songId);
      }
      if (device != null) {
        try {
          await File(device.localPath).delete();
        } catch (_) {}
        await DownloadManager.removeDeviceSong(songId);
      }
    }

    // Limpiar favoritos
    favoriteNotifier.value = {};

    // Sincronizar con la nube
    await DownloadSyncService.syncOnChange();

    // Actualizar estado de descargas
    await refreshDownloadStatus();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Todos los favoritos y archivos descargados han sido eliminados',
          ),
        ),
      );
    }
  }

  void _enableSelectionMode() {
    setState(() {
      _selectionModeEnabled = true;
      _selectedIds.clear();
    });
  }

  void _toggleSelection(String songId) {
    setState(() {
      if (_selectedIds.contains(songId)) {
        _selectedIds.remove(songId);
      } else {
        _selectedIds.add(songId);
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar seleccionadas'),
        content: Text(
          '¿Eliminar ${_selectedIds.length} canciones de favoritos y sus archivos descargados?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final idsToDelete = _selectedIds.toList();
    for (final songId in idsToDelete) {
      final localSongs = await DownloadManager.getLocalSongs();
      final deviceSongs = await DownloadManager.getDeviceSongs();
      final local = localSongs.firstWhereOrNull((s) => s.videoId == songId);
      final device = deviceSongs.firstWhereOrNull((s) => s.videoId == songId);
      if (local != null) {
        try {
          await File(local.localPath).delete();
        } catch (_) {}
        await DownloadManager.removeLocalSong(songId);
      }
      if (device != null) {
        try {
          await File(device.localPath).delete();
        } catch (_) {}
        await DownloadManager.removeDeviceSong(songId);
      }
    }

    // Eliminar de favoritos
    final remaining = favoriteNotifier.value
        .where((id) => !idsToDelete.contains(id))
        .toSet();
    favoriteNotifier.value = remaining;

    // Sincronizar con la nube
    await DownloadSyncService.syncOnChange();

    // Actualizar estado de descargas
    await refreshDownloadStatus();

    // Salir del modo selección
    setState(() {
      _selectionModeEnabled = false;
      _selectedIds.clear();
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${idsToDelete.length} canciones eliminadas')),
      );
    }
  }

  // ---------- Menú de descarga ----------

  void _showDownloadMenu() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('Descargar todos (App)'),
              onTap: () {
                Navigator.pop(context);
                _downloadAllFavorites(DownloadType.internal);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Descargar todos (Local)'),
              onTap: () {
                Navigator.pop(context);
                _downloadAllFavorites(DownloadType.public);
              },
            ),
            ListTile(
              leading: const Icon(Icons.checklist),
              title: const Text('Elegir qué descargar'),
              onTap: () {
                Navigator.pop(context);
                _enableDownloadSelection();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _downloadAllFavorites(DownloadType type) async {
    final favoriteIds = favoriteNotifier.value.toList();
    if (favoriteIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No tienes favoritos para descargar')),
      );
      return;
    }

    // Obtener los objetos Song
    final songsToDownload = favoriteIds
        .map((id) => database.firstWhereOrNull((s) => s.audioPath == id))
        .whereType<Song>()
        .toList();

    if (songsToDownload.isEmpty) return;

    // Mostrar Snackbar de inicio
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Iniciando descarga de ${songsToDownload.length} canciones...',
        ),
      ),
    );

    // Iniciar descarga una por una con progreso
    int successCount = 0;
    for (final song in songsToDownload) {
      // Verificar si ya está descargada
      final isDownloaded = await DownloadManager.isSongDownloaded(
        song.audioPath,
      );
      if (isDownloaded) {
        successCount++;
        continue;
      }

      try {
        // Iniciar descarga con progreso
        await downloadSongWithProgress(
          song: song,
          isLocal: type == DownloadType.internal,
          onProgress: (received, total) {
            final progress = received / total;
            _localDownloadProgress.value = {
              ..._localDownloadProgress.value,
              song.audioPath: progress,
            };
          },
        );
        // Actualizar estado de descargas
        await refreshDownloadStatus();
        successCount++;
      } catch (e) {
        print('Error descargando ${song.title}: $e');
      }
    }

    // Limpiar progresos
    _localDownloadProgress.value = {};

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Descarga completada. $successCount canciones descargadas.',
          ),
        ),
      );
    }
  }

  void _enableDownloadSelection() {
    // Activamos el modo de selección para descargar solo las marcadas
    setState(() {
      _selectionModeEnabled = true;
      _selectedIds.clear();
    });
    // Cambiamos la acción de la barra inferior para mostrar "Descargar seleccionadas"
  }

  Future<void> _downloadSelected() async {
    if (_selectedIds.isEmpty) return;

    final songsToDownload = _selectedIds
        .map((id) => database.firstWhereOrNull((s) => s.audioPath == id))
        .whereType<Song>()
        .toList();

    if (songsToDownload.isEmpty) return;

    // Preguntar dónde descargar
    final type = await showDialog<DownloadType>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Descargar seleccionadas'),
        content: const Text('Elige la ubicación:'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, DownloadType.internal),
            child: const Text('En la App'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, DownloadType.public),
            child: const Text('En el dispositivo'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
    if (type == null) return;

    int successCount = 0;
    for (final song in songsToDownload) {
      final isDownloaded = await DownloadManager.isSongDownloaded(
        song.audioPath,
      );
      if (isDownloaded) {
        successCount++;
        continue;
      }
      try {
        await downloadSongWithProgress(
          song: song,
          isLocal: type == DownloadType.internal,
          onProgress: (received, total) {
            final progress = received / total;
            _localDownloadProgress.value = {
              ..._localDownloadProgress.value,
              song.audioPath: progress,
            };
          },
        );
        await refreshDownloadStatus();
        successCount++;
      } catch (e) {
        print('Error descargando ${song.title}: $e');
      }
    }
    _localDownloadProgress.value = {};

    // Salir del modo selección
    setState(() {
      _selectionModeEnabled = false;
      _selectedIds.clear();
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Descarga completada. $successCount canciones descargadas.',
          ),
        ),
      );
    }
  }

  // ---------- Aleatorio y repetición ----------

  void _shuffleFavorites() {
    final favorites = favoriteNotifier.value.toList();
    if (favorites.isEmpty) return;
    final allSongs = allSongsNotifier.value;
final favoriteSongs = favorites
    .map((id) => allSongs[id])
    .whereType<Song>()
    .toList();
    if (favoriteSongs.isEmpty) return;
    // Reproducir en orden aleatorio
    final shuffled = List<Song>.from(favoriteSongs)..shuffle();
    // Buscar el contexto de AppShell para playSongFromList
    final appShell = context.findAncestorStateOfType<_AppShellState>();
    if (appShell != null) {
      appShell.playSongFromList(shuffled.first, shuffled);
    } else {
      // Fallback: reproducir el primero
      widget.onPlaySong(shuffled.first);
    }
  }

  void _toggleRepeat() {
    setState(() {
      _repeatMode = {
        RepeatMode.none: RepeatMode.all,
        RepeatMode.all: RepeatMode.one,
        RepeatMode.one: RepeatMode.none,
      }[_repeatMode]!;
    });
  }

  // ---------- Build ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header con retroceso y título
              Row(
                children: [
                  GestureDetector(
                    onTap: widget.onBack,
                    child: RepaintBoundary(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: SvgPicture.asset(
                          'assets/iconos/Vector.svg',
                          fit: BoxFit.contain,
                          colorFilter: const ColorFilter.mode(
                            Colors.white,
                            BlendMode.srcIn,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Mis Favoritos',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Barra de herramientas
              _buildToolbar(),

              const SizedBox(height: 8),

              // Lista de favoritos
              Expanded(
                child: ValueListenableBuilder<Set<String>>(
                  valueListenable: favoriteNotifier,
                  builder: (context, favorites, _) {
               final allSongs = allSongsNotifier.value;
final favoriteSongs = favorites
    .map((id) => allSongs[id])
    .whereType<Song>()
    .toList();

                    if (favoriteSongs.isEmpty) {
                      return Center(
                        child: Opacity(
                          opacity: 0.8,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Image.asset(
                                'assets/imagenes/tefalla.png',
                                width: 128,
                                height: 128,
                                fit: BoxFit.contain,
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'No tienes favoritos aún',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Dale ❤️ a tus canciones favoritas',
                                style: TextStyle(
                                  color: Color(0xFFB0B0B0),
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }

                    // Si está en modo selección, mostrar contador y botón de acción
                    if (_selectionModeEnabled) {
                      return Column(
                        children: [
                          Expanded(
                            child: ListView.builder(
                              itemCount: favoriteSongs.length,
                              itemBuilder: (context, index) {
                                final song = favoriteSongs[index];
                                final isSelected = _selectedIds.contains(
                                  song.audioPath,
                                );
                                return GestureDetector(
                                  onTap: () => _toggleSelection(song.audioPath),
                                  child:
                                      ValueListenableBuilder<Map<String, bool>>(
                                        valueListenable: downloadStatusNotifier,
                                        builder: (context, statusMap, _) {
                                          final isDownloaded =
                                              statusMap[song.audioPath] ??
                                              false;
                                          return ValueListenableBuilder<
                                            Map<String, double>
                                          >(
                                            valueListenable:
                                                _localDownloadProgress,
                                            builder: (context, progressMap, _) {
                                              final progress =
                                                  progressMap[song.audioPath] ??
                                                  -1.0;
                                              return SongListCard(
                                                imageUrl: song.img,
                                                songTitle: song.title,
                                                artistLabel: song.artist,
                                                albumName: 'Álbum',
                                                isFavorite: true,
                                                isDownloaded: isDownloaded,
                                                downloadProgress: progress,
                                                showCheckbox: true,
                                                isChecked: isSelected,
                                                onCheckboxChanged: () =>
                                                    _toggleSelection(
                                                      song.audioPath,
                                                    ),
                                                onTap:
                                                    null, // ya manejamos el tap
                                              );
                                            },
                                          );
                                        },
                                      ),
                                );
                              },
                            ),
                          ),
                          // Botón inferior de acción
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                ElevatedButton.icon(
                                  onPressed: _selectedIds.isEmpty
                                      ? null
                                      : _deleteSelected,
                                  icon: const Icon(
                                    Icons.delete,
                                    color: Colors.red,
                                  ),
                                  label: Text(
                                    'Eliminar (${_selectedIds.length})',
                                    style: const TextStyle(color: Colors.red),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.transparent,
                                    side: const BorderSide(color: Colors.red),
                                  ),
                                ),
                                ElevatedButton.icon(
                                  onPressed: _selectedIds.isEmpty
                                      ? null
                                      : _downloadSelected,
                                  icon: const Icon(
                                    Icons.download,
                                    color: Colors.green,
                                  ),
                                  label: Text(
                                    'Descargar (${_selectedIds.length})',
                                    style: const TextStyle(color: Colors.green),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.transparent,
                                    side: const BorderSide(color: Colors.green),
                                  ),
                                ),
                                OutlinedButton(
                                  onPressed: () {
                                    setState(() {
                                      _selectionModeEnabled = false;
                                      _selectedIds.clear();
                                    });
                                  },
                                  child: const Text('Cancelar'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    }

                    // Modo normal (sin selección)
                    return ListView.builder(
                      itemCount: favoriteSongs.length,
                      itemBuilder: (context, index) {
                        final song = favoriteSongs[index];
                        return ValueListenableBuilder<Map<String, bool>>(
                          valueListenable: downloadStatusNotifier,
                          builder: (context, statusMap, _) {
                            final isDownloaded =
                                statusMap[song.audioPath] ?? false;
                            return ValueListenableBuilder<Map<String, double>>(
                              valueListenable: _localDownloadProgress,
                              builder: (context, progressMap, _) {
                                final progress =
                                    progressMap[song.audioPath] ?? -1.0;
                                return GestureDetector(
                                  onTap: () => widget.onPlaySong(song),
                                  child: SongListCard(
                                    imageUrl: song.img,
                                    songTitle: song.title,
                                    artistLabel: song.artist,
                                    albumName: 'Álbum',
                                    isFavorite: true,
                                    isDownloaded: isDownloaded,
                                    downloadProgress: progress,
                                    showCheckbox: false,
                                  ),
                                );
                              },
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Widget de la barra de herramientas
  Widget _buildToolbar() {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8.0),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Papelera (ícono rojo)
        ScaleBtn(
          onTap: _showDeleteMenu,
          child: Icon(Icons.delete_outline, color: Colors.red, size: 28),
        ),
        // Shuffle (SVG)
        ScaleBtn(
          onTap: _shuffleFavorites,
          child: SvgPicture.asset(
            'assets/iconos/aleatorio.svg',
            width: 28,
            height: 28,
            colorFilter: ColorFilter.mode(
              _isShuffle ? AppColors.redPrimary : Colors.white70,
              BlendMode.srcIn,
            ),
          ),
        ),
        // Play/Pause (con círculo, igual que NowPlaying)
        ValueListenableBuilder<bool>(
          valueListenable: audioPlayerService.isPlayingNotifier,
          builder: (context, isPlaying, _) {
            return ScaleBtn(
              onTap: () {
                final favorites = favoriteNotifier.value.toList();
                if (favorites.isEmpty) return;
                final allSongs = allSongsNotifier.value;
                final favoriteSongs = favorites
                    .map((id) => allSongs[id])
                    .whereType<Song>()
                    .toList();
                if (favoriteSongs.isEmpty) return;
                final currentSong = audioPlayerService.currentPath;
                // Si suena y está en favoritos, pausar
                if (currentSong != null &&
                    favorites.contains(currentSong) &&
                    audioPlayerService.isPlayingNotifier.value) {
                  audioPlayerService.pause();
                  return;
                }
                // Reproducir la primera canción de favoritos
                widget.onPlaySong(favoriteSongs.first);
              },
              child: Container(
                width: 80,
                height: 80,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF16181E),
                ),
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: SvgPicture.asset(
                      audioPlayerService.isPlayingNotifier.value &&
                              favoriteNotifier.value.contains(
                                  audioPlayerService.currentPath)
                          ? 'assets/iconos/Pause1.svg'
                          : 'assets/iconos/Play1.svg',
                      key: ValueKey(audioPlayerService.isPlayingNotifier.value),
                      width: 48,
                      height: 48,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        // Repeat (SVG, cambia entre repetir todo y repetir uno)
        ScaleBtn(
          onTap: _toggleRepeat,
          child: SvgPicture.asset(
            _repeatMode == RepeatMode.one
                ? 'assets/iconos/Repetir1.svg'
                : 'assets/iconos/Repetir.svg',
            width: 22,
            height: 22,
            colorFilter: ColorFilter.mode(
              _repeatMode != RepeatMode.none ? AppColors.redPrimary : Colors.white70,
              BlendMode.srcIn,
            ),
          ),
        ),
        // Descarga (ícono Material)
        ScaleBtn(
          onTap: _showDownloadMenu,
          child: Icon(Icons.file_download_outlined, color: Colors.white70, size: 28),
        ),
      ],
    ),
  );
}
}

class _EmptyAlbumCarousel extends StatelessWidget {
  const _EmptyAlbumCarousel();

  @override
  Widget build(BuildContext context) {
    // Mostramos un carrusel con tarjetas vacías (placeholder)
    return SizedBox(
      height: 208 + 48, // altura similar a AlbumCarousel
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
        itemCount: 6, // número de tarjetas placeholder
        itemBuilder: (context, index) {
          return Container(
            width: 160,
            height: 200,
            margin: const EdgeInsets.only(right: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              color: const Color(0xFF1A1A1A),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.music_note,
                  color: Colors.white.withOpacity(0.2),
                  size: 48,
                ),
                const SizedBox(height: 8),
                Text(
                  'Próximamente',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.3),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class ConnectivityService {
  static Future<bool> isConnected() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    return connectivityResult != ConnectivityResult.none;
  }
}

class _DownloadProgressDialog extends StatefulWidget {
  final Song song;
  final bool isLocal;
  const _DownloadProgressDialog({required this.song, required this.isLocal});

  @override
  State<_DownloadProgressDialog> createState() =>
      _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<_DownloadProgressDialog> {
  double _progress = 0.0;
  bool _isComplete = false;
  String _status = 'Iniciando descarga...';

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  Future<void> _startDownload() async {
    try {
      final filePath = await downloadSongWithProgress(
        song: widget.song,
        isLocal: widget.isLocal,
        onProgress: (received, total) {
          final progress = received / total;
          setState(() {
            _progress = progress;
            _status = '${(progress * 100).toStringAsFixed(0)}%';
          });
        },
      );
      setState(() {
        _isComplete = true;
        _status = '¡Descarga completada!';
      });
      // Esperar un momento y cerrar
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) Navigator.pop(context);
    } on DuplicateSongException {
      // Ya se manejó antes, pero por si acaso
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('La canción ya está descargada')),
      );
    } catch (e) {
      setState(() {
        _status = 'Error: ${e.toString()}';
        _isComplete = true;
      });
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) Navigator.pop(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error al descargar: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.isLocal
            ? 'Descargando localmente...'
            : 'Descargando al dispositivo...',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(value: _isComplete ? 1.0 : _progress),
          const SizedBox(height: 10),
          Text(_status),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isComplete ? () => Navigator.pop(context) : null,
          child: const Text('Cerrar'),
        ),
      ],
    );
  }
}
