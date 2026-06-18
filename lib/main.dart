import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ImageFilter;
import 'package:device_preview/device_preview.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'firebase_options.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:likeus/likeus.dart';
import 'package:just_audio/just_audio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'models/song.dart';
import 'services/music_api_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';

Future<List<Song>> getDeviceSongs() async {
  final result = await FilePicker.platform.pickFiles(
    allowMultiple: true,
    type: FileType.audio,
  );
  if (result == null) return [];
  return result.paths.map((path) {
    final file = File(path!);
    final fileName = file.path.split('/').last;
    // Puedes intentar leer metadatos ID3 si quieres, pero por ahora usamos el nombre
    return Song(
      audioPath: file.path,
      title: fileName,
      artist: 'Dispositivo',
      img: '', // sin imagen
      isOnline: false,
    );
  }).toList();
}

Future<String> downloadSong(Song song) async {
  final dir = await getApplicationDocumentsDirectory();
  final fileName = p.basename(
    Uri.parse(song.audioPath).path,
  ); // extrae nombre del archivo
  final filePath = p.join(dir.path, fileName);
  final dio = Dio();
  await dio.download(song.audioPath, filePath);
  return filePath; // retorna la ruta local del archivo
}

enum RepeatMode { none, all, one }

// Después de los imports, antes de final ValueNotifier...
final AudioPlayerService audioPlayerService = AudioPlayerService();
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
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
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

class DownloadManager {
  static const String _key = 'downloaded_songs';

  static Future<List<String>> getDownloadedPaths() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key) ?? [];
  }

  static Future<void> addDownloadedPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await getDownloadedPaths();
    if (!list.contains(path)) {
      list.add(path);
      await prefs.setStringList(_key, list);
    }
  }

  static Future<void> removeDownloadedPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await getDownloadedPaths();
    list.remove(path);
    await prefs.setStringList(_key, list);
  }
}

class AudioPlayerService {
  static final AudioPlayerService _instance = AudioPlayerService._internal();
  factory AudioPlayerService() => _instance;
  AudioPlayerService._internal();

  final AudioPlayer _player = AudioPlayer();

  AudioPlayer get player => _player;
  final bool _isLoading = false;

  Future<void> loadSong(String assetPath, {bool autoPlay = false}) async {
    await _player.stop();
    try {
      try {
        await _player.setAudioSource(AudioSource.file(""), preload: false);
      } catch (_) {}

      // 🔥 NUEVO: Si es una URL HTTP, cargarla directamente
      if (assetPath.startsWith('http')) {
        await _player.setUrl(assetPath);
      } else if (kIsWeb) {
        final baseUrl = Uri.base.origin;
        final path = assetPath.startsWith('assets/')
            ? assetPath.substring(7)
            : assetPath;
        final fullUrl = '$baseUrl/assets/$path';
        print('🌐 Cargando URL: $fullUrl');
        await _player.setUrl(fullUrl);
      } else {
        await _player.setAsset(assetPath);
      }

      print('✅ Canción cargada: $assetPath');

      if (autoPlay) {
        await _waitForPlayerReady();
        await _player.play();
        print('▶️ Reproduciendo automáticamente');
      }
    } catch (e) {
      print('❌ Error al cargar: $assetPath, $e');
    }
  }

  Future<void> _waitForPlayerReady() async {
    // Esperar hasta que processingState no sea 'loading' ni 'none'
    Completer<void> completer = Completer();
    StreamSubscription<ProcessingState>? sub;
    sub = _player.processingStateStream.listen((state) {
      if (state == ProcessingState.ready ||
          state == ProcessingState.buffering ||
          state == ProcessingState.completed) {
        if (!completer.isCompleted) {
          completer.complete();
          sub?.cancel();
        }
      }
    });
    // Timeout por si acaso
    await completer.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        print('⚠️ Tiempo de espera agotado, reproduciendo de todos modos');
        if (!completer.isCompleted) completer.complete();
      },
    );
  }

  // Delegar las funciones de control (devuelven Future para poder await)
  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> stop() => _player.stop();
  Future<void> seek(Duration position) => _player.seek(position);

  // Liberar recursos cuando ya no se use
  void dispose() => _player.dispose();
}

const List<Song> database = [
  Song(
    audioPath: 'assets/audios/canto-de-soy-un-nina-cansada.mp3',
    title: 'Soy una niña-Remix',
    artist: 'Alan Ortiz',
    img: 'assets/imagenes/nega.jpg',
  ),
  Song(
    audioPath: 'assets/audios/el-la-estaba-esperando-con-una-flor-amarilla.mp3',
    title: 'Con una flor amarilla',
    artist: 'Alan Ortiz',
    img: 'assets/imagenes/posa.jpg',
  ),
  Song(
    audioPath: 'assets/audios/dame-de-tu-vide-y-de-tu-tiempo.mp3',
    title: 'Dame de tu vida',
    artist: 'Alan Ortiz',
    img: 'assets/imagenes/dae.jpg',
  ),
  Song(
    audioPath: 'assets/audios/como-quieres-tu-que-te-quiera.mp3',
    title: 'Como quieres tu ',
    artist: 'Alan Ortiz',
    img: 'assets/imagenes/lol.jpg',
  ),
  Song(
    audioPath: 'assets/audios/silencio_le-va-a-doler.mp3',
    title: 'Le va a doler',
    artist: 'Alan Ortiz',
    img: 'assets/imagenes/su.jpg',
  ),
  Song(
    audioPath: 'assets/audios/soy-una-nina-cnasada-de-estar.mp3',
    title: 'Soy una niña cansada',
    artist: 'Alan Ortiz',
    img: 'assets/imagenes/ojo.jpg',
  ),
  Song(
    audioPath: 'assets/audios/es-que-lo-borre-por-que-jejej.mp3',
    title: 'Por que jejej',
    artist: 'Alan Ortiz',
    img: 'assets/imagenes/jeja.jpg',
  ),
  Song(
    audioPath: 'assets/audios/el-diablo.mp3',
    title: 'El Diablo',
    artist: 'Alan Ortiz',
    img: 'assets/imagenes/ico.jpg',
  ),
];

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
        textTheme: GoogleFonts.poppinsTextTheme(ThemeData.dark().textTheme),
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

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
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
    this.progress = 0.0, // opcional, ya no se usa
    this.currentTime = '0:00', // opcional
    this.totalTime = '0:00', // opcional
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
              child: CachedNetworkImage(
                imageUrl: song.img,
                fit: BoxFit.cover,
                placeholder: (context, url) => Container(
                  color: const Color(0xFF27272A),
                  child: const Center(
                    child: Icon(
                      Icons.music_note,
                      color: Color(0xFF71717A),
                      size: 48,
                    ),
                  ),
                ),
                errorWidget: (context, url, error) => Container(
                  color: const Color(0xFF27272A),
                  child: const Center(
                    child: Icon(
                      Icons.music_note,
                      color: Color(0xFF71717A),
                      size: 48,
                    ),
                  ),
                ),
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
                  child: SvgPicture.network(
                    'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/05aafb194afaa258e1e1f13ced7dc76f5f5db11d/back.svg',
                    width: 20,
                    height: 20,
                  ),
                ),
                const SizedBox(width: 12),
                // Play/Pause
                ScaleBtn(
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
                        child: SvgPicture.network(
                          isPlaying
                              ? 'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/05aafb194afaa258e1e1f13ced7dc76f5f5db11d/Pause1.svg'
                              : 'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/05aafb194afaa258e1e1f13ced7dc76f5f5db11d/Play1.svg',
                          key: ValueKey(isPlaying),
                          width: 22,
                          height: 22,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Siguiente
                ScaleBtn(
                  onTap: onNext,
                  child: SvgPicture.network(
                    'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/05aafb194afaa258e1e1f13ced7dc76f5f5db11d/Next.svg',
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

class _AppShellState extends State<AppShell> {
  AppScreen _current = AppScreen.welcome;
  int _navIndex = 0;
  bool _downloadsShowDeviceFiles = false;
  Song _currentSong = emptySong;
  bool _isPlaying = false;
  List<Song> _currentSongList = database;
  int _currentSongIndex = 0;
  bool _showMiniPlayer = false;
  final bool _forceHideBar = false;
  bool _hasStartedPlaying = false;

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
    // Listener de autenticación
    FirebaseAuth.instance.authStateChanges().listen((User? user) async {
      if (user != null) {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
        final hasCompleteProfile =
            doc.exists &&
            (doc.data()?['nickname']?.isNotEmpty == true) &&
            (doc.data()?['avatarUrl']?.isNotEmpty == true);
        if (hasCompleteProfile) {
          final nickname = doc.data()?['nickname'] ?? 'Usuario';
          final avatarUrl = doc.data()?['avatarUrl'] ?? '';
          final avatarHasOwnCircle = doc.data()?['avatarHasOwnCircle'] ?? false;
          userProfileNotifier.value = UserProfile(
            nickname: nickname,
            avatarUrl: avatarUrl,
            avatarHasOwnCircle: avatarHasOwnCircle,
            isLoaded: true,
          );

          final favoritesList =
              (doc.data()?['favorites'] as List?)?.cast<String>() ?? [];
          favoriteNotifier.value = Set.of(favoritesList);
          favoriteNotifier.addListener(saveFavoritesToFirestore);

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _resetPlayer();
            navigate(AppScreen.home);
            _updateMiniPlayerVisibility();
          });
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            navigate(AppScreen.profileSetup);
          });
        }
      } else {
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
    if (_current == target) return;
    _currentScreenNotifier.value = target; // <-- añadir esta línea
    _safeSetState(() {
      // almacenar la intención de mostrar archivos del dispositivo en Descargas
      _downloadsShowDeviceFiles = showDeviceFiles;
      _current = target;
      if (navIndex != null) _navIndex = navIndex;
    });
    _updateMiniPlayerVisibility();
  }

  void playSongFromList(Song song, List<Song> songList) {
    final index = songList.indexWhere((s) => s.audioPath == song.audioPath);
    if (index == -1) return;
    _safeSetState(() {
      _currentSong = song;
      _currentSongList = songList;
      _currentSongIndex = index;
      _isPlaying = false;
      _hasStartedPlaying = true;
    });
    audioPlayerService.loadSong(song.audioPath, autoPlay: false);
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
    _safeSetState(() => _isPlaying = !_isPlaying);
    if (_isPlaying) {
      audioPlayerService.play();
    } else {
      audioPlayerService.pause();
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

  // ---------- Build ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgBase,
      body: Stack(
        children: [
          // Fondo animado SOLO para welcome y login
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

          // Contenido que cambia
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            transitionBuilder: (child, animation) {
              // Animación de entrada: desde abajo y fade
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position:
                      Tween<Offset>(
                        begin: const Offset(0, 0.2), // viene desde abajo
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
                            (_duration != null && _duration!.inMilliseconds > 0)
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
                    navigate(targets[i], navIndex: i);
                  },
                ),
              ],
            ),
          ),
        ],
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
          onOpenNowPlaying: (song) => playSongFromList(song, database),
          onNavigate: navigate,
        );
      case AppScreen.search:
        return SearchScreen(
          key: const ValueKey('search'),
          onBack: () => navigate(AppScreen.home, navIndex: 0),
          onPlay: (song) => playSongFromList(song, database),
        );
      case AppScreen.notifications:
        return NotificationsScreen(
          key: const ValueKey('noti'),
          onBack: () => navigate(AppScreen.home, navIndex: 0),
        );
      case AppScreen.nowPlaying:
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
              style: GoogleFonts.tiny5(
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
            style: GoogleFonts.happyMonkey(
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
                filter: ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
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
                        style: GoogleFonts.poppins(
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
  }

  // ========== AUTENTICACIÓN (todos los métodos sin cambios) ==========
  Future<void> _signInWithGoogle() async {
    setState(() {
      _isLoading = true;
      _msg = '';
    });
    try {
      final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) {
        setState(() {
          _isLoading = false;
          _msg = 'Inicio de sesión cancelado';
        });
        return;
      }
      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
    } catch (e) {
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
      final signInMethods = await FirebaseAuth.instance
          .fetchSignInMethodsForEmail(email);
      print('🔍 Métodos existentes para $email: $signInMethods');

      if (signInMethods.contains('google.com')) {
        setState(() {
          _msg =
              'Este correo ya está registrado con Google. Usa el botón de Google.';
          _isLoading = false;
        });
        return;
      }
      if (signInMethods.contains('password')) {
        setState(() {
          _msg = 'Este correo ya tiene contraseña. Inicia sesión.';
          _isLoading = false;
        });
        return;
      }

      final userCredential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: password);
      final user = userCredential.user;
      if (user == null) throw Exception('No se pudo crear el usuario');

      await user.reload();
      final updatedUser = FirebaseAuth.instance.currentUser;
      final hasPassword =
          updatedUser?.providerData.any(
            (info) => info.providerId == 'password',
          ) ??
          false;

      if (!hasPassword) {
        print(
          '⚠️ El usuario no tiene proveedor password. Vinculando manualmente...',
        );
        final credential = EmailAuthProvider.credential(
          email: email,
          password: password,
        );
        await user.linkWithCredential(credential);
        await user.reload();
        print('✅ Proveedor password vinculado correctamente.');
      } else {
        print('✅ El usuario SÍ tiene proveedor password.');
      }

      print('✅ Registro exitoso con email/password');
    } on FirebaseAuthException catch (e) {
      print('❌ FirebaseAuthException en registro: ${e.code} - ${e.message}');
      String errorMsg;
      switch (e.code) {
        case 'email-already-in-use':
          errorMsg = 'Este correo ya está registrado. Inicia sesión.';
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
      print('❌ Error inesperado en registro: $e');
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
      hintStyle: GoogleFonts.happyMonkey(
        color: const Color(0xFF9A9A9A),
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
      prefixIcon: Padding(
        padding: const EdgeInsets.all(12),
        child: SvgPicture.network(
          svgUrl,
          width: 18,
          height: 18,
          color: const Color(0xFF9A9A9A),
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
                  style: GoogleFonts.tiny5(
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
                  style: GoogleFonts.happyMonkey(
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
                  style: GoogleFonts.poppins(
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
                  style: GoogleFonts.happyMonkey(
                    color: Colors.white,
                    fontSize: 14,
                  ),
                  keyboardType: TextInputType.emailAddress,
                  decoration: _fieldDeco(
                    _isLoginMode
                        ? 'ejemplo@correo.com o tu apodo'
                        : 'tuemail@ejemplo.com',
                    _isLoginMode
                        ? 'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/171a6c870bcbd7d5923a62232de0a3bf00516d2b/persona.svg'
                        : 'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/161dfa2b8db0c39450db78d4196341372d8b7fb2/correo.svg',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Transform.translate(
                offset: Offset(0, -70),
                child: Text(
                  'Contraseña',
                  style: GoogleFonts.poppins(
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
                  style: GoogleFonts.happyMonkey(
                    color: Colors.white,
                    fontSize: 14,
                  ),
                  obscureText: _obscurePass,
                  decoration: _fieldDeco(
                    'Contraseña',
                    'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/161dfa2b8db0c39450db78d4196341372d8b7fb2/contrase%C3%B1a.svg',
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
                      style: GoogleFonts.merienda(
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
                  style: GoogleFonts.merienda(
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
                        style: GoogleFonts.merienda(
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
                        style: GoogleFonts.merienda(
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
                            style: GoogleFonts.poppins(
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
            child: const MusicLoader(),
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
                style: GoogleFonts.stylish(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Elige cómo te llamaremos y tu avatar',
                style: GoogleFonts.happyMonkey(
                  color: const Color(0xFF9A9A9A),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 32),
              Text(
                'Apodo',
                style: GoogleFonts.poppins(
                  color: const Color(0xFF9A9A9A),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              TextField(
                controller: _nicknameController,
                style: GoogleFonts.happyMonkey(
                  color: Colors.white,
                  fontSize: 14,
                ),
                decoration: InputDecoration(
                  hintText: 'Ej. Pepito',
                  hintStyle: GoogleFonts.happyMonkey(
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
                style: GoogleFonts.poppins(
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

class HomeScreen extends StatefulWidget {
  final Function(Song) onOpenNowPlaying;
  final Function(AppScreen, {int? navIndex}) onNavigate;

  const HomeScreen({
    super.key,
    required this.onOpenNowPlaying,
    required this.onNavigate,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Genre _genre = Genre.musica;
  bool _isLoading = false;
  bool _isConnected = true; // por defecto true
  List<Song> _onlineTracks = []; // Canciones para la pestaña Online
  List<Song> _estilosTracks = []; // Canciones para la pestaña Estilos

  String get _greeting {
    final h = DateTime.now().hour;
    if (h >= 5 && h < 12) return 'Buenos días';
    if (h >= 12 && h < 18) return 'Buenas tardes';
    return 'Buenas noches';
  }

  @override
  void initState() {
    super.initState();
    _checkConnectivityAndLoadData();
  }

  // Método que carga datos según conectividad
  Future<void> _checkConnectivityAndLoadData() async {
    final connected = await ConnectivityService.isConnected();
    setState(() {
      _isConnected = connected;
    });
    if (connected) {
      await _loadOnlineData();
    }
  }

  Future<void> _loadOnlineData() async {
    setState(() => _isLoading = true);
    try {
      final apiService = MusicApiService();
      final topTracks = await apiService.getTopTracks();
      final popTracks = await apiService.getTracksByGenre('pop');
      setState(() {
        _onlineTracks = topTracks;
        _estilosTracks = popTracks;
        _isLoading = false;
      });
    } catch (e) {
      print('Error al cargar datos online: $e');
      setState(() => _isLoading = false);
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
              style: GoogleFonts.merienda(color: Colors.white60, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              'Conéctate para ver las canciones del mundo',
              style: TextStyle(color: Color(0xFF71717A), fontSize: 14),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _checkConnectivityAndLoadData,
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    if (_isLoading) {
      return const Center(child: MusicLoader());
    }

    if (_onlineTracks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.music_off, color: Colors.white60, size: 64),
            const SizedBox(height: 16),
            Text(
              'No hay canciones disponibles',
              style: GoogleFonts.merienda(color: Colors.white60, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              'Intenta de nuevo más tarde',
              style: TextStyle(color: Color(0xFF71717A), fontSize: 14),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadOnlineData,
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Text(
          'Lanzamientos más nuevos',
          style: GoogleFonts.merienda(
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
          onTap: widget.onOpenNowPlaying,
        ),
        const SizedBox(height: 28),
        Text(
          'Géneros',
          style: GoogleFonts.merienda(
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
          onTap: widget.onOpenNowPlaying,
        ),
      ],
    );
  }

  // Widget para la pestaña "Estilos"
  Widget _buildEstilosContent() {
    // Lógica similar a Online, pero con _estilosTracks
    if (!_isConnected) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.wifi_off, color: Colors.white60, size: 64),
            const SizedBox(height: 16),
            Text(
              'No estás conectado a internet',
              style: GoogleFonts.merienda(color: Colors.white60, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              'Conéctate para ver estilos musicales',
              style: TextStyle(color: Color(0xFF71717A), fontSize: 14),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _checkConnectivityAndLoadData,
              child: const Text('Reintentar'),
            ),
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
              style: GoogleFonts.merienda(color: Colors.white60, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              'Intenta de nuevo más tarde',
              style: TextStyle(color: Color(0xFF71717A), fontSize: 14),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadOnlineData,
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Text(
          'Estilos populares',
          style: GoogleFonts.merienda(
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
          onTap: widget.onOpenNowPlaying,
        ),
        const SizedBox(height: 28),
        Text(
          'Recomendados',
          style: GoogleFonts.merienda(
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
          onTap: widget.onOpenNowPlaying,
        ),
      ],
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
          songs: database.sublist(0, 4),
          cardWidth: 191,
          cardHeight: 202,
          onTap: widget.onOpenNowPlaying,
        ),
        const SizedBox(height: 28),
        Text(
          'Introduciones Cortas',
          style: GoogleFonts.merienda(
            color: Color(0xFFE5E5E5),
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        AlbumCarousel(
          songs: database.sublist(4, 8),
          cardWidth: 192,
          cardHeight: 208,
          onTap: widget.onOpenNowPlaying,
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
          style: GoogleFonts.merienda(
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
          style: GoogleFonts.merienda(
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
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
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
                          style: GoogleFonts.happyMonkey(
                            color: Color(0xFFD6D3D1),
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          nickname,
                          style: GoogleFonts.merienda(
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
                                child: SvgPicture.network(
                                  'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/03c748171c0e7766a11004b2a64e8c650c9d9526/busqueda.svg',
                                  width: 20,
                                  height: 20,
                                  fit: BoxFit.contain,
                                  colorFilter: const ColorFilter.mode(
                                    Colors.white,
                                    BlendMode.srcIn,
                                  ),
                                  placeholderBuilder: (_) =>
                                      const MusicLoader(),
                                  errorBuilder: (_, _, _) => const Icon(
                                    Icons.search,
                                    color: Colors.white,
                                    size: 20,
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
                                child: SvgPicture.network(
                                  'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/9ce4623b7dda17699b153a3f666b6601711e0154/notifi.svg',
                                  width: 19,
                                  height: 19,
                                  fit: BoxFit.contain,
                                  colorFilter: const ColorFilter.mode(
                                    Colors.white,
                                    BlendMode.srcIn,
                                  ),
                                  placeholderBuilder: (_) =>
                                      const MusicLoader(),
                                  errorBuilder: (_, _, _) => const Icon(
                                    Icons.notifications,
                                    color: Colors.white,
                                    size: 20,
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
                        // NO navegamos a otra pantalla
                      },
                    ),
                    _GenreTab(
                      label: 'Musica',
                      active: _genre == Genre.musica,
                      large: true,
                      onTap: () => setState(() => _genre = Genre.musica),
                    ),
                    _GenreTab(
                      label: 'Estilos',
                      active: _genre == Genre.estilos,
                      large: false,
                      onTap: () {
                        setState(() => _genre = Genre.estilos);
                        // NO navegamos a otra pantalla
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // Contenido según la pestaña seleccionada
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _buildContentForGenre(),
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
          fontFamily: GoogleFonts.stylish().fontFamily,
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
  }

  void _updateCenter() {
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
                  child: CachedNetworkImage(
                    imageUrl: song.img,
                    fit: BoxFit.cover,
                    placeholder: (context, url) => Container(
                      color: const Color(0xFF27272A),
                      child: const Center(
                        child: Icon(
                          Icons.music_note,
                          color: Color(0xFF71717A),
                          size: 48,
                        ),
                      ),
                    ),
                    errorWidget: (context, url, error) => Container(
                      color: const Color(0xFF27272A),
                      child: const Center(
                        child: Icon(
                          Icons.music_note,
                          color: Color(0xFF71717A),
                          size: 48,
                        ),
                      ),
                    ),
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
                    filter: ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
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
                    curve: Curves
                        .easeOutBack, // Efecto de rebote sutil al aparecer
                    scale: isCenter ? 1.0 : 0.0, // Desaparece encogiéndose a 0
                    child: LiquidButton(
                      onTap: onPlay,
                      size: 40,
                      child: Center(
                        child: SvgPicture.network(
                          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/2cf193a01b09bea18d56d06a3078f595dcc3ef00/play.svg',
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
            leading: SvgPicture.network(
              svgUrl,
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
                  child: SvgPicture.network(
                    'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/2cf193a01b09bea18d56d06a3078f595dcc3ef00/Vector.svg',
                    width: 20,
                    height: 20,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Mi Perfil',
                  style: GoogleFonts.stylish(
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
                    style: GoogleFonts.stylish(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    email,
                    style: GoogleFonts.merienda(
                      color: Color(0xFF9A9A9A),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            _buildMenuItem(
              style: GoogleFonts.happyMonkey(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
              svgUrl:
                  'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/824002cc67cdd367304e6b2d1603fda0300515e9/favoritos.svg',
              title: 'Mis favoritos',
              onTap: () {
                final appShell = context
                    .findAncestorStateOfType<_AppShellState>();
                appShell?.navigate(AppScreen.favorites);
              },
            ),
            _buildMenuItem(
              style: GoogleFonts.happyMonkey(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
              svgUrl:
                  'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/824002cc67cdd367304e6b2d1603fda0300515e9/descargas.svg',
              title: 'Descargas',
              onTap: () {
                final appShell = context
                    .findAncestorStateOfType<_AppShellState>();
                appShell?.navigate(AppScreen.downloads);
              },
            ),
            _buildMenuItem(
              style: GoogleFonts.happyMonkey(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
              svgUrl:
                  'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/824002cc67cdd367304e6b2d1603fda0300515e9/playlist.svg',
              title: 'Mis Playlists',
              onTap: _showComingSoon,
            ),
            _buildMenuItem(
              style: GoogleFonts.happyMonkey(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
              svgUrl:
                  'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/824002cc67cdd367304e6b2d1603fda0300515e9/recientes.svg',
              title: 'Recientes',
              onTap: _showComingSoon,
            ),
            _buildMenuItem(
              style: GoogleFonts.happyMonkey(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
              svgUrl:
                  'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/e235276200febd7a3360e3bbe75ae9c99815a98c/salir.svg',
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
  final String _shuffleIconUrl =
      'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/70ec49269263a1979fe152211e3dedfeb7474616/aleatorio.svg';
  final String _repeatAllIconUrl =
      'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/70ec49269263a1979fe152211e3dedfeb7474616/Repetir.svg';
  final String _repeatOneIconUrl =
      'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/70ec49269263a1979fe152211e3dedfeb7474616/Repetir1.svg';

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
  }

  @override
  void initState() {
    super.initState();
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
    _loadAndPlay(widget.songs[_idx]);
    _processingStateSubscription = audioPlayerService
        .player
        .processingStateStream
        .listen((state) {
          if (state == ProcessingState.completed) _onSongFinished();
        });
  }

  @override
  void didUpdateWidget(NowPlayingScreen old) {
    super.didUpdateWidget(old);
    if (widget.isPlaying != old.isPlaying) {
      _isPlayingInternal = widget.isPlaying;
      if (widget.isPlaying) {
        audioPlayerService.play();
      } else {
        audioPlayerService.pause();
      }
    }
    if (widget.initialIndex != old.initialIndex) {
      _idx = widget.initialIndex.clamp(0, widget.songs.length - 1);
      _pc.jumpToPage(_idx);
      _loadSong(_activeSong.audioPath);
      if (widget.isPlaying) audioPlayerService.play();
    }
  }

  @override
  void dispose() {
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
              leading: SvgPicture.network(
                'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/824002cc67cdd367304e6b2d1603fda0300515e9/descargas.svg',
                width: 24,
                height: 24,
                colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
              ),
              title: Text(
                'Descargar Local',
                style: GoogleFonts.merienda(
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
              leading: SvgPicture.network(
                'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/d8053fff26b12faffa776cf871c92acaebd8a7ca/archivo.svg',
                width: 24,
                height: 24,
                colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
              ),
              title: Text(
                'En tu dispositivo',
                style: GoogleFonts.merienda(
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

  Future<void> _downloadCurrentSong() async {
    final song = _activeSong; // la canción actual
    try {
      final localPath = await downloadSong(song);
      await DownloadManager.addDownloadedPath(localPath);
      // Opcional: guardar metadatos (título, artista, imagen) en un mapa aparte
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Canción descargada correctamente')),
      );
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error al descargar: $e')));
    }
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
                      child: SvgPicture.network(
                        'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/2cf193a01b09bea18d56d06a3078f595dcc3ef00/Vector.svg',
                        fit: BoxFit.contain,
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
                      child: SvgPicture.network(
                        'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/824002cc67cdd367304e6b2d1603fda0300515e9/descargas.svg',
                        fit: BoxFit.contain,
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
                    child: CachedNetworkImage(
                      imageUrl: widget.songs[i].img,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(
                        color: const Color(0xFF27272A),
                        child: const Icon(
                          Icons.music_note,
                          color: Color(0xFF71717A),
                          size: 64,
                        ),
                      ),
                      errorWidget: (context, url, error) => Container(
                        color: const Color(0xFF27272A),
                        child: const Icon(
                          Icons.music_note,
                          color: Color(0xFF71717A),
                          size: 64,
                        ),
                      ),
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
                            (_duration != null && _duration!.inMilliseconds > 0)
                            ? _position.inMilliseconds /
                                  _duration!.inMilliseconds
                            : 0.0;
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
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: WaveProgressPainter(
                                      progress: progress,
                                      glowIntensity: 0.0,
                                    ),
                                  ),
                                ),
                              ],
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
                            child: SvgPicture.network(
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
                            child: SvgPicture.network(
                              'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/05aafb194afaa258e1e1f13ced7dc76f5f5db11d/back.svg',
                              width: sideIconSize,
                              height: sideIconSize,
                            ),
                          ),
                          const SizedBox(width: 14),
                          ScaleBtn(
                            onTap: () {
                              if (widget.isPlaying) {
                                audioPlayerService.pause();
                                widget.onTogglePlay();
                              } else {
                                audioPlayerService.play();
                                widget.onTogglePlay();
                              }
                              setState(() {});
                            },
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
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 250),
                                  child: SvgPicture.network(
                                    widget.isPlaying
                                        ? 'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/05aafb194afaa258e1e1f13ced7dc76f5f5db11d/Pause1.svg'
                                        : 'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/05aafb194afaa258e1e1f13ced7dc76f5f5db11d/Play1.svg',
                                    key: ValueKey(widget.isPlaying),
                                    width: 34,
                                    height: 34,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          ScaleBtn(
                            onTap: widget.onNextSong,
                            child: SvgPicture.network(
                              'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/05aafb194afaa258e1e1f13ced7dc76f5f5db11d/Next.svg',
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
                            child: SvgPicture.network(
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
    );
  }
}

class WaveProgressPainter extends CustomPainter {
  final double progress;
  final double glowIntensity;

  const WaveProgressPainter({required this.progress, this.glowIntensity = 0.0});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final baseY = h * 0.90;
    final peakY = h * 0.06;
    final bgPaint = Paint()
      ..color = const Color(0xFF27272A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(0, baseY)
      ..cubicTo(w * 0.22, peakY, w * 0.78, peakY, w, baseY);
    canvas.drawPath(path, bgPaint);
    if (progress <= 0) return;

    final metrics = path.computeMetrics().first;
    final playedLength = metrics.length * progress.clamp(0.0, 1.0);
    final partial = metrics.extractPath(0, playedLength);

    final tangent = metrics.getTangentForOffset(playedLength);
    final playedWidth = (tangent?.position.dx ?? (w * progress))
        .clamp(1.0, w)
        .toDouble();

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
      ).createShader(Rect.fromLTWH(0, 0, playedWidth, h))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.3
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(partial, fgPaint);

    if (tangent != null) {
      // Círculo de brillo pulsante
      final glowRadius = 12.0 + glowIntensity * 8;
      canvas.drawCircle(
        tangent.position,
        glowRadius,
        Paint()
          ..shader =
              RadialGradient(
                colors: [
                  Colors.white.withOpacity(0.3 * glowIntensity),
                  Colors.white.withOpacity(0.1 * glowIntensity),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.5, 1.0],
              ).createShader(
                Rect.fromCircle(center: tangent.position, radius: glowRadius),
              ),
      );
      // Círculo blanco central
      canvas.drawCircle(tangent.position, 4.5, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(WaveProgressPainter old) =>
      old.progress != progress || old.glowIntensity != glowIntensity;
}

class SongListCard extends StatelessWidget {
  final String imageUrl;
  final String songTitle;
  final String artistLabel;
  final String albumName;
  final bool isFavorite;

  const SongListCard({
    super.key,
    required this.imageUrl,
    required this.songTitle,
    required this.artistLabel,
    required this.albumName,
    required this.isFavorite,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF131313),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Image.asset(
              imageUrl,
              width: 72,
              height: 72,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Container(
                width: 72,
                height: 72,
                color: const Color(0xFF27272A),
                child: const Icon(
                  Icons.music_note,
                  color: Color(0xFF71717A),
                  size: 28,
                ),
              ),
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
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 6),
                Text(
                  albumName,
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
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
    );
  }
}

// ==================== BÚSQUEDA ====================
class SearchScreen extends StatefulWidget {
  final VoidCallback onBack;
  final Function(Song) onPlay;
  const SearchScreen({super.key, required this.onBack, required this.onPlay});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();
  List<Song> _results = [];
  bool _hasSearch = false;
  void _search(String term) {
    final t = term.toLowerCase().trim();
    setState(() {
      _hasSearch = t.isNotEmpty;
      _results = t.isEmpty
          ? []
          : database
                .where(
                  (s) =>
                      s.title.toLowerCase().contains(t) ||
                      s.artist.toLowerCase().contains(t),
                )
                .toList();
    });
  }

  void _showDownloadOptions() {
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
                        child: SvgPicture.network(
                          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/2cf193a01b09bea18d56d06a3078f595dcc3ef00/Vector.svg',
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
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                hintText: 'Buscar canciones...',
                                hintStyle: TextStyle(color: Colors.white54),
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
                  ? (_results.isEmpty
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
                                onTap: () => widget.onPlay(s),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: Image.asset(
                                          s.img,
                                          width: 56,
                                          height: 56,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, _, _) => Container(
                                            width: 56,
                                            height: 56,
                                            color: const Color(0xFF27272A),
                                            child: const Icon(
                                              Icons.music_note,
                                              color: Color(0xFF71717A),
                                            ),
                                          ),
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
                          ))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Búsquedas Recientes',
                              style: GoogleFonts.happyMonkey(
                                color: const Color(0xFFE5E5E5),
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              'Limpiar',
                              style: GoogleFonts.merienda(
                                color: const Color(0xFF71717A),
                                fontSize: 12,
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
                            child: SvgPicture.network(
                              'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/2cf193a01b09bea18d56d06a3078f595dcc3ef00/Vector.svg',
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
                      style: GoogleFonts.stylish(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Text(
                  'Leídas',
                  style: GoogleFonts.merienda(
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
                        style: GoogleFonts.stylish(
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
                      child: SvgPicture.network(
                        'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/2cf193a01b09bea18d56d06a3078f595dcc3ef00/Vector.svg',
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
    'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/2cf193a01b09bea18d56d06a3078f595dcc3ef00/2-homeB11.svg',
    'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/2cf193a01b09bea18d56d06a3078f595dcc3ef00/42-exploreB.svg',
    'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/2cf193a01b09bea18d56d06a3078f595dcc3ef00/30-playB.svg',
    'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/2cf193a01b09bea18d56d06a3078f595dcc3ef00/11-profileB.svg',
  ];
  static const _iconsInactive = [
    'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/2cf193a01b09bea18d56d06a3078f595dcc3ef00/2-home-11.svg',
    'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/2cf193a01b09bea18d56d06a3078f595dcc3ef00/42-explore.svg',
    'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/2cf193a01b09bea18d56d06a3078f595dcc3ef00/30-play.svg',
    'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/2cf193a01b09bea18d56d06a3078f595dcc3ef00/11-profile.svg',
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
                        child: SvgPicture.network(
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
                        filter: ImageFilter.blur(sigmaX: 8.0, sigmaY: 8.0),
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
                filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
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
                    style: GoogleFonts.poppins(
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

// ==================== INDICADOR DE CARGA PERSONALIZADO ====================
class MusicLoader extends StatelessWidget {
  final double size;
  const MusicLoader({super.key, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: size,
        height: size,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 1200),
          builder: (context, angle, child) {
            return Transform.rotate(
              angle: angle * 2 * 3.14159,
              child: SvgPicture.network(
                'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/8a31554a9c39345f69211b97cdfcbffb9c360e26/logi2.svg',
                width: size,
                height: size,
              ),
            );
          },
        ),
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
  const DownloadsScreen({
    super.key,
    required this.onBack,
    this.showDeviceFiles = false,
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
        // Cargar archivos del dispositivo (por ahora usamos una lista vacía)
        // TODO: Implementar getDeviceSongs() si es necesario
        setState(() => _songs = []);
      } else {
        // Cargar canciones descargadas localmente
        final downloadedPaths = await DownloadManager.getDownloadedPaths();
        setState(
          () => _songs = downloadedPaths
              .map(
                (path) => Song(
                  audioPath: path,
                  title: path.split('/').last,
                  artist: 'Descargado',
                  img: '',
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
                    child: SvgPicture.network(
                      'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/2cf193a01b09bea18d56d06a3078f595dcc3ef00/Vector.svg',
                      width: 20,
                      height: 20,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    title,
                    style: GoogleFonts.stylish(
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
                      return _DownloadCard(song: song);
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
class FavoritesScreen extends StatelessWidget {
  final VoidCallback onBack;
  final Function(Song) onPlaySong;
  const FavoritesScreen({
    super.key,
    required this.onBack,
    required this.onPlaySong,
  });

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
              Row(
                children: [
                  GestureDetector(
                    onTap: onBack,
                    child: RepaintBoundary(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: SvgPicture.network(
                          'https://raw.githubusercontent.com/Darlyn1432546/Darlyn-G/2cf193a01b09bea18d56d06a3078f595dcc3ef00/Vector.svg',
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
              Expanded(
                child: ValueListenableBuilder<Set<String>>(
                  valueListenable: favoriteNotifier,
                  builder: (context, favorites, _) {
                    final favoriteSongs = database
                        .where((song) => favorites.contains(song.audioPath))
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
                    return ListView.builder(
                      itemCount: favoriteSongs.length,
                      itemBuilder: (context, index) {
                        final song = favoriteSongs[index];
                        return GestureDetector(
                          onTap: () => onPlaySong(song),
                          child: SongListCard(
                            imageUrl: song.img,
                            songTitle: song.title,
                            artistLabel: song.artist,
                            albumName: 'Álbum',
                            isFavorite: true,
                          ),
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
