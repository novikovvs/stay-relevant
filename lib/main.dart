import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';

const ink = Color(0xFF15251F);
const muted = Color(0xFF7C8983);
const paper = Color(0xFFF4F6F1);
const card = Color(0xFFFFFFFF);
const green = Color(0xFF4FCB91);
const greenDark = Color(0xFF198A60);
const line = Color(0xFFE6EAE5);
const orange = Color(0xFFEAA76A);
const red = Color(0xFFD66C67);

void main() => runApp(const TrainerApp());

class TrainerApp extends StatelessWidget {
  const TrainerApp({super.key});

  @override
  Widget build(BuildContext context) => WidgetsApp(
    color: greenDark,
    debugShowCheckedModeBanner: false,
    pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
      settings: settings,
      pageBuilder: (context, animation, secondaryAnimation) => builder(context),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
    textStyle: const TextStyle(
      color: ink,
      fontFamily: '.AppleSystemUIFont',
      fontSize: 14,
    ),
    home: const TrainerHome(),
  );
}

class StudyStore {
  static const _repo = 'novikovvs/stay-relevant';
  static const _branch = 'main';
  final _random = Random.secure();
  final _http = HttpClient();
  final Map<String, Map<String, dynamic>> _banks = {};
  final Map<String, Map<String, dynamic>> _catalog = {};
  final Map<String, Map<String, dynamic>> _progress = {};
  final Map<String, Map<String, dynamic>> _challenges = {};
  bool _initialized = false;
  late final File _progressFile;

  Future<void> initialize() async {
    if (_initialized) return;
    final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    final directory = Directory(
      '$home/Library/Application Support/Stay Relevant',
    );
    await directory.create(recursive: true);
    _progressFile = File('${directory.path}/progress.json');
    final legacyProgress = File(
      '$home/Library/Application Support/Go Fluent/progress.json',
    );
    if (!await _progressFile.exists() && await legacyProgress.exists()) {
      await legacyProgress.copy(_progressFile.path);
    }
    _blocksDirectory = Directory('${directory.path}/blocks');
    await _blocksDirectory.create(recursive: true);
    if (await _progressFile.exists()) {
      final saved =
          jsonDecode(await _progressFile.readAsString())
              as Map<String, dynamic>;
      for (final entry
          in (saved['banks'] as Map<String, dynamic>? ?? {}).entries) {
        _progress[entry.key] = Map<String, dynamic>.from(entry.value as Map);
      }
    }
    await _scanLocalBlocks();
    try {
      final request = await _http.getUrl(
        Uri.https('api.github.com', '/repos/$_repo/contents/blocks', {
          'ref': _branch,
        }),
      );
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'Stay-Relevant');
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('GitHub вернул ${response.statusCode}');
      }
      final entries =
          jsonDecode(await response.transform(utf8.decoder).join()) as List;
      for (final entry in entries) {
        if (entry is! Map<String, dynamic> || entry['type'] != 'file') continue;
        final path = entry['path'] as String?;
        final name = entry['name'] as String?;
        if (path == null ||
            name == null ||
            !path.startsWith('blocks/') ||
            path.substring(7).contains('/') ||
            !name.endsWith('.json'))
          continue;
        final id = name.substring(0, name.length - 5);
        if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) continue;
        final rawRequest = await _http.getUrl(
          Uri.https('raw.githubusercontent.com', '/$_repo/$_branch/$path'),
        );
        rawRequest.headers.set(HttpHeaders.userAgentHeader, 'Stay-Relevant');
        final rawResponse = await rawRequest.close().timeout(
          const Duration(seconds: 20),
        );
        if (rawResponse.statusCode != HttpStatus.ok) continue;
        final bytes = await rawResponse.fold<List<int>>(
          [],
          (all, chunk) => all..addAll(chunk),
        );
        if (bytes.length > 15 * 1024 * 1024) continue;
        final source = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        final questions = source['questions'] as List?;
        if (questions == null || questions.isEmpty) continue;
        _catalog[id] = {
          'id': id,
          'title': source['title'] ?? id,
          'path': path,
          'question_count': questions.length,
          'category_count': questions
              .map((q) => (q as Map)['category'])
              .toSet()
              .length,
        };
      }
    } catch (_) {
      // Downloaded blocks remain available offline when the catalog cannot load.
    }
    for (final entry in _banks.entries) {
      _catalog.putIfAbsent(
        entry.key,
        () => Map<String, dynamic>.from(entry.value),
      );
    }
    _initialized = true;
  }

  late final Directory _blocksDirectory;

  Future<void> _scanLocalBlocks() async {
    _banks.clear();
    await for (final entity in _blocksDirectory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final source =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        _addBank(
          entity.uri.pathSegments.last.replaceFirst('.json', ''),
          source,
        );
      } catch (_) {
        // Ignore malformed files; validation runs again when downloading.
      }
    }
  }

  void _addBank(String id, Map<String, dynamic> source) {
    if (source['id'] != null && source['id'] != id) {
      throw const FormatException('ID блока не совпадает с именем файла.');
    }
    final questions = (source['questions'] as List)
        .cast<Map<String, dynamic>>();
    final ids = <String>{};
    if (questions.isEmpty ||
        questions.any(
          (q) =>
              q['id'] is! String ||
              q['question'] is! String ||
              q['answer'] is! String ||
              q['distractors'] is! List ||
              (q['distractors'] as List).length != 3 ||
              (q['distractors'] as List).any((answer) => answer is! String) ||
              (q['distractors'] as List).toSet().length != 3 ||
              (q['distractors'] as List).contains(q['answer']) ||
              !ids.add(q['id'] as String),
        )) {
      throw const FormatException('Неверный формат блока вопросов.');
    }
    _banks[id] = {
      'id': id,
      'title': source['title'] ?? id,
      'question_count': questions.length,
      'category_count': questions.map((q) => q['category']).toSet().length,
      'questions': questions,
    };
  }

  Future<void> download(String id) async {
    final entry = _catalog[id];
    if (entry == null || entry['path'] is! String)
      throw Exception('Блок не найден в каталоге.');
    final path = entry['path'] as String;
    final uri = Uri.https(
      'raw.githubusercontent.com',
      '/$_repo/$_branch/$path',
    );
    final request = await _http.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, 'Stay-Relevant');
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.ok)
      throw HttpException('Не удалось скачать блок (${response.statusCode}).');
    final bytes = await response.fold<List<int>>(
      [],
      (all, chunk) => all..addAll(chunk),
    );
    if (bytes.length > 15 * 1024 * 1024)
      throw const FormatException('Файл блока слишком большой.');
    final source = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    _addBank(id, source);
    await File(
      '${_blocksDirectory.path}/$id.json',
    ).writeAsBytes(bytes, flush: true);
  }

  Future<dynamic> get(String path) async {
    if (path == '/banks') {
      return _banks.values
          .map((b) => Map<String, dynamic>.from(b)..remove('questions'))
          .toList();
    }
    if (path == '/catalog') {
      return _catalog.values
          .map(
            (b) => {
              'id': b['id'],
              'title': b['title'],
              'question_count':
                  _banks[b['id']]?['question_count'] ??
                  b['question_count'] ??
                  0,
              'category_count':
                  _banks[b['id']]?['category_count'] ??
                  b['category_count'] ??
                  0,
              'downloaded': _banks.containsKey(b['id']),
            },
          )
          .toList();
    }
    final uri = Uri.parse(path);
    final id = uri.queryParameters['bank'];
    final bank = _banks[id];
    if (bank == null) {
      throw Exception('Не найдена база вопросов: $id');
    }
    final state = _state(id!);
    if (uri.path == '/progress') return _summary(bank, state);
    if (uri.path == '/next') return _next(id, bank, state);
    throw Exception('Неизвестная операция');
  }

  Future<dynamic> post(String path, Map<String, Object?> body) async {
    if (path != '/answer') {
      throw Exception('Неизвестная операция');
    }
    final token = body['token'] as String?;
    final challenge = _challenges.remove(token);
    if (challenge == null || challenge['bank_id'] != body['bank_id']) {
      throw Exception('Карточка устарела, запроси следующую.');
    }
    final correct = body['option_id'] == challenge['correct_id'];
    final id = challenge['bank_id'] as String;
    final state = _state(id);
    final cards = state['cards'] as Map<String, dynamic>;
    final qid = challenge['question_id'] as String;
    final card = Map<String, dynamic>.from(cards[qid] as Map? ?? {});
    final answers = (state['total_answers'] as int) + 1;
    state['total_answers'] = answers;
    final counter = correct ? 'correct_answers' : 'incorrect_answers';
    state[counter] = (state[counter] as int? ?? 0) + 1;
    final category = challenge['category'] as String? ?? 'Другое';
    final categoryStats = state['category_stats'] as Map<String, dynamic>;
    final categoryStat = Map<String, dynamic>.from(
      categoryStats[category] as Map? ?? {'correct': 0, 'total': 0},
    );
    categoryStat['total'] = (categoryStat['total'] as int) + 1;
    if (correct) categoryStat['correct'] = (categoryStat['correct'] as int) + 1;
    categoryStats[category] = categoryStat;
    final day = DateTime.now().toIso8601String().substring(0, 10);
    final daily = state['daily_answers'] as Map<String, dynamic>;
    daily[day] = (daily[day] as int? ?? 0) + 1;
    final streak = correct ? ((card['streak'] as int? ?? 0) + 1) : 0;
    final reviews = (card['reviews'] as int? ?? 0) + 1;
    card['streak'] = streak;
    card['reviews'] = reviews;
    if (correct && streak >= 3) {
      final days = [1, 3, 7, 14, 30];
      card['due_at'] =
          DateTime.now()
              .add(Duration(days: days[(streak - 3).clamp(0, 4).toInt()]))
              .millisecondsSinceEpoch ~/
          1000;
      card['due_after'] = answers;
    } else {
      card['due_at'] = 0;
      card['due_after'] = answers + (correct ? (streak == 1 ? 3 : 6) : 3);
    }
    cards[qid] = card;
    await _save();
    final bank = _banks[id]!;
    return {
      'correct': correct,
      'correct_option_id': challenge['correct_id'],
      'streak': streak,
      'review_count': reviews,
      'progress': _summary(bank, state),
    };
  }

  Map<String, dynamic> _state(String id) {
    final state = _progress.putIfAbsent(id, () => <String, dynamic>{});
    state.putIfAbsent('total_answers', () => 0);
    state.putIfAbsent('cards', () => <String, dynamic>{});
    state.putIfAbsent('recent_question_ids', () => <String>[]);
    state.putIfAbsent('correct_answers', () => 0);
    state.putIfAbsent('incorrect_answers', () => 0);
    state.putIfAbsent('category_stats', () => <String, dynamic>{});
    state.putIfAbsent('daily_answers', () => <String, dynamic>{});
    return state;
  }

  Map<String, dynamic> _summary(
    Map<String, dynamic> bank,
    Map<String, dynamic> state,
  ) {
    final cards = state['cards'] as Map<String, dynamic>;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var learned = 0, mastered = 0, due = 0;
    for (final q in bank['questions'] as List) {
      final c = cards[q['id']];
      if (c == null) {
        due++;
        continue;
      }
      final card = c as Map;
      if ((card['reviews'] as int? ?? 0) > 0) learned++;
      if ((card['streak'] as int? ?? 0) >= 3) mastered++;
      if ((card['due_after'] as int? ?? 0) <= (state['total_answers'] as int) &&
          (card['due_at'] as int? ?? 0) <= now) {
        due++;
      }
    }
    final categories = state['category_stats'] as Map<String, dynamic>? ?? {};
    final correct = state['correct_answers'] as int? ?? 0;
    final incorrect = state['incorrect_answers'] as int? ?? 0;
    return {
      'learned': learned,
      'mastered': mastered,
      'due': due,
      'total': bank['question_count'],
      'total_answers': state['total_answers'],
      'correct_answers': correct,
      'incorrect_answers': incorrect,
      'accuracy': correct + incorrect == 0
          ? 0.0
          : correct / (correct + incorrect),
      'category_stats': categories,
    };
  }

  Future<Map<String, dynamic>> _next(
    String id,
    Map<String, dynamic> bank,
    Map<String, dynamic> state,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final totalAnswers = state['total_answers'] as int;
    final cards = state['cards'] as Map<String, dynamic>;
    final questions = (bank['questions'] as List).cast<Map<String, dynamic>>();
    var available = questions.where((q) {
      final c = cards[q['id']] as Map?;
      return (c?['due_after'] as int? ?? 0) <= totalAnswers &&
          (c?['due_at'] as int? ?? 0) <= now;
    }).toList();
    if (available.isEmpty) {
      available = questions.where((q) {
        final c = cards[q['id']] as Map?;
        return (c?['reviews'] as int? ?? 0) > 0 &&
            (c?['due_at'] as int? ?? 0) <= now;
      }).toList();
    }
    if (available.isEmpty) {
      return {
        'empty': true,
        'next_due_at': null,
        'progress': _summary(bank, state),
      };
    }
    final recent = (state['recent_question_ids'] as List)
        .cast<String>()
        .toSet();
    final fresh = available.where((q) => !recent.contains(q['id'])).toList();
    if (fresh.isNotEmpty) available = fresh;
    available.sort((a, b) {
      final ca = cards[a['id']] as Map? ?? const {},
          cb = cards[b['id']] as Map? ?? const {};
      final reviewed = ((cb['reviews'] as int? ?? 0) > 0 ? 1 : 0).compareTo(
        (ca['reviews'] as int? ?? 0) > 0 ? 1 : 0,
      );
      return reviewed != 0
          ? reviewed
          : (ca['due_after'] as int? ?? 0).compareTo(
              cb['due_after'] as int? ?? 0,
            );
    });
    final first = cards[available.first['id']] as Map? ?? const {};
    final tier = available.takeWhile((q) {
      final c = cards[q['id']] as Map? ?? const {};
      return ((c['reviews'] as int? ?? 0) > 0) ==
              ((first['reviews'] as int? ?? 0) > 0) &&
          (c['due_after'] as int? ?? 0) == (first['due_after'] as int? ?? 0);
    }).toList();
    final q = tier[_random.nextInt(tier.length)];
    final texts = <String>[
      q['answer'] as String,
      ...(q['distractors'] as List).cast<String>(),
    ]..shuffle(_random);
    final options = [
      for (var i = 0; i < texts.length; i++)
        {'id': 'choice-$i', 'text': texts[i]},
    ];
    final correctId = 'choice-${texts.indexOf(q['answer'])}';
    final token = List.generate(
      24,
      (_) => _random.nextInt(16).toRadixString(16),
    ).join();
    _challenges[token] = {
      'bank_id': id,
      'question_id': q['id'],
      'category': q['category'],
      'correct_id': correctId,
    };
    final history = state['recent_question_ids'] as List;
    history.add(q['id']);
    if (history.length > 20) history.removeRange(0, history.length - 20);
    await _save();
    final c = cards[q['id']] as Map? ?? const {};
    return {
      'empty': false,
      'token': token,
      'question': q,
      'options': options,
      'streak': c['streak'] ?? 0,
      'reviews': c['reviews'] ?? 0,
      'progress': _summary(bank, state),
    };
  }

  Future<void> _save() async {
    await _progressFile.writeAsString(
      jsonEncode({'banks': _progress}),
      flush: true,
    );
  }
}

class QuestionBank {
  const QuestionBank({
    required this.id,
    required this.title,
    required this.count,
    required this.categories,
    this.downloaded = true,
  });
  final String id;
  final String title;
  final int count;
  final int categories;
  final bool downloaded;
  factory QuestionBank.fromJson(Map<String, dynamic> json) => QuestionBank(
    id: json['id'] as String,
    title: json['title'] as String,
    count: json['question_count'] as int,
    categories: json['category_count'] as int,
    downloaded: json['downloaded'] as bool? ?? true,
  );
}

class LearningProgress {
  const LearningProgress({
    this.learned = 0,
    this.mastered = 0,
    this.due = 0,
    this.total = 0,
    this.answers = 0,
    this.correct = 0,
    this.incorrect = 0,
    this.categoryStats = const {},
  });
  final int learned;
  final int mastered;
  final int due;
  final int total;
  final int answers;
  final int correct;
  final int incorrect;
  final Map<String, CategoryStat> categoryStats;
  double get accuracy => answers == 0 ? 0 : correct / answers;
  factory LearningProgress.fromJson(Map<String, dynamic> json) =>
      LearningProgress(
        learned: json['learned'] as int? ?? 0,
        mastered: json['mastered'] as int? ?? 0,
        due: json['due'] as int? ?? 0,
        total: json['total'] as int? ?? 0,
        answers: json['total_answers'] as int? ?? 0,
        correct: json['correct_answers'] as int? ?? 0,
        incorrect: json['incorrect_answers'] as int? ?? 0,
        categoryStats: (json['category_stats'] as Map<String, dynamic>? ?? {})
            .map(
              (name, value) => MapEntry(
                name,
                CategoryStat.fromJson(Map<String, dynamic>.from(value as Map)),
              ),
            ),
      );
}

class CategoryStat {
  const CategoryStat({this.correct = 0, this.total = 0});
  final int correct;
  final int total;
  double get accuracy => total == 0 ? 0 : correct / total;
  factory CategoryStat.fromJson(Map<String, dynamic> json) => CategoryStat(
    correct: json['correct'] as int? ?? 0,
    total: json['total'] as int? ?? 0,
  );
}

class QuizQuestion {
  const QuizQuestion({
    required this.id,
    required this.text,
    required this.category,
    required this.answer,
    required this.sources,
  });
  final String id;
  final String text;
  final String category;
  final String answer;
  final List<String> sources;
  factory QuizQuestion.fromJson(Map<String, dynamic> json) => QuizQuestion(
    id: json['id'] as String,
    text: json['question'] as String,
    category: json['category'] as String? ?? 'Go',
    answer: json['answer'] as String,
    sources: (json['sources'] as List? ?? []).cast<String>(),
  );
}

class AnswerOption {
  const AnswerOption(this.id, this.text);
  final String id;
  final String text;
  factory AnswerOption.fromJson(Map<String, dynamic> json) =>
      AnswerOption(json['id'] as String, json['text'] as String);
}

class TrainerHome extends StatefulWidget {
  const TrainerHome({super.key});
  @override
  State<TrainerHome> createState() => _TrainerHomeState();
}

class _TrainerHomeState extends State<TrainerHome> {
  final store = StudyStore();
  List<QuestionBank> banks = [];
  Map<String, LearningProgress> progress = {};
  String? selectedBank;
  bool inQuiz = false;
  bool loading = true;
  String? downloading;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await store.initialize();
      final raw = await store.get('/catalog') as List;
      final loaded = raw
          .map((e) => QuestionBank.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final stats = <String, LearningProgress>{};
      for (final bank in loaded.where((bank) => bank.downloaded)) {
        final value = await store.get(
          '/progress?bank=${Uri.encodeQueryComponent(bank.id)}',
        );
        stats[bank.id] = LearningProgress.fromJson(
          Map<String, dynamic>.from(value),
        );
      }
      if (!mounted) return;
      setState(() {
        banks = loaded;
        progress = stats;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _download(QuestionBank bank) async {
    setState(() {
      downloading = bank.id;
    });
    try {
      await store.download(bank.id);
      await _load();
    } catch (e) {
      if (mounted)
        setState(() {
          error = e.toString().replaceFirst('Exception: ', '');
        });
    } finally {
      if (mounted) setState(() => downloading = null);
    }
  }

  Future<void> _refreshProgress() async {
    final matches = banks.where((e) => e.id == selectedBank);
    if (matches.isEmpty) return;
    final bank = matches.first;
    try {
      final value = await store.get(
        '/progress?bank=${Uri.encodeQueryComponent(bank.id)}',
      );
      if (mounted) {
        setState(
          () => progress[bank.id] = LearningProgress.fromJson(
            Map<String, dynamic>.from(value),
          ),
        );
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: paper,
      child: Row(
        children: [
          _Sidebar(
            inQuiz: inQuiz,
            onHome: () => setState(() => inQuiz = false),
            onReview: () {
              final downloaded = banks.where((bank) => bank.downloaded);
              if (downloaded.isEmpty) return;
              setState(() {
                selectedBank ??= downloaded.first.id;
                inQuiz = true;
              });
            },
          ),
          Expanded(
            child: loading
                ? const Center(child: _LoadingState())
                : error != null
                ? _ConnectionState(message: error!, onRetry: _load)
                : inQuiz && selectedBank != null
                ? QuizScreen(
                    api: store,
                    bank: banks.firstWhere((b) => b.id == selectedBank),
                    onProgress: _refreshProgress,
                    onExit: () {
                      setState(() => inQuiz = false);
                      _refreshProgress();
                    },
                  )
                : _Dashboard(
                    banks: banks,
                    progress: progress,
                    downloading: downloading,
                    onDownload: _download,
                    onStart: (bank) => setState(() {
                      selectedBank = bank.id;
                      inQuiz = true;
                    }),
                  ),
          ),
        ],
      ),
    ),
  );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.inQuiz,
    required this.onHome,
    required this.onReview,
  });
  final bool inQuiz;
  final VoidCallback onHome;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) => Container(
    width: 232,
    color: const Color(0xFF192923),
    padding: const EdgeInsets.fromLTRB(22, 32, 18, 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: green,
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Center(
                child: Text(
                  'S',
                  style: TextStyle(
                    color: ink,
                    fontSize: 25,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 11),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'stay relevant',
                  style: TextStyle(
                    color: Color(0xFFFFFFFF),
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'ТРЕНАЖЁР',
                  style: TextStyle(
                    color: Color(0xFF9AA79F),
                    fontSize: 8,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 44),
        _NavItem(
          icon: '⌂',
          label: 'Моя программа',
          selected: !inQuiz,
          onTap: onHome,
        ),
        const SizedBox(height: 8),
        _NavItem(
          icon: '◷',
          label: 'Повторение',
          selected: inQuiz,
          onTap: onReview,
        ),
        const Spacer(),
      ],
    ),
  );
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      height: 43,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF2B4035) : const Color(0x00000000),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: [
          Text(
            icon,
            style: TextStyle(
              color: selected ? green : const Color(0xFF9CAB9F),
              fontSize: 19,
            ),
          ),
          const SizedBox(width: 11),
          Text(
            label,
            style: TextStyle(
              color: selected
                  ? const Color(0xFFFFFFFF)
                  : const Color(0xFFB8C4BC),
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    ),
  );
}

class _Dashboard extends StatelessWidget {
  const _Dashboard({
    required this.banks,
    required this.progress,
    required this.onStart,
    required this.onDownload,
    required this.downloading,
  });
  final List<QuestionBank> banks;
  final Map<String, LearningProgress> progress;
  final ValueChanged<QuestionBank> onStart;
  final ValueChanged<QuestionBank> onDownload;
  final String? downloading;

  @override
  Widget build(BuildContext context) {
    final categoryTotals = <String, CategoryStat>{};
    for (final bankProgress in progress.values) {
      for (final entry in bankProgress.categoryStats.entries) {
        final previous = categoryTotals[entry.key] ?? const CategoryStat();
        categoryTotals[entry.key] = CategoryStat(
          correct: previous.correct + entry.value.correct,
          total: previous.total + entry.value.total,
        );
      }
    }
    final totals = progress.values.fold<LearningProgress>(
      const LearningProgress(),
      (a, b) => LearningProgress(
        learned: a.learned + b.learned,
        mastered: a.mastered + b.mastered,
        due: a.due + b.due,
        total: a.total + b.total,
        answers: a.answers + b.answers,
        correct: a.correct + b.correct,
        incorrect: a.incorrect + b.incorrect,
      ),
    );
    final stats = LearningProgress(
      learned: totals.learned,
      mastered: totals.mastered,
      due: totals.due,
      total: totals.total,
      answers: totals.answers,
      correct: totals.correct,
      incorrect: totals.incorrect,
      categoryStats: categoryTotals,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(48, 36, 52, 44),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    'ТВОЯ ТЕРРИТОРИЯ ЗНАНИЙ',
                    style: TextStyle(
                      color: greenDark,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.6,
                    ),
                  ),
                  const Spacer(),
                  _SmallPill(text: '${totals.answers} ответов · локально'),
                ],
              ),
              const SizedBox(height: 20),
              const Text(
                'Stay Relevant',
                style: TextStyle(
                  fontSize: 32,
                  height: 1.06,
                  letterSpacing: -1.8,
                  fontWeight: FontWeight.w800,
                  color: ink,
                ),
              ),
              const SizedBox(height: 22),
              _SummaryStrip(progress: totals),
              _StatisticsPanel(progress: stats),
              const SizedBox(height: 26),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'БЛОКИ',
                        style: TextStyle(
                          color: greenDark,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    '${banks.length} ${_plural(banks.length, 'блок', 'блока', 'блоков')}',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 17),
              if (banks.isEmpty)
                const Text(
                  'Каталог пуст или недоступен.',
                  style: TextStyle(color: muted),
                )
              else
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    for (var i = 0; i < banks.length; i++)
                      _BankCard(
                        bank: banks[i],
                        progress:
                            progress[banks[i].id] ?? const LearningProgress(),
                        accent: i == 0 ? green : orange,
                        onTap: () => onStart(banks[i]),
                        onDownload: () => onDownload(banks[i]),
                        downloading: downloading == banks[i].id,
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.progress});
  final LearningProgress progress;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 23, vertical: 18),
    decoration: BoxDecoration(
      color: ink,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      children: [
        const _MiniStat(
          icon: '✦',
          value: '3',
          caption: 'верных ответа\nдля первого освоения',
          color: green,
        ),
        _divider(),
        _MiniStat(
          icon: '↻',
          value: '${progress.due}',
          caption: 'вопросов ждут\nповторения',
          color: orange,
        ),
        _divider(),
        _MiniStat(
          icon: '✓',
          value: '${progress.mastered}',
          caption: 'уже освоено\nвсего',
          color: green,
        ),
        const Spacer(),
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF263C31),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Center(child: Text('⚡', style: TextStyle(fontSize: 22))),
        ),
      ],
    ),
  );
  Widget _divider() => Container(
    width: 1,
    height: 36,
    color: const Color(0xFF34443B),
    margin: const EdgeInsets.symmetric(horizontal: 28),
  );
}

class _StatisticsPanel extends StatelessWidget {
  const _StatisticsPanel({required this.progress});
  final LearningProgress progress;

  @override
  Widget build(BuildContext context) {
    final categories = progress.categoryStats.entries.toList()
      ..sort((a, b) => b.value.total.compareTo(a.value.total));
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'СТАТИСТИКА',
            style: TextStyle(
              color: greenDark,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _Metric(value: '${progress.answers}', label: 'ответов всего'),
              _Metric(
                value: '${(progress.accuracy * 100).round()}%',
                label: 'точность',
              ),
              _Metric(
                value: '${progress.correct} / ${progress.incorrect}',
                label: 'верно / неверно',
              ),
            ],
          ),
          if (categories.isNotEmpty) ...[
            const SizedBox(height: 18),
            const Text(
              'ПО ТЕМАМ',
              style: TextStyle(
                color: muted,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 10),
            for (final entry in categories.take(5)) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      entry.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: ink,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 160,
                    child: _ProgressBar(
                      value: entry.value.accuracy,
                      color: greenDark,
                    ),
                  ),
                  SizedBox(
                    width: 46,
                    child: Text(
                      '${(entry.value.accuracy * 100).round()}%',
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: muted, fontSize: 10),
                    ),
                  ),
                  SizedBox(
                    width: 76,
                    child: Text(
                      '${entry.value.correct}/${entry.value.total}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: muted, fontSize: 10),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ] else
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                'Статистика по темам появится после первого ответа.',
                style: TextStyle(color: muted, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.value, required this.label});
  final String value, label;
  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: ink,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 3),
        Text(label, style: const TextStyle(color: muted, fontSize: 10)),
      ],
    ),
  );
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.icon,
    required this.value,
    required this.caption,
    required this.color,
  });
  final String icon, value, caption;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(icon, style: TextStyle(color: color, fontSize: 19)),
      const SizedBox(width: 11),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Color(0xFFFFFFFF),
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            caption,
            style: const TextStyle(
              color: Color(0xFFB3C1B8),
              fontSize: 10,
              height: 1.3,
            ),
          ),
        ],
      ),
    ],
  );
}

class _BankCard extends StatefulWidget {
  const _BankCard({
    required this.bank,
    required this.progress,
    required this.accent,
    required this.onTap,
    required this.onDownload,
    required this.downloading,
  });
  final QuestionBank bank;
  final LearningProgress progress;
  final Color accent;
  final VoidCallback onTap;
  final VoidCallback onDownload;
  final bool downloading;
  @override
  State<_BankCard> createState() => _BankCardState();
}

class _BankCardState extends State<_BankCard> {
  bool hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => hover = true),
    onExit: (_) => setState(() => hover = false),
    child: GestureDetector(
      onTap: widget.downloading
          ? null
          : widget.bank.downloaded
          ? widget.onTap
          : widget.onDownload,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 330,
        padding: const EdgeInsets.all(19),
        transform: Matrix4.translationValues(0, hover ? -3 : 0, 0),
        decoration: BoxDecoration(
          color: card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: hover ? widget.accent : line,
            width: hover ? 1.4 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(
                0xFF213D2D,
              ).withValues(alpha: hover ? .1 : .035),
              blurRadius: hover ? 22 : 10,
              offset: Offset(0, hover ? 9 : 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 43,
                  height: 43,
                  decoration: BoxDecoration(
                    color: widget.accent.withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Center(
                    child: Text(
                      widget.bank.id.startsWith('golang') ? 'Go' : '✦',
                      style: TextStyle(
                        color: widget.accent == green
                            ? greenDark
                            : const Color(0xFF9B642F),
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                _SmallPill(text: '${widget.bank.categories} тем'),
              ],
            ),
            const SizedBox(height: 17),
            Text(
              widget.bank.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: -.3,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              '${widget.bank.count} вопросов · ${widget.progress.due} к повторению',
              style: const TextStyle(color: muted, fontSize: 11),
            ),
            const SizedBox(height: 17),
            _ProgressBar(
              value: widget.progress.total == 0
                  ? 0
                  : widget.progress.mastered / widget.progress.total,
              color: widget.accent,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Text(
                  '${widget.progress.mastered} / ${widget.bank.count} освоено',
                  style: const TextStyle(color: muted, fontSize: 10),
                ),
                const Spacer(),
                Text(
                  widget.downloading
                      ? 'ЗАГРУЗКА…'
                      : widget.bank.downloaded
                      ? 'НАЧАТЬ'
                      : 'СКАЧАТЬ',
                  style: TextStyle(
                    color: greenDark,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .9,
                  ),
                ),
                const SizedBox(width: 6),
                const Text(
                  '↗',
                  style: TextStyle(color: greenDark, fontSize: 14),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value, this.color = green});
  final double value;
  final Color color;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: SizedBox(
        height: 7,
        child: Stack(
          children: [
            const ColoredBox(color: Color(0xFFEEF1ED)),
            Align(
              alignment: Alignment.centerLeft,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: constraints.maxWidth * value.clamp(0, 1),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SmallPill extends StatelessWidget {
  const _SmallPill({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFFF0F3EF),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: muted,
        fontSize: 10,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(19, 16, 19, 16),
    decoration: BoxDecoration(
      color: const Color(0xFFEAF2EB),
      borderRadius: BorderRadius.circular(16),
    ),
    child: const Row(
      children: [
        Text('✧', style: TextStyle(color: greenDark, fontSize: 22)),
        SizedBox(width: 13),
        Expanded(
          child: Text(
            'Умный ритм: отвечай правильно несколько раз подряд — и вопрос переходит на более длинный интервал. Ошибся? Он вернётся совсем скоро.',
            style: TextStyle(
              color: Color(0xFF3B5848),
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ),
      ],
    ),
  );
}

class QuizScreen extends StatefulWidget {
  const QuizScreen({
    super.key,
    required this.api,
    required this.bank,
    required this.onProgress,
    required this.onExit,
  });
  final StudyStore api;
  final QuestionBank bank;
  final VoidCallback onProgress;
  final VoidCallback onExit;
  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  QuizQuestion? question;
  List<AnswerOption> options = [];
  LearningProgress progress = const LearningProgress();
  String? token, selected;
  String? correctOption;
  bool? wasCorrect;
  bool busy = true;
  bool empty = false;
  String? error;
  int sessionAnswers = 0;
  int sessionCorrect = 0;
  int streak = 0;
  int reviewCount = 0;
  int? nextDueAt;

  @override
  void initState() {
    super.initState();
    _next();
  }

  Future<void> _next() async {
    setState(() {
      busy = true;
      error = null;
      wasCorrect = null;
      selected = null;
      correctOption = null;
    });
    try {
      final data = Map<String, dynamic>.from(
        await widget.api.get(
          '/next?bank=${Uri.encodeQueryComponent(widget.bank.id)}',
        ),
      );
      if (!mounted) return;
      final rawProgress = data['progress'];
      if (rawProgress is Map) {
        progress = LearningProgress.fromJson(
          Map<String, dynamic>.from(rawProgress),
        );
      }
      if (data['empty'] == true) {
        setState(() {
          empty = true;
          busy = false;
          nextDueAt = data['next_due_at'] as int?;
        });
      } else {
        setState(() {
          empty = false;
          question = QuizQuestion.fromJson(
            Map<String, dynamic>.from(data['question']),
          );
          options = (data['options'] as List)
              .map((e) => AnswerOption.fromJson(Map<String, dynamic>.from(e)))
              .toList();
          token = data['token'] as String;
          streak = data['streak'] as int? ?? 0;
          reviewCount = data['reviews'] as int? ?? 0;
          busy = false;
        });
      }
      widget.onProgress();
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<void> _check() async {
    if (selected == null || token == null || busy) return;
    setState(() => busy = true);
    try {
      final result = Map<String, dynamic>.from(
        await widget.api.post('/answer', {
          'bank_id': widget.bank.id,
          'token': token,
          'option_id': selected,
        }),
      );
      if (!mounted) return;
      final correct = result['correct'] as bool;
      setState(() {
        wasCorrect = correct;
        correctOption = result['correct_option_id'] as String;
        streak = result['streak'] as int;
        reviewCount = result['review_count'] as int;
        busy = false;
        sessionAnswers++;
        if (correct) sessionCorrect++;
      });
      widget.onProgress();
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(35, 23, 38, 17),
        child: Row(
          children: [
            _TextAction(label: '←  К программе', onTap: widget.onExit),
            const Spacer(),
            Text(
              widget.bank.title,
              style: const TextStyle(
                color: muted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 15),
            _SmallPill(
              text: 'Раунд ${sessionAnswers + (wasCorrect == null ? 1 : 0)}',
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 38),
        child: _ProgressBar(
          value: progress.total == 0 ? 0 : progress.mastered / progress.total,
          color: greenDark,
        ),
      ),
      Expanded(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: _quizBody(),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _quizBody() {
    if (busy && question == null && !empty) return const _LoadingState();
    if (error != null && question == null) {
      return _ErrorCard(message: error!, onRetry: _next);
    }
    if (empty) {
      return _EmptySession(
        nextDueAt: nextDueAt,
        answered: sessionAnswers,
        correct: sessionCorrect,
        onExit: widget.onExit,
        onRefresh: _next,
      );
    }
    if (question == null) return const _LoadingState();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0xFFE0F2E7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Center(
                child: Text(
                  '✦',
                  style: TextStyle(color: greenDark, fontSize: 18),
                ),
              ),
            ),
            const SizedBox(width: 11),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  question!.category.toUpperCase(),
                  style: const TextStyle(
                    color: greenDark,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.3,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Повторение №${reviewCount + 1}',
                  style: const TextStyle(color: muted, fontSize: 10),
                ),
              ],
            ),
            const Spacer(),
            if (streak > 0) _SmallPill(text: 'Серия $streak / 3'),
          ],
        ),
        const SizedBox(height: 19),
        Text(
          question!.text,
          style: const TextStyle(
            color: ink,
            fontSize: 25,
            height: 1.26,
            fontWeight: FontWeight.w800,
            letterSpacing: -.65,
          ),
        ),
        const SizedBox(height: 7),
        const Text(
          'Выбери самый точный ответ',
          style: TextStyle(color: muted, fontSize: 12),
        ),
        const SizedBox(height: 22),
        for (var i = 0; i < options.length; i++) ...[
          _OptionTile(
            index: i,
            option: options[i],
            selected: selected == options[i].id,
            revealed: wasCorrect != null,
            correct: options[i].id == correctOption,
            onTap: wasCorrect == null && !busy
                ? () => setState(() => selected = options[i].id)
                : null,
          ),
          if (i != options.length - 1) const SizedBox(height: 9),
        ],
        const SizedBox(height: 16),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              error!,
              style: const TextStyle(color: red, fontSize: 12),
            ),
          ),
        if (wasCorrect != null)
          _AnswerFeedback(
            correct: wasCorrect!,
            explanation: question!.answer,
            sources: question!.sources,
            streak: streak,
          ),
        const SizedBox(height: 14),
        Row(
          children: [
            Text(
              '${progress.mastered} освоено · ${progress.due} ждут',
              style: const TextStyle(color: muted, fontSize: 10),
            ),
            const Spacer(),
            _ActionButton(
              label: wasCorrect == null ? 'Проверить ответ' : 'Дальше  →',
              enabled: wasCorrect != null || selected != null,
              loading: busy,
              onTap: wasCorrect == null ? _check : _next,
            ),
          ],
        ),
      ],
    );
  }
}

class _OptionTile extends StatefulWidget {
  const _OptionTile({
    required this.index,
    required this.option,
    required this.selected,
    required this.revealed,
    required this.correct,
    required this.onTap,
  });
  final int index;
  final AnswerOption option;
  final bool selected, revealed, correct;
  final VoidCallback? onTap;
  @override
  State<_OptionTile> createState() => _OptionTileState();
}

class _OptionTileState extends State<_OptionTile> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final success = widget.revealed && widget.correct;
    final fail = widget.revealed && widget.selected && !widget.correct;
    final active = widget.selected && !widget.revealed;
    final border = success
        ? greenDark
        : fail
        ? red
        : active
        ? greenDark
        : hover && widget.onTap != null
        ? const Color(0xFFB8C9BD)
        : line;
    return MouseRegion(
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
          decoration: BoxDecoration(
            color: success
                ? const Color(0xFFEAF7EF)
                : fail
                ? const Color(0xFFFFEFED)
                : active
                ? const Color(0xFFEDF6EF)
                : card,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: border,
              width: active || success || fail ? 1.5 : 1,
            ),
            boxShadow: [
              if (hover && widget.onTap != null)
                const BoxShadow(
                  color: Color(0x0C10251A),
                  blurRadius: 9,
                  offset: Offset(0, 3),
                ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 24,
                height: 24,
                margin: const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(
                  color: success
                      ? greenDark
                      : fail
                      ? red
                      : active
                      ? greenDark
                      : const Color(0xFFF2F4F1),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    String.fromCharCode(65 + widget.index),
                    style: TextStyle(
                      color: success || fail || active
                          ? const Color(0xFFFFFFFF)
                          : muted,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.option.text,
                  style: TextStyle(
                    color: ink,
                    fontSize: 12,
                    height: 1.45,
                    fontWeight: active || success
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ),
              if (success)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Text(
                    '✓',
                    style: TextStyle(
                      color: greenDark,
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                ),
              if (fail)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Text(
                    '×',
                    style: TextStyle(
                      color: red,
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
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

class _AnswerFeedback extends StatelessWidget {
  const _AnswerFeedback({
    required this.correct,
    required this.explanation,
    required this.sources,
    required this.streak,
  });
  final bool correct;
  final String explanation;
  final List<String> sources;
  final int streak;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: correct ? const Color(0xFFEAF7EF) : const Color(0xFFFFF2E8),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: correct ? const Color(0xFFCDE8D6) : const Color(0xFFF5D9C3),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              correct ? 'Именно так!' : 'Пока не совсем',
              style: TextStyle(
                color: correct ? greenDark : const Color(0xFF9E5D2D),
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
            const Spacer(),
            if (correct)
              Text(
                streak >= 3
                    ? 'ОТЛИЧНО · ИНТЕРВАЛ УВЕЛИЧЕН'
                    : '$streak / 3 верных подряд',
                style: const TextStyle(
                  color: greenDark,
                  fontSize: 9,
                  letterSpacing: .5,
                  fontWeight: FontWeight.w800,
                ),
              ),
          ],
        ),
        const SizedBox(height: 7),
        Text(
          explanation,
          style: const TextStyle(color: ink, fontSize: 11, height: 1.5),
        ),
        if (sources.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 9),
            child: Wrap(
              spacing: 12,
              runSpacing: 5,
              children: [
                for (var i = 0; i < sources.length; i++)
                  _TextAction(
                    label: 'Изучить источник ${i + 1} ↗',
                    onTap: () => Process.run('open', [sources[i]]),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _EmptySession extends StatelessWidget {
  const _EmptySession({
    required this.nextDueAt,
    required this.answered,
    required this.correct,
    required this.onExit,
    required this.onRefresh,
  });
  final int? nextDueAt;
  final int answered, correct;
  final VoidCallback onExit, onRefresh;
  @override
  Widget build(BuildContext context) {
    final when = nextDueAt == null || nextDueAt == 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(nextDueAt! * 1000).toLocal();
    final next = when == null
        ? 'Все доступные вопросы на сегодня разобраны.'
        : 'Следующее повторение: ${when.day}.${when.month.toString().padLeft(2, '0')} в ${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}.';
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('✦', style: TextStyle(color: greenDark, fontSize: 30)),
          const SizedBox(height: 16),
          const Text(
            'Отличный раунд!',
            style: TextStyle(
              color: ink,
              fontSize: 28,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 9),
          Text(
            '$answered ответов · $correct правильных',
            style: const TextStyle(color: muted, fontSize: 13),
          ),
          const SizedBox(height: 19),
          Text(next, style: const TextStyle(color: ink, fontSize: 13)),
          const SizedBox(height: 23),
          Row(
            children: [
              _ActionButton(label: 'На главную', enabled: true, onTap: onExit),
              const SizedBox(width: 10),
              _TextAction(label: 'Проверить снова', onTap: onRefresh),
            ],
          ),
        ],
      ),
    );
  }
}

class _ConnectionState extends StatelessWidget {
  const _ConnectionState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: _ErrorCard(
      message:
          '$message\n\nПроверь подключение к каталогу блоков и попробуй снова.',
      onRetry: onRetry,
    ),
  );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Container(
    width: 520,
    padding: const EdgeInsets.all(28),
    decoration: BoxDecoration(
      color: card,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Не удалось загрузить базы вопросов',
          style: TextStyle(
            color: ink,
            fontSize: 23,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          message,
          style: const TextStyle(color: muted, fontSize: 12, height: 1.6),
        ),
        const SizedBox(height: 18),
        _ActionButton(
          label: 'Попробовать снова',
          enabled: true,
          onTap: onRetry,
        ),
      ],
    ),
  );
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();
  @override
  Widget build(BuildContext context) => const Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('✦', style: TextStyle(color: greenDark, fontSize: 29)),
      SizedBox(height: 8),
      Text(
        'Загружаю следующую карточку…',
        style: TextStyle(color: muted, fontSize: 11),
      ),
    ],
  );
}

class _ActionButton extends StatefulWidget {
  const _ActionButton({
    required this.label,
    required this.enabled,
    required this.onTap,
    this.loading = false,
  });
  final String label;
  final bool enabled;
  final bool loading;
  final VoidCallback onTap;
  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.enabled
        ? SystemMouseCursors.click
        : SystemMouseCursors.basic,
    onEnter: (_) => setState(() => hover = true),
    onExit: (_) => setState(() => hover = false),
    child: GestureDetector(
      onTap: widget.enabled && !widget.loading ? widget.onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        decoration: BoxDecoration(
          color: widget.enabled
              ? (hover ? const Color(0xFF32B982) : greenDark)
              : const Color(0xFFD5DDD7),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            if (widget.enabled)
              const BoxShadow(
                color: Color(0x1A145E3D),
                blurRadius: 9,
                offset: Offset(0, 3),
              ),
          ],
        ),
        child: Text(
          widget.loading ? 'Подожди…' : widget.label,
          style: const TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: .2,
          ),
        ),
      ),
    ),
  );
}

class _TextAction extends StatefulWidget {
  const _TextAction({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  State<_TextAction> createState() => _TextActionState();
}

class _TextActionState extends State<_TextAction> {
  bool hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => hover = true),
    onExit: (_) => setState(() => hover = false),
    child: GestureDetector(
      onTap: widget.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          widget.label,
          style: TextStyle(
            color: hover ? greenDark : muted,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ),
  );
}

String _plural(int n, String one, String few, String many) {
  final n100 = n % 100, n10 = n % 10;
  if (n100 >= 11 && n100 <= 14) return many;
  if (n10 == 1) return one;
  if (n10 >= 2 && n10 <= 4) return few;
  return many;
}
