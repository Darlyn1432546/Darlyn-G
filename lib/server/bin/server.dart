import 'dart:async'; // ✅ Necesario para StreamController
import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:dart_ytmusic_api/yt_music.dart';
import 'package:dotenv/dotenv.dart';
import 'package:http/http.dart' as http;

void main() async {
  final env = DotEnv(includePlatformEnvironment: true)..load(['.env']);
  final cookie = env['YOUTUBE_COOKIE'] ?? '';
  if (cookie.isEmpty) {
    print('⚠️ YOUTUBE_COOKIE no configurada en .env');
    exit(1);
  }

  final ytMusic = YTMusic();
  await ytMusic.initialize(cookies: cookie);
  print('✅ YouTube Music inicializado en el servidor');

  // Rutas adaptables según el sistema operativo (Windows o Linux/Docker)
  final ytDlpPath = Platform.isWindows ? r'C:\tools\yt-dlp.exe' : 'yt-dlp';
  final cookiesPath = Platform.isWindows ? r'C:\tools\cookies.txt' : 'cookies.txt';
final app = Router();

app.get('/health', (Request req) {
    return Response.ok('OK', headers: {'Content-Type': 'text/plain'});
  });

  // (Aquí mantienes todas tus rutas de la API igual: /search, /trending, /audio, /stream, /download, /liked)
  app.get('/search', (Request req) async {
    final query = req.url.queryParameters['q'] ?? '';
    if (query.isEmpty) {
      return Response.badRequest(body: 'Missing query parameter q');
    }
    try {
      final results = await ytMusic.searchSongs(query);
      final songs = results
          .map((song) => {
                'id': song.videoId,
                'title': song.name,
                'artist': song.artist.name,
                'thumbnail':
                    'https://img.youtube.com/vi/${song.videoId}/hqdefault.jpg',
              })
          .toList();
      return Response.ok(
        jsonEncode({'songs': songs}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(body: 'Error: $e');
    }
  });

  app.get('/trending', (Request req) async {
    try {
      final results = await ytMusic.searchSongs('trending music');
      final songs = results
          .map((song) => {
                'id': song.videoId,
                'title': song.name,
                'artist': song.artist.name,
                'thumbnail':
                    'https://img.youtube.com/vi/${song.videoId}/hqdefault.jpg',
              })
          .toList();
      return Response.ok(
        jsonEncode({'songs': songs}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(body: 'Error: $e');
    }
  });

  app.get('/audio', (Request req) async {
    final id = req.url.queryParameters['id'] ?? '';
    if (id.isEmpty) {
      return Response.badRequest(body: 'Missing id parameter');
    }
    try {
      final result = await Process.run(
        ytDlpPath,
        [
          '-f', 'bestaudio',
          '--get-url',
          '--cookies', cookiesPath,
          '--js-runtimes', 'node',
          '--remote-components', 'ejs:github',
          '--no-check-certificate',
          'https://www.youtube.com/watch?v=$id',
        ],
        runInShell: true,
      );
      if (result.exitCode != 0) {
        print('❌ yt-dlp error: ${result.stderr}');
        return Response.internalServerError(body: 'Error obteniendo URL');
      }
      final audioUrl = (result.stdout as String).trim();
      print('🎵 URL directa obtenida: $audioUrl');
      return Response.ok(
        jsonEncode({'url': audioUrl}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      print('❌ Error en /audio: $e');
      return Response.internalServerError(body: 'Error: $e');
    }
  });

  app.get('/stream', (Request req) async {
    final id = req.url.queryParameters['id'] ?? '';
    if (id.isEmpty) {
      return Response.badRequest(body: 'Missing id parameter');
    }

    try {
      final result = await Process.run(
        ytDlpPath,
        [
          '-f', 'bestaudio',
          '--get-url',
          '--cookies', cookiesPath,
          '--remote-components', 'ejs:github',
          '--no-check-certificate',
          'https://www.youtube.com/watch?v=$id',
        ],
        runInShell: true,
      );

      if (result.exitCode != 0) {
        print('❌ yt-dlp error: ${result.stderr}');
        return Response.internalServerError(body: 'Error obteniendo URL');
      }

      final audioUrl = (result.stdout as String).trim();
      print('🎵 Proxy: URL obtenida para $id');

      final client = http.Client();
      final requestToYoutube = http.Request('GET', Uri.parse(audioUrl));
      final rangeHeader = req.headers['range'];
      if (rangeHeader != null) {
        requestToYoutube.headers['range'] = rangeHeader;
      }
      requestToYoutube.headers['user-agent'] =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36';

      final responseFromYoutube = await client.send(requestToYoutube);

      final controller = StreamController<List<int>>();
      responseFromYoutube.stream.listen(
        (data) => controller.add(data),
        onError: (error) {
          controller.addError(error);
          client.close();
        },
        onDone: () {
          controller.close();
          client.close();
        },
      );

      final responseHeaders = {
        'Content-Type':
            responseFromYoutube.headers['content-type'] ?? 'audio/webm',
        'Content-Length':
            responseFromYoutube.headers['content-length'] ?? '0',
        'Content-Range': responseFromYoutube.headers['content-range'] ?? '',
        'Accept-Ranges': 'bytes',
        'Access-Control-Allow-Origin': '*',
      };

      return Response(
        responseFromYoutube.statusCode,
        body: controller.stream,
        headers: responseHeaders,
      );
    } catch (e) {
      print('❌ Error en /stream para ID $id: $e');
      return Response.internalServerError(body: 'Error: $e');
    }
  });

  app.get('/download', (Request req) async {
    final id = req.url.queryParameters['id'] ?? '';
    if (id.isEmpty) {
      return Response.badRequest(body: 'Missing id parameter');
    }

    try {
      final downloadsDir = Directory('downloads');
      if (!await downloadsDir.exists()) {
        await downloadsDir.create();
      }

      final outputPath = 'downloads/$id.mp3';

      final result = await Process.run(
        ytDlpPath,
        [
          '-x',
          '--audio-format',
          'mp3',
          '--audio-quality',
          '0',
          '--output',
          outputPath,
          '--cookies',
          cookiesPath,
          '--extractor-args',
          'youtube:player_client=android',
          'https://www.youtube.com/watch?v=$id',
        ],
        runInShell: true,
      );

      if (result.exitCode != 0) {
        print('❌ Error en descarga: ${result.stderr}');
        return Response.internalServerError(body: 'Error al descargar');
      }

      final file = File(outputPath);
      if (!await file.exists()) {
        return Response.internalServerError(body: 'Archivo no encontrado');
      }

      final bytes = await file.readAsBytes();

      return Response.ok(bytes, headers: {
        'Content-Type': 'audio/mpeg',
        'Content-Disposition': 'attachment; filename="$id.mp3"',
        'Access-Control-Allow-Origin': '*',
      });
    } catch (e) {
      print('❌ Error en /download: $e');
      return Response.internalServerError(body: 'Error: $e');
    }
  });

  app.get('/liked', (Request req) async {
    try {
      final liked = await ytMusic.searchSongs('liked songs');
      final songs = liked
          .map((song) => {
                'id': song.videoId,
                'title': song.name,
                'artist': song.artist.name,
                'thumbnail':
                    'https://img.youtube.com/vi/${song.videoId}/hqdefault.jpg',
              })
          .toList();
      return Response.ok(
        jsonEncode({'songs': songs}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(body: 'Error: $e');
    }
  });

  // Manejador dedicado exclusivamente para la raíz (intercepta GET y HEAD perfectamente)
app.get('/', (Request req) {
    return Response.ok('¡Servidor de Musichita activo y funcionando! 🎵');
  });

  // 👇 DEJA SOLO ESTO PARA EL HANDLER
  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsHeaders())
      .addHandler(app.call);

  final port = int.parse(Platform.environment['PORT'] ?? '8081');
  await io.serve(handler, '0.0.0.0', port);
  print('✅ Servidor proxy escuchando en http://0.0.0.0:$port');
}