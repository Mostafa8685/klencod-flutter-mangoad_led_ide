import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KlencodIdeApp());
}

class AppColors {
  static const Color darkBg = Color(0xFF0D1117);
  static const Color surface = Color(0xFF161B22);
  static const Color surfaceAlt = Color(0xFF21262D);
  static const Color border = Color(0xFF30363D);
  static const Color primary = Color(0xFF1F6FEB);
  static const Color primaryLight = Color(0xFF58A6FF);
  static const Color orange = Color(0xFFFF9800);
  static const Color success = Color(0xFF2EA043);
  static const Color danger = Color(0xFFCF222E);
  static const Color warning = Color(0xFFD29922);
  static const Color textPrimary = Color(0xFFE6EDF3);
  static const Color textMuted = Color(0xFF8B949E);
}

class KlencodIdeApp extends StatelessWidget {
  const KlencodIdeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mangoad Mobile IDE',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: AppColors.darkBg,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.primary,
          secondary: AppColors.orange,
          surface: AppColors.surface,
          error: AppColors.danger,
          onPrimary: Colors.white,
          onSurface: AppColors.textPrimary,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.surface,
          elevation: 0,
          titleTextStyle: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      home: const IdeWorkspaceScreen(),
    );
  }
}

/// ============================================================================
/// 1. محرر الأكواد مع تلوين الكود (Dart Syntax Highlighting Controller)
/// ============================================================================
class DartSyntaxTextEditingController extends TextEditingController {
  DartSyntaxTextEditingController({super.text});

  static final RegExp _tokenRegex = RegExp(
    r"(//.*$)|(/\*[\s\S]*?\*/)|('(?:\\.|[^'\\])*')|"
    r'("(?:\\.|[^"\\])*")'
    r"|(@[a-zA-Z_]\w*)"
    r"|\b(abstract|as|assert|async|await|break|case|catch|class|const|continue|covariant|default|deferred|do|dynamic|else|enum|export|extends|extension|external|factory|false|final|finally|for|Function|get|hide|if|implements|import|in|interface|is|late|library|mixin|new|null|on|operator|part|required|rethrow|return|sealed|set|show|static|super|switch|sync|this|throw|true|try|typedef|var|void|when|while|with|yield)\b"
    r"|\b(Widget|StatelessWidget|StatefulWidget|State|BuildContext|Scaffold|AppBar|Container|Column|Row|Text|Center|ListView|Padding|Expanded|SizedBox|IconButton|ElevatedButton|TextField|MaterialApp|ThemeData|Color|Colors|EdgeInsets|Future|Stream|List|Map|Set|String|int|double|bool|num|Object|Key)\b"
    r"|\b(\d+(?:\.\d+)?)\b",
    multiLine: true,
  );

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final baseStyle = style ??
        const TextStyle(
          fontFamily: 'monospace',
          fontSize: 14,
          height: 1.5,
          color: AppColors.textPrimary,
        );

    final source = text;
    if (source.isEmpty) {
      return TextSpan(style: baseStyle, text: '');
    }

    final children = <TextSpan>[];
    var lastIndex = 0;

    for (final match in _tokenRegex.allMatches(source)) {
      if (match.start > lastIndex) {
        children.add(TextSpan(text: source.substring(lastIndex, match.start)));
      }

      Color tokenColor = AppColors.textPrimary;
      FontWeight? weight;
      FontStyle? fontStyle;

      if (match.group(1) != null || match.group(2) != null) {
        tokenColor = AppColors.textMuted;
        fontStyle = FontStyle.italic;
      } else if (match.group(3) != null || match.group(4) != null) {
        tokenColor = const Color(0xFFA5D6FF); // نصوص Strings
      } else if (match.group(5) != null) {
        tokenColor = const Color(0xFFD2A8FF); // @annotations
      } else if (match.group(6) != null) {
        tokenColor = const Color(0xFFFF7B72); // كلمات مفتاحية Keywords
        weight = FontWeight.w600;
      } else if (match.group(7) != null) {
        tokenColor = const Color(0xFFFFA657); // ويدجتس وأنواع Types
      } else if (match.group(8) != null) {
        tokenColor = const Color(0xFF79C0FF); // أرقام Numbers
      }

      children.add(
        TextSpan(
          text: match.group(0),
          style: baseStyle.copyWith(
            color: tokenColor,
            fontWeight: weight,
            fontStyle: fontStyle,
          ),
        ),
      );
      lastIndex = match.end;
    }

    if (lastIndex < source.length) {
      children.add(TextSpan(text: source.substring(lastIndex)));
    }

    return TextSpan(style: baseStyle, children: children);
  }
}

/// ============================================================================
/// 2. نموذج شجرة الملفات (Virtual File Node)
/// ============================================================================
class IdeNode {
  String path;
  bool isFolder;
  String content;
  bool isDirty;

  IdeNode({
    required this.path,
    required this.isFolder,
    this.content = '',
    this.isDirty = false,
  });

  String get name => path.split('/').last;

  Map<String, dynamic> toJson() => {
        'path': path,
        'isFolder': isFolder,
        'content': content,
      };

  factory IdeNode.fromJson(Map<String, dynamic> json) => IdeNode(
        path: json['path'] as String,
        isFolder: json['isFolder'] as bool? ?? false,
        content: json['content'] as String? ?? '',
      );
}

/// ============================================================================
/// 3. خدمة الذكاء الاصطناعي (Gemini & OpenAI API Service)
/// ============================================================================
class AiAssistantService {
  static Future<String> generateOrEditCode({
    required String provider, // 'gemini' or 'openai'
    required String apiKey,
    required String model,
    required String prompt,
    required String currentFilePath,
    required String currentFileContent,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw Exception('يرجى إدخال مفتاح API أولاً في إعدادات المساعد الذكي.');
    }

    final systemInstruction =
        'أنت مساعد برمجي خبير في Flutter و Dart داخل بيئة تطوير للهواتف (Klencod IDE).\n'
        'المستخدم يعمل حالياً على الملف: $currentFilePath\n'
        'محتوى الملف الحالي:\n'
        '```dart\n$currentFileContent\n```\n'
        'عندما يطلب المستخدم تعديل الكود أو إنشاء كود جديد:\n'
        '1. اشرح التعديل باختصار شديد (سطر أو سطرين).\n'
        '2. ضع الكود الكامل الجاهز للاستبدال داخل بلوك ```dart ... ``` لكي يتمكن المستخدم من تطبيقه بضغطة زر واحدة.';

    if (provider == 'gemini') {
      final selectedModel = model.isEmpty ? 'gemini-2.5-flash' : model;
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$selectedModel:generateContent?key=${apiKey.trim()}',
      );
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'system_instruction': {
                'parts': [
                  {'text': systemInstruction}
                ]
              },
              'contents': [
                {
                  'role': 'user',
                  'parts': [
                    {'text': prompt}
                  ]
                }
              ],
              'generationConfig': {
                'temperature': 0.2,
              },
            }),
          )
          .timeout(const Duration(seconds: 45));

      if (response.statusCode >= 400) {
        throw Exception('خطأ من Gemini API (${response.statusCode}): ${response.body}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final candidates = data['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) {
        throw Exception('لم يرجع النموذج أي استجابة.');
      }
      final parts = (candidates.first['content'] as Map<String, dynamic>)['parts'] as List;
      return parts.map((p) => (p as Map<String, dynamic>)['text'] ?? '').join('\n');
    } else {
      final selectedModel = model.isEmpty ? 'gpt-4o-mini' : model;
      final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${apiKey.trim()}',
            },
            body: jsonEncode({
              'model': selectedModel,
              'temperature': 0.2,
              'messages': [
                {'role': 'system', 'content': systemInstruction},
                {'role': 'user', 'content': prompt},
              ],
            }),
          )
          .timeout(const Duration(seconds: 45));

      if (response.statusCode >= 400) {
        throw Exception('خطأ من OpenAI API (${response.statusCode}): ${response.body}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final choices = data['choices'] as List?;
      if (choices == null || choices.isEmpty) {
        throw Exception('لم يرجع النموذج أي استجابة.');
      }
      return ((choices.first as Map<String, dynamic>)['message'] as Map<String, dynamic>)['content']
              ?.toString() ??
          '';
    }
  }

  static String? extractCodeBlock(String responseText) {
    final regex = RegExp(r'```(?:dart|yaml|json|xml|gradle)?\s*\n([\s\S]*?)```');
    final match = regex.firstMatch(responseText);
    if (match != null) {
      return match.group(1)?.trimRight();
    }
    return null;
  }
}

/// ============================================================================
/// 4. خدمة البناء السحابي المباشر عبر GitHub API (GitHub Actions Cloud Build)
/// ============================================================================
class GithubDirectCloudBuildService {
  static const String defaultWorkflowYaml = '''name: Build Flutter APK

on:
  workflow_dispatch:
    inputs:
      flutter_version:
        description: 'Flutter version'
        required: true
        default: '3.47.2'

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Gradle Cache
        uses: actions/cache@v4
        with:
          path: |
            ~/.gradle/caches
            ~/.gradle/wrapper
          key: \${{ runner.os }}-gradle-\${{ hashFiles('**/*.gradle*', '**/gradle-wrapper.properties') }}
          restore-keys: |
            \${{ runner.os }}-gradle-

      - name: Setup Java 17
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'

      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          flutter-version: \${{ github.event.inputs.flutter_version }}
          cache: true
          channel: stable

      - name: Ensure Android platform exists
        run: |
          if [ ! -d "android" ]; then
            flutter create . --platforms=android
          fi

      - name: Get dependencies
        run: flutter pub get

      - name: Build APK
        run: flutter build apk --release

      - name: Upload APK
        uses: actions/upload-artifact@v4
        with:
          name: app-release
          path: build/app/outputs/flutter-apk/app-release.apk
          if-no-files-found: error
          retention-days: 7
''';

  static Future<String> pushProjectAndTriggerBuild({
    required String patToken,
    required String repoFullName,
    required String branch,
    required List<IdeNode> nodes,
    required String commitMessage,
  }) async {
    final cleanToken = patToken.trim();
    final cleanRepo = repoFullName.trim();
    final cleanBranch = branch.trim().isEmpty ? 'main' : branch.trim();

    if (cleanToken.isEmpty || !cleanRepo.contains('/')) {
      throw Exception('يرجى إدخال GitHub Token واسم المستودع بصيغة owner/repo.');
    }

    final headers = {
      'Authorization': 'Bearer $cleanToken',
      'Accept': 'application/vnd.github+json',
      'Content-Type': 'application/json',
      'X-GitHub-Api-Version': '2022-11-28',
    };

    // 1. جلب مرجع الفرع الحالي (Branch Ref)
    final refUri = Uri.parse('https://api.github.com/repos/$cleanRepo/git/ref/heads/$cleanBranch');
    final refRes = await http.get(refUri, headers: headers).timeout(const Duration(seconds: 25));
    if (refRes.statusCode >= 400) {
      throw Exception(
        'تعذر الوصول للفرع ($cleanBranch) في المستودع $cleanRepo (${refRes.statusCode}). تأكد من صحة التوكن واسم المستودع.',
      );
    }
    final refData = jsonDecode(refRes.body) as Map<String, dynamic>;
    final latestCommitSha = (refData['object'] as Map<String, dynamic>)['sha'] as String;

    // 2. جلب بيانات آخر Commit للحصول على base_tree
    final commitUri = Uri.parse('https://api.github.com/repos/$cleanRepo/git/commits/$latestCommitSha');
    final commitRes = await http.get(commitUri, headers: headers).timeout(const Duration(seconds: 25));
    if (commitRes.statusCode >= 400) {
      throw Exception('تعذر قراءة شجرة المستودع (${commitRes.statusCode}).');
    }
    final commitData = jsonDecode(commitRes.body) as Map<String, dynamic>;
    final baseTreeSha = (commitData['tree'] as Map<String, dynamic>)['sha'] as String;

    // 3. تجهيز قائمة الملفات للشجرة
    final files = nodes.where((n) => !n.isFolder).toList();
    final hasWorkflow = files.any((f) => f.path.startsWith('.github/workflows/'));
    final treeItems = <Map<String, dynamic>>[
      for (final file in files)
        {
          'path': file.path,
          'mode': '100644',
          'type': 'blob',
          'content': file.content,
        },
      if (!hasWorkflow)
        {
          'path': '.github/workflows/main.yml',
          'mode': '100644',
          'type': 'blob',
          'content': defaultWorkflowYaml,
        },
    ];

    // 4. إنشاء شجرة Git جديدة
    final treeUri = Uri.parse('https://api.github.com/repos/$cleanRepo/git/trees');
    final treeRes = await http
        .post(
          treeUri,
          headers: headers,
          body: jsonEncode({
            'base_tree': baseTreeSha,
            'tree': treeItems,
          }),
        )
        .timeout(const Duration(seconds: 35));
    if (treeRes.statusCode >= 400) {
      throw Exception('فشل رفع شجرة الملفات إلى GitHub (${treeRes.statusCode}): ${treeRes.body}');
    }
    final newTreeSha = (jsonDecode(treeRes.body) as Map<String, dynamic>)['sha'] as String;

    // 5. إنشاء Commit جديد
    final newCommitUri = Uri.parse('https://api.github.com/repos/$cleanRepo/git/commits');
    final newCommitRes = await http
        .post(
          newCommitUri,
          headers: headers,
          body: jsonEncode({
            'message': commitMessage,
            'tree': newTreeSha,
            'parents': [latestCommitSha],
          }),
        )
        .timeout(const Duration(seconds: 25));
    if (newCommitRes.statusCode >= 400) {
      throw Exception('فشل إنشاء Commit جديد (${newCommitRes.statusCode}).');
    }
    final newCommitSha = (jsonDecode(newCommitRes.body) as Map<String, dynamic>)['sha'] as String;

    // 6. تحديث مرجع الفرع (Update Branch Reference) -> تشغيل البناء تلقائياً
    final updateRefRes = await http
        .patch(
          refUri,
          headers: headers,
          body: jsonEncode({'sha': newCommitSha, 'force': false}),
        )
        .timeout(const Duration(seconds: 25));
    if (updateRefRes.statusCode >= 400) {
      throw Exception('فشل تحديث الفرع $cleanBranch (${updateRefRes.statusCode}).');
    }

    return 'https://github.com/$cleanRepo/actions';
  }
}

/// ============================================================================
/// 5. الشاشة الرئيسية لبيئة التطوير (IDE Workspace Screen)
/// ============================================================================
class IdeWorkspaceScreen extends StatefulWidget {
  const IdeWorkspaceScreen({super.key});

  @override
  State<IdeWorkspaceScreen> createState() => _IdeWorkspaceScreenState();
}

class _IdeWorkspaceScreenState extends State<IdeWorkspaceScreen> {
  static const String _prefsProjectKey = 'mangoad_ide_project_nodes_v2';
  static const String _prefsProjectNameKey = 'mangoad_ide_project_name_v2';

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  late final DartSyntaxTextEditingController _codeController;
  final ScrollController _editorScrollController = ScrollController();

  String _projectName = 'mangoad_led';
  List<IdeNode> _nodes = [];
  List<String> _openTabs = [];
  String? _activeFilePath;
  final Set<String> _expandedFolders = {'lib', '.github', '.github/workflows'};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _codeController = DartSyntaxTextEditingController();
    _codeController.addListener(_onCodeChanged);
    _loadWorkspace();
  }

  @override
  void dispose() {
    _codeController.removeListener(_onCodeChanged);
    _codeController.dispose();
    _editorScrollController.dispose();
    super.dispose();
  }

  void _onCodeChanged() {
    final activePath = _activeFilePath;
    if (activePath == null) return;
    final idx = _nodes.indexWhere((n) => !n.isFolder && n.path == activePath);
    if (idx == -1) return;
    if (_nodes[idx].content != _codeController.text) {
      setState(() {
        _nodes[idx].content = _codeController.text;
        _nodes[idx].isDirty = true;
      });
    }
  }

  Future<void> _loadWorkspace() async {
    final prefs = await SharedPreferences.getInstance();
    final savedName = prefs.getString(_prefsProjectNameKey);
    final savedRaw = prefs.getString(_prefsProjectKey);

    if (savedRaw != null && savedRaw.isNotEmpty) {
      try {
        final decoded = (jsonDecode(savedRaw) as List)
            .map((e) => IdeNode.fromJson(e as Map<String, dynamic>))
            .toList();
        if (decoded.isNotEmpty) {
          _nodes = decoded;
          _projectName = savedName ?? 'mangoad_led';
        }
      } catch (_) {
        _nodes = _createStarterProject();
      }
    } else {
      _nodes = _createStarterProject();
    }

    final firstDart = _nodes.where((n) => !n.isFolder && n.path.endsWith('.dart')).firstOrNull ??
        _nodes.where((n) => !n.isFolder).firstOrNull;

    if (firstDart != null) {
      _openTabs = [firstDart.path];
      _activeFilePath = firstDart.path;
      _codeController.text = firstDart.content;
    }

    if (mounted) {
      setState(() => _loading = false);
    }
  }

  List<IdeNode> _createStarterProject() {
    return [
      IdeNode(
        path: 'pubspec.yaml',
        isFolder: false,
        content: '''name: $_projectName
description: A Flutter project edited in Mobile IDE.
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: '>=3.0.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter

flutter:
  uses-material-design: true
''',
      ),
      IdeNode(path: 'lib', isFolder: true),
      IdeNode(
        path: 'lib/main.dart',
        isFolder: false,
        content: '''import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'تطبيقي الجديد',
      theme: ThemeData.dark(useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _counter = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تطبيقي من محرر Klencod')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('مرحباً بك! لقد قمت ببناء هذا التطبيق بنجاح:'),
            const SizedBox(height: 10),
            Text(
              '\$_counter',
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _counter++),
        child: const Icon(Icons.add),
      ),
    );
  }
}
''',
      ),
      IdeNode(path: '.github', isFolder: true),
      IdeNode(path: '.github/workflows', isFolder: true),
      IdeNode(
        path: '.github/workflows/main.yml',
        isFolder: false,
        content: GithubDirectCloudBuildService.defaultWorkflowYaml,
      ),
    ];
  }

  Future<void> _saveAllFiles({bool showToast = true}) async {
    final prefs = await SharedPreferences.getInstance();
    for (final node in _nodes) {
      node.isDirty = false;
    }
    await prefs.setString(_prefsProjectNameKey, _projectName);
    await prefs.setString(
      _prefsProjectKey,
      jsonEncode(_nodes.map((n) => n.toJson()).toList()),
    );
    if (mounted) {
      setState(() {});
      if (showToast) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تم حفظ جميع الملفات بنجاح ✓'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  void _selectFile(String path) {
    final node = _nodes.where((n) => !n.isFolder && n.path == path).firstOrNull;
    if (node == null) return;
    setState(() {
      if (!_openTabs.contains(path)) {
        _openTabs.add(path);
      }
      _activeFilePath = path;
      _codeController.value = TextEditingValue(
        text: node.content,
        selection: const TextSelection.collapsed(offset: 0),
      );
    });
  }

  void _closeTab(String path) {
    setState(() {
      _openTabs.remove(path);
      if (_activeFilePath == path) {
        _activeFilePath = _openTabs.isNotEmpty ? _openTabs.last : null;
        final nextNode = _nodes.where((n) => !n.isFolder && n.path == _activeFilePath).firstOrNull;
        _codeController.text = nextNode?.content ?? '';
      }
    });
  }

  void _insertSymbol(String symbol) {
    final value = _codeController.value;
    final start = value.selection.start >= 0 ? value.selection.start : value.text.length;
    final end = value.selection.end >= 0 ? value.selection.end : value.text.length;
    final newText = value.text.replaceRange(start, end, symbol);
    final cursorOffset = start + symbol.length;
    _codeController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: cursorOffset),
    );
  }

  Future<void> _importZipIntoIde() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    final filePath = res?.files.single.path;
    if (filePath == null) return;

    try {
      final bytes = await File(filePath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final importedNodes = <IdeNode>[];
      final seenFolders = <String>{};

      for (final entry in archive) {
        var relPath = entry.name.replaceAll('\\', '/');
        relPath = relPath.replaceAll(RegExp(r'^/+|/+$'), '');
        if (relPath.isEmpty || relPath.startsWith('.git/')) continue;

        final parts = relPath.split('/');
        var currentFolder = '';
        for (var i = 0; i < parts.length - 1; i++) {
          currentFolder = currentFolder.isEmpty ? parts[i] : '$currentFolder/${parts[i]}';
          if (seenFolders.add(currentFolder)) {
            importedNodes.add(IdeNode(path: currentFolder, isFolder: true));
          }
        }

        if (entry.isFile) {
          final ext = relPath.split('.').last.toLowerCase();
          const textExts = {
            'dart', 'yaml', 'yml', 'json', 'xml', 'gradle', 'kts',
            'properties', 'md', 'txt', 'html', 'css', 'js', 'java', 'kt', 'sh'
          };
          if (textExts.contains(ext) && entry.size < 1024 * 512) {
            final rawBytes = entry.content;
            final bytesList = rawBytes is List<int> ? rawBytes : <int>[];
            final content = utf8.decode(bytesList, allowMalformed: true);
            importedNodes.add(IdeNode(path: relPath, isFolder: false, content: content));
          }
        }
      }

      if (importedNodes.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لم يتم العثور على ملفات برمجية قابلة للقراءة داخل الأرشيف.')),
        );
        return;
      }

      setState(() {
        _projectName = res!.files.single.name.replaceAll(RegExp(r'\.zip$', caseSensitive: false), '');
        _nodes = importedNodes;
        _expandedFolders
          ..clear()
          ..add('lib');
        final mainFile = _nodes.where((n) => !n.isFolder && n.path == 'lib/main.dart').firstOrNull ??
            _nodes.where((n) => !n.isFolder).first;
        _openTabs = [mainFile.path];
        _activeFilePath = mainFile.path;
        _codeController.text = mainFile.content;
      });
      await _saveAllFiles(showToast: false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم استيراد المشروع ($_projectName) بنجاح!')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر فك ملف الـ ZIP: $e')),
      );
    }
  }

  Future<void> _showCreateNodeDialog({String? parentFolder, required bool isFolder}) async {
    final controller = TextEditingController(
      text: parentFolder != null && parentFolder.isNotEmpty ? '$parentFolder/' : 'lib/',
    );
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(isFolder ? 'إنشاء مجلد جديد' : 'إنشاء ملف جديد'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.ltr,
          decoration: InputDecoration(
            labelText: isFolder ? 'مسار المجلد (مثال: lib/screens)' : 'مسار الملف (مثال: lib/home.dart)',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('إنشاء'),
          ),
        ],
      ),
    );

    if (result == null || result.isEmpty) return;
    final cleanPath = result.replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '');
    if (cleanPath.isEmpty) return;

    if (_nodes.any((n) => n.path == cleanPath)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('هذا المسار موجود بالفعل.')),
      );
      return;
    }

    setState(() {
      final parts = cleanPath.split('/');
      var acc = '';
      for (var i = 0; i < parts.length - 1; i++) {
        acc = acc.isEmpty ? parts[i] : '$acc/${parts[i]}';
        if (!_nodes.any((n) => n.isFolder && n.path == acc)) {
          _nodes.add(IdeNode(path: acc, isFolder: true));
        }
        _expandedFolders.add(acc);
      }

      final newNode = IdeNode(
        path: cleanPath,
        isFolder: isFolder,
        content: isFolder
            ? ''
            : cleanPath.endsWith('.dart')
                ? "import 'package:flutter/material.dart';\n\n// $cleanPath\n"
                : '',
      );
      _nodes.add(newNode);
      if (isFolder) {
        _expandedFolders.add(cleanPath);
      } else {
        _selectFile(cleanPath);
      }
    });
    await _saveAllFiles(showToast: false);
  }

  Future<void> _deleteNode(IdeNode node) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('تأكيد الحذف'),
        content: Text('هل تريد حذف "${node.path}" نهائياً من المشروع؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() {
      _nodes.removeWhere(
        (n) => n.path == node.path || (node.isFolder && n.path.startsWith('${node.path}/')),
      );
      _openTabs.removeWhere(
        (t) => t == node.path || (node.isFolder && t.startsWith('${node.path}/')),
      );
      if (_activeFilePath != null && !_openTabs.contains(_activeFilePath)) {
        _activeFilePath = _openTabs.isNotEmpty ? _openTabs.last : null;
        final next = _nodes.where((n) => !n.isFolder && n.path == _activeFilePath).firstOrNull;
        _codeController.text = next?.content ?? '';
      }
    });
    await _saveAllFiles(showToast: false);
  }

  Future<void> _openAiAssistantSheet() async {
    final prefs = await SharedPreferences.getInstance();
    var provider = prefs.getString('ide_ai_provider') ?? 'gemini';
    final apiKeyCtrl = TextEditingController(text: prefs.getString('ide_ai_api_key') ?? '');
    final modelCtrl = TextEditingController(
      text: prefs.getString('ide_ai_model') ?? 'gemini-2.5-flash',
    );
    final promptCtrl = TextEditingController();
    String? aiReply;
    String? extractedCode;
    String? errorMsg;
    bool busy = false;
    bool showSettings = apiKeyCtrl.text.isEmpty;

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            Future<void> sendPrompt() async {
              if (promptCtrl.text.trim().isEmpty) return;
              setModalState(() {
                busy = true;
                errorMsg = null;
              });
              await prefs.setString('ide_ai_provider', provider);
              await prefs.setString('ide_ai_api_key', apiKeyCtrl.text.trim());
              await prefs.setString('ide_ai_model', modelCtrl.text.trim());

              try {
                final reply = await AiAssistantService.generateOrEditCode(
                  provider: provider,
                  apiKey: apiKeyCtrl.text,
                  model: modelCtrl.text,
                  prompt: promptCtrl.text,
                  currentFilePath: _activeFilePath ?? 'lib/main.dart',
                  currentFileContent: _codeController.text,
                );
                setModalState(() {
                  aiReply = reply;
                  extractedCode = AiAssistantService.extractCodeBlock(reply);
                });
              } catch (e) {
                setModalState(() {
                  errorMsg = e.toString().replaceFirst('Exception: ', '');
                });
              } finally {
                setModalState(() => busy = false);
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 14,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.auto_awesome, color: AppColors.orange),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'مساعد الذكاء الاصطناعي (AI Code Assistant)',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ),
                        IconButton(
                          icon: Icon(showSettings ? Icons.expand_less : Icons.key_outlined),
                          tooltip: 'إعدادات API',
                          onPressed: () => setModalState(() => showSettings = !showSettings),
                        ),
                      ],
                    ),
                    Text(
                      'الملف المفتوح: ${_activeFilePath ?? "لا يوجد"}',
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                    ),
                    const SizedBox(height: 10),
                    if (showSettings) ...[
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'gemini', label: Text('Google Gemini')),
                          ButtonSegment(value: 'openai', label: Text('OpenAI')),
                        ],
                        selected: {provider},
                        onSelectionChanged: (s) {
                          setModalState(() {
                            provider = s.first;
                            modelCtrl.text = provider == 'gemini' ? 'gemini-2.5-flash' : 'gpt-4o-mini';
                          });
                        },
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: apiKeyCtrl,
                        obscureText: true,
                        textDirection: TextDirection.ltr,
                        decoration: InputDecoration(
                          labelText: provider == 'gemini' ? 'Gemini API Key' : 'OpenAI API Key',
                          prefixIcon: const Icon(Icons.vpn_key_outlined),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: modelCtrl,
                        textDirection: TextDirection.ltr,
                        decoration: const InputDecoration(
                          labelText: 'اسم النموذج (Model)',
                          prefixIcon: Icon(Icons.memory_outlined),
                        ),
                      ),
                      const Divider(height: 22),
                    ],
                    TextField(
                      controller: promptCtrl,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        hintText: 'اطلب من الذكاء الاصطناعي تعديل هذا الكود أو إضافة ميزة...',
                        labelText: 'طلبك البرمجي',
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.orange,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                        onPressed: busy ? null : sendPrompt,
                        icon: busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                              )
                            : const Icon(Icons.send_rounded),
                        label: Text(busy ? 'جارٍ التوليد...' : 'توليد وتعديل الكود'),
                      ),
                    ),
                    if (errorMsg != null) ...[
                      const SizedBox(height: 10),
                      Text(errorMsg!, style: const TextStyle(color: AppColors.danger)),
                    ],
                    if (aiReply != null) ...[
                      const Divider(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('الرد المقترح:', style: TextStyle(fontWeight: FontWeight.bold)),
                          if (extractedCode != null && _activeFilePath != null)
                            Row(
                              children: [
                                TextButton.icon(
                                  icon: const Icon(Icons.add_box_outlined, size: 18),
                                  label: const Text('إدراج عند المؤشر'),
                                  onPressed: () {
                                    _insertSymbol('\n$extractedCode\n');
                                    Navigator.pop(ctx);
                                  },
                                ),
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.success,
                                    foregroundColor: Colors.white,
                                  ),
                                  icon: const Icon(Icons.check_circle_outline, size: 18),
                                  label: const Text('تطبيق على الملف'),
                                  onPressed: () {
                                    _codeController.text = extractedCode!;
                                    _saveAllFiles(showToast: true);
                                    Navigator.pop(ctx);
                                  },
                                ),
                              ],
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 220),
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.darkBg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            aiReply!,
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openCloudBuildDialog() async {
    await _saveAllFiles(showToast: false);
    final prefs = await SharedPreferences.getInstance();
    final patCtrl = TextEditingController(text: prefs.getString('ide_gh_pat') ?? '');
    final repoCtrl = TextEditingController(text: prefs.getString('ide_gh_repo') ?? '');
    final branchCtrl = TextEditingController(text: prefs.getString('ide_gh_branch') ?? 'main');
    final commitCtrl = TextEditingController(text: 'Update from Mobile IDE');

    bool busy = false;
    String? statusMsg;
    String? errorMsg;
    String? actionsUrl;

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            Future<void> runCloudBuild() async {
              setModalState(() {
                busy = true;
                errorMsg = null;
                statusMsg = null;
                actionsUrl = null;
              });

              try {
                await prefs.setString('ide_gh_pat', patCtrl.text.trim());
                await prefs.setString('ide_gh_repo', repoCtrl.text.trim());
                await prefs.setString('ide_gh_branch', branchCtrl.text.trim());

                final url = await GithubDirectCloudBuildService.pushProjectAndTriggerBuild(
                  patToken: patCtrl.text,
                  repoFullName: repoCtrl.text,
                  branch: branchCtrl.text,
                  nodes: _nodes,
                  commitMessage: commitCtrl.text.trim().isEmpty
                      ? 'Update from Mobile IDE'
                      : commitCtrl.text.trim(),
                );
                setModalState(() {
                  statusMsg = 'تم رفع التعديلات وتشغيل GitHub Actions لبناء الـ APK بنجاح!';
                  actionsUrl = url;
                });
              } catch (e) {
                setModalState(() {
                  errorMsg = e.toString().replaceFirst('Exception: ', '');
                });
              } finally {
                setModalState(() => busy = false);
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 14,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.cloud_upload_outlined, color: AppColors.primaryLight),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'نظام البناء السحابي (GitHub Actions APK)',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: patCtrl,
                      obscureText: true,
                      textDirection: TextDirection.ltr,
                      decoration: const InputDecoration(
                        labelText: 'GitHub Personal Access Token (PAT)',
                        hintText: 'ghp_xxxxxxxxxxxxxxxxxxxx',
                        prefixIcon: Icon(Icons.vpn_key_outlined),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: repoCtrl,
                            textDirection: TextDirection.ltr,
                            decoration: const InputDecoration(
                              labelText: 'المستودع (owner/repo)',
                              hintText: 'username/my-flutter-app',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: branchCtrl,
                            textDirection: TextDirection.ltr,
                            decoration: const InputDecoration(
                              labelText: 'الفرع',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: commitCtrl,
                      decoration: const InputDecoration(
                        labelText: 'رسالة التحديث (Commit Message)',
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                        onPressed: busy ? null : runCloudBuild,
                        icon: busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.play_arrow_rounded),
                        label: Text(busy ? 'جارٍ الرفع وتشغيل البناء...' : 'رفع التعديلات وبناء APK'),
                      ),
                    ),
                    if (errorMsg != null) ...[
                      const SizedBox(height: 10),
                      Text(errorMsg!, style: const TextStyle(color: AppColors.danger)),
                    ],
                    if (statusMsg != null) ...[
                      const SizedBox(height: 10),
                      Text(statusMsg!, style: const TextStyle(color: AppColors.success)),
                      if (actionsUrl != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('فتح صفحة GitHub Actions لمتابعة البناء'),
                            onPressed: () => launchUrl(
                              Uri.parse(actionsUrl!),
                              mode: LaunchMode.externalApplication,
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildFileExplorerDrawer() {
    final sortedNodes = [..._nodes]..sort((a, b) {
        if (a.isFolder != b.isFolder) {
          return a.isFolder ? -1 : 1;
        }
        return a.path.compareTo(b.path);
      });

    final visibleNodes = sortedNodes.where((node) {
      final parts = node.path.split('/');
      if (parts.length == 1) return true;
      var parent = '';
      for (var i = 0; i < parts.length - 1; i++) {
        parent = parent.isEmpty ? parts[i] : '$parent/${parts[i]}';
        if (!_expandedFolders.contains(parent)) return false;
      }
      return true;
    }).toList();

    return Drawer(
      backgroundColor: AppColors.surface,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.folder_copy_outlined, color: AppColors.orange),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _projectName,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.note_add_outlined, size: 20),
                    tooltip: 'ملف جديد',
                    onPressed: () => _showCreateNodeDialog(isFolder: false),
                  ),
                  IconButton(
                    icon: const Icon(Icons.create_new_folder_outlined, size: 20),
                    tooltip: 'مجلد جديد',
                    onPressed: () => _showCreateNodeDialog(isFolder: true),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.folder_zip_outlined, size: 17),
                      label: const Text('استيراد ZIP', style: TextStyle(fontSize: 12)),
                      onPressed: () {
                        Navigator.pop(context);
                        _importZipIntoIde();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.restart_alt_rounded, size: 17),
                      label: const Text('إعادة ضبط', style: TextStyle(fontSize: 12)),
                      onPressed: () async {
                        setState(() {
                          _nodes = _createStarterProject();
                          _openTabs = ['lib/main.dart'];
                          _activeFilePath = 'lib/main.dart';
                          _codeController.text = _nodes
                              .firstWhere((n) => n.path == 'lib/main.dart')
                              .content;
                        });
                        await _saveAllFiles(showToast: false);
                        if (mounted) Navigator.pop(context);
                      },
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 16),
            Expanded(
              child: ListView.builder(
                itemCount: visibleNodes.length,
                itemBuilder: (ctx, index) {
                  final node = visibleNodes[index];
                  final depth = node.path.split('/').length - 1;
                  final isSelected = !node.isFolder && node.path == _activeFilePath;
                  final isExpanded = node.isFolder && _expandedFolders.contains(node.path);

                  return InkWell(
                    onTap: () {
                      if (node.isFolder) {
                        setState(() {
                          if (isExpanded) {
                            _expandedFolders.remove(node.path);
                          } else {
                            _expandedFolders.add(node.path);
                          }
                        });
                      } else {
                        _selectFile(node.path);
                        Navigator.pop(context);
                      }
                    },
                    child: Container(
                      color: isSelected ? AppColors.orange.withOpacity(0.16) : null,
                      padding: EdgeInsets.only(
                        left: 12.0 + depth * 16.0,
                        right: 10,
                        top: 8,
                        bottom: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            node.isFolder
                                ? (isExpanded ? Icons.folder_open : Icons.folder)
                                : _fileIcon(node.name),
                            size: 19,
                            color: node.isFolder
                                ? AppColors.orange
                                : (node.name.endsWith('.dart')
                                    ? AppColors.primaryLight
                                    : AppColors.textMuted),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              node.name + (node.isDirty ? ' •' : ''),
                              textDirection: TextDirection.ltr,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                color: isSelected ? AppColors.orange : null,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (node.isFolder)
                            IconButton(
                              icon: const Icon(Icons.add, size: 17),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              tooltip: 'إضافة ملف هنا',
                              onPressed: () =>
                                  _showCreateNodeDialog(parentFolder: node.path, isFolder: false),
                            ),
                          const SizedBox(width: 6),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 17, color: AppColors.danger),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            tooltip: 'حذف',
                            onPressed: () => _deleteNode(node),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _fileIcon(String name) {
    if (name.endsWith('.dart')) return Icons.code_rounded;
    if (name.endsWith('.yaml') || name.endsWith('.yml')) return Icons.settings_suggest_outlined;
    if (name.endsWith('.md')) return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final lineCount = '\n'.allMatches(_codeController.text).length + 1;

    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildFileExplorerDrawer(),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.account_tree_outlined),
          tooltip: 'مستعرض الملفات',
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: Text(
          _activeFilePath ?? _projectName,
          style: const TextStyle(fontSize: 14, fontFamily: 'monospace', fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.save_outlined),
            tooltip: 'حفظ التعديلات',
            onPressed: () => _saveAllFiles(showToast: true),
          ),
          IconButton(
            icon: const Icon(Icons.auto_awesome, color: AppColors.orange),
            tooltip: 'مساعد الذكاء الاصطناعي (AI)',
            onPressed: _openAiAssistantSheet,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: _openCloudBuildDialog,
              icon: const Icon(Icons.cloud_upload_outlined, size: 17),
              label: const Text('بناء APK', style: TextStyle(fontSize: 12.5)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_openTabs.isNotEmpty)
            Container(
              height: 38,
              color: AppColors.surface,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _openTabs.length,
                itemBuilder: (ctx, idx) {
                  final tabPath = _openTabs[idx];
                  final isCurrent = tabPath == _activeFilePath;
                  final node = _nodes.where((n) => n.path == tabPath).firstOrNull;
                  final dirty = node?.isDirty ?? false;

                  return InkWell(
                    onTap: () => _selectFile(tabPath),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: isCurrent ? AppColors.darkBg : AppColors.surface,
                        border: Border(
                          bottom: BorderSide(
                            color: isCurrent ? AppColors.orange : Colors.transparent,
                            width: 2.5,
                          ),
                          right: const BorderSide(color: AppColors.border, width: 0.5),
                        ),
                      ),
                      child: Row(
                        children: [
                          Text(
                            tabPath.split('/').last + (dirty ? ' •' : ''),
                            style: TextStyle(
                              fontSize: 12.5,
                              fontFamily: 'monospace',
                              color: isCurrent ? AppColors.orange : AppColors.textMuted,
                              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                          const SizedBox(width: 6),
                          GestureDetector(
                            onTap: () => _closeTab(tabPath),
                            child: const Icon(Icons.close, size: 14, color: AppColors.textMuted),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

          Expanded(
            child: _activeFilePath == null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.code_off_rounded, size: 48, color: AppColors.textMuted),
                        const SizedBox(height: 10),
                        const Text('لا يوجد ملف مفتوح حالياً'),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.folder_open),
                          label: const Text('فتح مستعرض الملفات'),
                          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                        ),
                      ],
                    ),
                  )
                : Directionality(
                    textDirection: TextDirection.ltr,
                    child: Container(
                      color: AppColors.darkBg,
                      child: SingleChildScrollView(
                        controller: _editorScrollController,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 44,
                              padding: const EdgeInsets.only(right: 8, left: 6),
                              decoration: const BoxDecoration(
                                border: Border(
                                  right: BorderSide(color: AppColors.border),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: List.generate(
                                  lineCount,
                                  (i) => Text(
                                    '${i + 1}',
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 14,
                                      height: 1.5,
                                      color: AppColors.textMuted,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextField(
                                controller: _codeController,
                                maxLines: null,
                                keyboardType: TextInputType.multiline,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 14,
                                  height: 1.5,
                                  color: AppColors.textPrimary,
                                ),
                                decoration: const InputDecoration(
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  filled: false,
                                  isDense: true,
                                  contentPadding: EdgeInsets.only(right: 14),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),

          Directionality(
            textDirection: TextDirection.ltr,
            child: Container(
              height: 42,
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(top: BorderSide(color: AppColors.border)),
              ),
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                children: [
                  for (final sym in [
                    ('Tab', '  '),
                    ('{', '{'),
                    ('}', '}'),
                    ('(', '('),
                    (')', ')'),
                    ('[', '['),
                    (']', ']'),
                    (';', ';'),
                    ('=>', ' => '),
                    ('=', ' = '),
                    ("'", "'"),
                    ('"', '"'),
                    (r'$', r'$'),
                    ('//', '// '),
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => _insertSymbol(sym.$2),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.surfaceAlt,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Text(
                            sym.$1,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}