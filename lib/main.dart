import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:flutter_ffmpeg/flutter_ffmpeg.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';

// ===== Services =====

class SecureAESService {
  static const _storage = FlutterSecureStorage();
  static const _keyName = 'master_aes_key';

  Future<enc.Key> _getOrCreateKey() async {
    String? existing = await _storage.read(key: _keyName);
    if (existing != null && existing.isNotEmpty) {
      return enc.Key.fromBase64(existing);
    }
    final key = enc.Key.fromSecureRandom(32);
    await _storage.write(key: _keyName, value: key.base64);
    return key;
  }

  Future<String> encrypt(String plain) async {
    final key = await _getOrCreateKey();
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    final encrypted = encrypter.encrypt(plain, iv: iv);
    return '${iv.base64}:${encrypted.base64}';
  }

  Future<String> decrypt(String cipherText) async {
    final key = await _getOrCreateKey();
    final parts = cipherText.split(':');
    final iv = enc.IV.fromBase64(parts[0]);
    final encrypted = enc.Encrypted.fromBase64(parts[1]);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    return encrypter.decrypt(encrypted, iv: iv);
  }
}

class DatabaseService {
  static final DatabaseService instance = DatabaseService._init();
  static Database? _db;
  DatabaseService._init();
  Future<Database> get db async => _db ??= await _initDB('factory_pro.db');

  Future<Database> _initDB(String fileName) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, fileName);
    return openDatabase(path, version: 1, onCreate: _createDB);
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''CREATE TABLE projects (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, idea_text TEXT, status TEXT DEFAULT 'draft', created_at INTEGER, updated_at INTEGER)''');
    await db.execute('''CREATE TABLE scripts (id INTEGER PRIMARY KEY AUTOINCREMENT, project_id INTEGER, hook TEXT, body TEXT, cta TEXT, chapters TEXT, keywords TEXT, hashtags TEXT, description TEXT, created_at INTEGER)''');
    await db.execute('''CREATE TABLE media_library (id INTEGER PRIMARY KEY AUTOINCREMENT, project_id INTEGER, type TEXT, file_path TEXT, source_url TEXT, created_at INTEGER)''');
    await db.execute('''CREATE TABLE api_keys (id INTEGER PRIMARY KEY AUTOINCREMENT, provider_name TEXT NOT NULL UNIQUE, encrypted_key_blob TEXT NOT NULL, iv TEXT, is_enabled INTEGER DEFAULT 1)''');
    await db.execute('''CREATE TABLE analytics_local (id INTEGER PRIMARY KEY AUTOINCREMENT, project_id INTEGER, event_type TEXT, provider TEXT, tokens_used INTEGER, timestamp INTEGER)''');
    await db.execute('''CREATE TABLE seo_data (id INTEGER PRIMARY KEY AUTOINCREMENT, project_id INTEGER, title TEXT, description TEXT, keywords TEXT, hashtags TEXT, chapters TEXT, seo_score INTEGER, created_at INTEGER)''');
  }
}

// ===== AI Router & Engines =====

class GeminiProvider {
  final String apiKey;
  GeminiProvider(this.apiKey);

  Future<String> generateText(String prompt) async {
    final url = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$apiKey');
    final body = {"contents": [{"parts": [{"text": prompt}]}]};
    final res = await http.post(url, headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      return data['candidates'][0]['content']['parts'][0]['text'];
    }
    throw Exception('Gemini Error: ${res.statusCode}');
  }
}

class AIRouter {
  final secure = SecureAESService();

  Future<String> getGeminiKey() async {
    final db = await DatabaseService.instance.db;
    final rows = await db.query('api_keys', where: 'provider_name = ?', whereArgs: ['Gemini']);
    if (rows.isEmpty) throw Exception('أضف مفتاح Gemini أولاً من API Manager');
    return secure.decrypt(rows.first['encrypted_key_blob'] as String);
  }

  Future<String> text(String prompt) async {
    final key = await getGeminiKey();
    return GeminiProvider(key).generateText(prompt);
  }

  Future<String> image(String prompt) async {
    return 'https://image.pollinations.ai/prompt/${Uri.encodeComponent(prompt)}?width=1024&height=1024&nologo=true';
  }
}

class ScriptGenerator {
  final AIRouter router;
  ScriptGenerator(this.router);

  Future<String> generate(String idea) async {
    final prompt = '''
أنت كاتب سيناريو يوتيوب محترف. الفكرة: "$idea"
أعطني JSON صالح:
{
  "hook": "افتتاحية قوية",
  "body": "النص الكامل في فقرات",
  "cta": "اطلب الاشتراك",
  "chapters": [{"title":"عنوان","time":"00:00"}],
  "keywords":"كلمات",
  "hashtags":"#هاشتاج",
  "description":"وصف"
}
اكتب JSON فقط.
''';
    return router.text(prompt);
  }
}

class VideoRenderer {
  final FlutterFFmpeg _ffmpeg = FlutterFFmpeg();

  Future<String> render({
    required List<String> images,
    String? voice,
    required String sub,
    required int projectId,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final out = p.join(dir.path, 'video_$projectId.mp4');
    final n = images.length;
    final inputs = StringBuffer();
    for (int i = 0; i < n; i++) {
      inputs.write('-loop 1 -t 5 -i "${images[i]}" ');
    }
    final audio = (voice != null && voice.isNotEmpty) ? '-i "$voice" ' : '';
    final mapAudio = (voice != null && voice.isNotEmpty) ? '-map $n:a ' : '';
    final filter = List.generate(n, (i) => '[${i}:v]').join('') + ' concat=n=$n:v=1:a=0[outv]';
    final cmd = '-y $inputs$audio -filter_complex "$filter" -map "[outv]" $mapAudio -c:v libx264 -preset ultrafast -crf 23 -pix_fmt yuv420p "$out"';
    final rc = await _ffmpeg.execute(cmd);
    if (rc != 0) throw Exception('FFmpeg failed: $rc');
    return out;
  }
}

// ===== Screens =====

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('تسجيل الدخول')),
    body: Center(child: ElevatedButton(onPressed: () => context.go('/'), child: const Text('دخول'))),
  );
}

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('لوحة التحكم'), actions: [
        IconButton(onPressed: () => context.go('/api'), icon: const Icon(Icons.api)),
        IconButton(onPressed: () => context.go('/settings'), icon: const Icon(Icons.settings)),
      ]),
      body: FutureBuilder(
        future: DatabaseService.instance.db.then((db) => db.query('projects', orderBy: 'created_at DESC')),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final projects = snapshot.data ?? [];
          if (projects.isEmpty) return const Center(child: Text('لا توجد مشاريع بعد'));
          return ListView.builder(
            itemCount: projects.length,
            itemBuilder: (_, i) => Card(
              child: ListTile(
                leading: const Icon(Icons.video_library, color: Colors.purple),
                title: Text(projects[i]['title'].toString()),
                subtitle: Text('الحالة: ${projects[i]['status']}'),
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/new'),
        icon: const Icon(Icons.add),
        label: const Text('مشروع جديد'),
      ),
    );
  }
}

class NewProjectScreen extends ConsumerStatefulWidget {
  const NewProjectScreen({super.key});
  @override
  ConsumerState<NewProjectScreen> createState() => _NewProjectScreenState();
}

class _NewProjectScreenState extends ConsumerState<NewProjectScreen> {
  final _idea = TextEditingController();
  bool _busy = false;
  String _log = '';

  Future<void> _run() async {
    final idea = _idea.text.trim();
    if (idea.isEmpty) return setState(() => _log = 'اكتب فكرة أولاً');
    setState(() { _busy = true; _log = 'جاري العمل...'; });

    try {
      final db = await DatabaseService.instance.db;
      final pid = await db.insert('projects', {
        'title': idea.length > 20 ? idea.substring(0, 17) + '...' : idea,
        'idea_text': idea,
        'status': 'processing',
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      setState(() => _log = 'توليد السكريبت...');
      final router = AIRouter();
      final scriptGen = ScriptGenerator(router);
      final rawScript = await scriptGen.generate(idea);
      final scriptMap = jsonDecode(rawScript.replaceAll('```json', '').replaceAll('```', '')) as Map<String, dynamic>;
      await db.insert('scripts', {
        'project_id': pid,
        'hook': scriptMap['hook'],
        'body': scriptMap['body'],
        'cta': scriptMap['cta'],
        'chapters': jsonEncode(scriptMap['chapters']),
        'keywords': scriptMap['keywords'],
        'hashtags': scriptMap['hashtags'],
        'description': scriptMap['description'],
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });

      setState(() => _log = 'توليد الصور...');
      final bodyText = scriptMap['body'].toString();
      final paragraphs = bodyText.split('\n').where((e) => e.trim().isNotEmpty).toList();
      final imagePaths = <String>[];
      final dir = await getApplicationDocumentsDirectory();
      for (int i = 0; i < paragraphs.length; i++) {
        final imgUrl = await router.image(paragraphs[i]);
        final imgRes = await http.get(Uri.parse(imgUrl));
        final imgPath = p.join(dir.path, 'scene_$i.png');
        await File(imgPath).writeAsBytes(imgRes.bodyBytes);
        imagePaths.add(imgPath);
        await db.insert('media_library', {
          'project_id': pid, 'type': 'image', 'file_path': imgPath,
          'source_url': imgUrl, 'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      setState(() => _log = 'تجميع الفيديو...');
      final videoPath = await VideoRenderer().render(
        images: imagePaths,
        sub: '',
        projectId: pid,
      );

      await db.update('projects', {'status': 'completed'}, where: 'id=?', whereArgs: [pid]);
      setState(() { _busy = false; _log = 'تم الفيديو: $videoPath'; });
    } catch (e) {
      setState(() { _busy = false; _log = 'خطأ: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('مشروع جديد')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        TextField(controller: _idea, maxLines: 3, decoration: const InputDecoration(labelText: 'فكرة الفيديو', border: OutlineInputBorder())),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: _busy ? null : _run,
          icon: const Icon(Icons.auto_awesome),
          label: Text(_busy ? 'جاري...' : 'ابدأ'),
        ),
        const SizedBox(height: 20),
        Expanded(child: SingleChildScrollView(child: Align(alignment: Alignment.centerRight, child: Text(_log)))),
      ]),
    ),
  );
}

class ApiManagerScreen extends ConsumerStatefulWidget {
  const ApiManagerScreen({super.key});
  @override
  ConsumerState<ApiManagerScreen> createState() => _ApiManagerScreenState();
}

class _ApiManagerScreenState extends ConsumerState<ApiManagerScreen> {
  final _key = TextEditingController();
  final _secure = SecureAESService();
  String _provider = 'Gemini';

  Future<void> _save() async {
    if (_key.text.trim().isEmpty) return;
    final encrypted = await _secure.encrypt(_key.text.trim());
    final db = await DatabaseService.instance.db;
    await db.insert('api_keys', {'provider_name': _provider, 'encrypted_key_blob': encrypted, 'is_enabled': 1},
        conflictAlgorithm: ConflictAlgorithm.replace);
    setState(() {});
    _key.clear();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('API Manager')),
    body: FutureBuilder(
      future: DatabaseService.instance.db.then((db) => db.query('api_keys')),
      builder: (context, snap) {
        final keys = snap.data ?? [];
        return ListView(children: [
          Padding(padding: const EdgeInsets.all(16), child: Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(children: [
            DropdownButton<String>(value: _provider, items: const [DropdownMenuItem(value: 'Gemini', child: Text('Gemini')), DropdownMenuItem(value: 'ElevenLabs', child: Text('ElevenLabs'))], onChanged: (v) => setState(() => _provider = v!)),
            TextField(controller: _key, obscureText: true, decoration: const InputDecoration(labelText: 'API Key')),
            ElevatedButton(onPressed: _save, child: const Text('حفظ مشفر')),
          ])))),
          ...keys.map((k) => ListTile(leading: const Icon(Icons.vpn_key), title: Text(k['provider_name'].toString()), subtitle: const Text('مشفر'),
            trailing: IconButton(icon: const Icon(Icons.delete), onPressed: () async { final db = await DatabaseService.instance.db; await db.delete('api_keys', where: 'id=?', whereArgs: [k['id']]); setState(() {}); }))),
        ]);
      },
    ),
  );
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('الإعدادات')),
    body: ListView(children: [
      ListTile(leading: const Icon(Icons.delete_forever), title: const Text('مسح البيانات'), onTap: () async {
        final db = await DatabaseService.instance.db;
        await db.delete('projects'); await db.delete('scripts'); await db.delete('media_library');
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم المسح')));
      }),
      const AboutListTile(icon: Icon(Icons.info), applicationName: 'AI YouTube Factory Pro', applicationVersion: '1.0.0'),
    ]),
  );
}

// ===== App =====

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: App()));
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'AI YouTube Factory Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple), brightness: Brightness.dark),
      locale: const Locale('ar', 'EG'),
      supportedLocales: const [Locale('ar', 'EG'), Locale('en', 'US')],
      localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
      routerConfig: GoRouter(initialLocation: '/login', routes: [
        GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
        GoRoute(path: '/', builder: (_, __) => const DashboardScreen()),
        GoRoute(path: '/new', builder: (_, __) => const NewProjectScreen()),
        GoRoute(path: '/api', builder: (_, __) => const ApiManagerScreen()),
        GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
      ]),
    );
  }
}
