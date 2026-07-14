import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum VesperPhase { idle, search, split, merge, reveal }

// --- КЛАСС ДЛЯ ТЕРМИНАЛА (РЕЗУЛЬТАТЫ ВЫПОЛНЕНИЯ КОДА) ---
class RunResult {
  final bool isRunning;
  final String stdout;
  final String stderr;
  final int exitCode;

  RunResult({
    this.isRunning = false,
    this.stdout = '',
    this.stderr = '',
    this.exitCode = 0,
  });
}

// Заглушка для пункта меню в Drawer.
class ChatSummary {
  final String id;
  final String title;

  const ChatSummary({required this.id, required this.title});
}

// Справочник доступных моделей для UI-селектора.
class VesperModel {
  final String key;
  final String label;
  final String description; // <-- Вот переменная, которой не хватало компилятору!

  // <-- И вот обновленный конструктор, который её принимает
  const VesperModel({required this.key, required this.label, required this.description});

  static const List<VesperModel> all = [
    VesperModel(
      key: 'spark',
      label: 'Vesper Spark',
      description: 'Быстрая и лёгкая, хорошо подходит для ролинга'
    ),
    VesperModel(
      key: 'nova',
      label: 'Vesper Nova',
      description: 'Сбалансированная и умная'
    ),
    VesperModel(
      key: 'zenith',
      label: 'Vesper Zenith',
      description: 'Сверхбыстрая, отлично пишет код, одна из самых умных'
    ),
    VesperModel(
      key: 'quantum',
      label: 'Vesper Quantum',
      description: 'Максимально умная и сильная для сложных задач'
    ),
  ];

  static VesperModel byKey(String key) =>
  all.firstWhere((m) => m.key == key, orElse: () => all[1]);
}

class ChatState {
  final List<Map<String, String>> messages;
  final VesperPhase phase;
  final String statusText;
  final bool isThinking;
  final double detailLevel;
  final String currentSessionId;
  final List<ChatSummary> availableChats;
  final String selectedModel;

  // ДОБАВЛЕНО: Словарь для хранения состояний терминала артефактов
  final Map<String, RunResult> runResults;

  const ChatState({
    this.messages = const [],
    this.phase = VesperPhase.idle,
    this.statusText = "",
    this.isThinking = false,
    this.detailLevel = 0.5,
    this.currentSessionId = 'session_1',
    this.availableChats = const [
      ChatSummary(id: 'session_1', title: 'Новый чат'),
    ],
    this.selectedModel = 'nova',
    this.runResults = const {},
  });

  ChatState copyWith({
    List<Map<String, String>>? messages,
    VesperPhase? phase,
    String? statusText,
    bool? isThinking,
    double? detailLevel,
    String? currentSessionId,
    List<ChatSummary>? availableChats,
    String? selectedModel,
    Map<String, RunResult>? runResults,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      phase: phase ?? this.phase,
      statusText: statusText ?? this.statusText,
      isThinking: isThinking ?? this.isThinking,
      detailLevel: detailLevel ?? this.detailLevel,
      currentSessionId: currentSessionId ?? this.currentSessionId,
      availableChats: availableChats ?? this.availableChats,
      selectedModel: selectedModel ?? this.selectedModel,
      runResults: runResults ?? this.runResults,
    );
  }
}

class ChatNotifier extends Notifier<ChatState> {
  WebSocketChannel? _channel;

  static const String _defaultSessionId = 'session_1';

  @override
  ChatState build() {
    _connectWebSocket(_defaultSessionId);
    ref.onDispose(() => _channel?.sink.close());
    return const ChatState(currentSessionId: _defaultSessionId);
  }

  void _connectWebSocket(String sessionId) {
    final wsUrl = Uri.parse('ws://127.0.0.1:8000/ws/chat/$sessionId');
    _channel = WebSocketChannel.connect(wsUrl);

    _channel!.stream.listen(
      (message) {
        final data = jsonDecode(message);
        final type = data['type'];

        if (type == 'phase') {
          final phaseStr = data['value'];
          final status = data['status'] ?? '';

    VesperPhase newPhase = VesperPhase.idle;
    if (phaseStr == 'search') newPhase = VesperPhase.search;
    else if (phaseStr == 'split') newPhase = VesperPhase.split;
    else if (phaseStr == 'merge') newPhase = VesperPhase.merge;
    else if (phaseStr == 'reveal') newPhase = VesperPhase.reveal;

    setPhase(newPhase, status);

        } else if (type == 'history') {
          final historyList = data['messages'] as List;
          final loadedMessages = historyList.map<Map<String, String>>((m) => {
            'role': m['role'] == 'user' ? 'User' : 'Vesper',
            'text': m['content'].toString()
          }).toList();
          state = state.copyWith(messages: loadedMessages);

        } else if (type == 'token') {
          appendToLastMessage(data['value']);

        } else if (type == 'done') {
          setPhase(VesperPhase.idle, "");

        } else if (type == 'rename_chat') {
          print("🔄 Бэкенд переименовал чат в: ${data['title']}");

          // ДОБАВЛЕНО: Перехват ответа от терминала бэкенда
        } else if (type == 'run_result') {
          final artifactId = data['artifact_id'];
          if (artifactId != null) {
            final updatedResults = Map<String, RunResult>.from(state.runResults);
            updatedResults[artifactId] = RunResult(
              isRunning: false,
              stdout: data['stdout'] ?? '',
              stderr: data['stderr'] ?? '',
              exitCode: data['exit_code'] ?? 0,
            );
            state = state.copyWith(runResults: updatedResults);
          }
        }
      },
      onError: (error) {
        print("❌ Ошибка WebSocket: $error");
        setPhase(VesperPhase.idle, "");
      },
      onDone: () {
        print("🔌 WebSocket отключен");
        setPhase(VesperPhase.idle, "");
      },
    );
  }

  void sendMessage(String text) {
    if (text.trim().isEmpty) return;

    addMessage('User', text);
    addMessage('Vesper', '');

    try {
      if (_channel != null) {
        _channel!.sink.add(jsonEncode({
          "text": text,
          "model": state.selectedModel,
        }));
      }
    } catch (e) {
      print("❌ Ошибка отправки: $e");
      appendToLastMessage("\n\n*[Соединение с сервером разорвано. Нажмите R в терминале для переподключения]*");
      setPhase(VesperPhase.idle);
    }
  }

  // ДОБАВЛЕНО: Функция для отправки кода на выполнение серверу
  void runCode(String code, String artifactId) {
    // Включаем статус загрузки (показываем спиннер в терминале)
    final updatedResults = Map<String, RunResult>.from(state.runResults);
    updatedResults[artifactId] = RunResult(isRunning: true);
    state = state.copyWith(runResults: updatedResults);

    try {
      if (_channel != null) {
        _channel!.sink.add(jsonEncode({
          "type": "run_code",
          "code": code,
          "artifact_id": artifactId,
        }));
      }
    } catch (e) {
      print("❌ Ошибка запуска кода: $e");
      final failedResults = Map<String, RunResult>.from(state.runResults);
      failedResults[artifactId] = RunResult(
        isRunning: false,
        stderr: "Ошибка отправки на сервер: $e",
        exitCode: -1,
      );
      state = state.copyWith(runResults: failedResults);
    }
  }

  void addMessage(String role, String text) {
    state = state.copyWith(
      messages: [...state.messages, {'role': role, 'text': text}],
    );
  }

  void appendToLastMessage(String chunk) {
    if (state.messages.isEmpty) return;
    final messages = List<Map<String, String>>.from(state.messages);
    final lastIndex = messages.length - 1;
    final lastMsg = messages[lastIndex];

    messages[lastIndex] = {
      'role': lastMsg['role']!,
      'text': (lastMsg['text'] ?? '') + chunk,
    };
    state = state.copyWith(messages: messages);
  }

  void setPhase(VesperPhase phase, [String statusText = ""]) {
    state = state.copyWith(phase: phase, statusText: statusText);
  }

  void toggleThinking(bool value) {
    state = state.copyWith(isThinking: value);
  }

  void setDetailLevel(double value) {
    state = state.copyWith(detailLevel: value);
  }

  void setModel(String modelKey) {
    state = state.copyWith(selectedModel: modelKey);
  }

  void _switchToSession(String sessionId) {
    _channel?.sink.close();
    state = state.copyWith(
      currentSessionId: sessionId,
      messages: [],
      phase: VesperPhase.idle,
      statusText: "",
    );
    _connectWebSocket(sessionId);
  }

  void switchChat(String chatId) {
    if (chatId == state.currentSessionId) return;
    final exists = state.availableChats.any((c) => c.id == chatId);
    if (!exists) {
      print("⚠️ Попытка переключиться на неизвестный chatId: $chatId");
      return;
    }
    _switchToSession(chatId);
  }

  void createNewChat() {
    final newId = 'session_${DateTime.now().millisecondsSinceEpoch}';
    final newChat = ChatSummary(id: newId, title: 'Новый чат');

    state = state.copyWith(
      availableChats: [...state.availableChats, newChat],
    );
    _switchToSession(newId);
  }

  Future<void> simulateStreamingResponse(String fullText) async {
    addMessage('Vesper', '');
    for (int i = 0; i < fullText.length; i++) {
      await Future.delayed(const Duration(milliseconds: 15));
      appendToLastMessage(fullText[i]);
    }
  }
}

final chatProvider = NotifierProvider<ChatNotifier, ChatState>(ChatNotifier.new);
