import 'dart:io';
import 'dart:ui' show FragmentShader, FragmentProgram, ImageFilter;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/scheduler.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_highlighter/flutter_highlighter.dart';
import 'package:flutter_highlighter/themes/atom-one-dark.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import 'providers.dart';

// ─────────────────────────────────────────────────────────────────────────
// PALETTE
// ─────────────────────────────────────────────────────────────────────────

class VesperColors {
  VesperColors._();

  static const bg = Color(0xFF0D0D12);
  static const surface = Color(0xFF1A1A24);
  static const surfaceHigh = Color(0xFF20202C);
  static const indigo = Color(0xFF4B0082);
  static const indigoBright = Color(0xFF8A5CF6);

  // Границы: тише, чем раньше (8% вместо 10%) — поверхности меньше «шумят»
  static const border = Color(0x14FFFFFF); // white @ 8%
  static const borderFaint = Color(0x0DFFFFFF); // white @ 5%
  static const borderStrong = Color(0x33FFFFFF); // white @ 20%
  static const glassEdgeTop = Color(0x26FFFFFF); // white @ 15% — «блик» кромки

  static const codeBg = Color(0xFF111118);

  static const textPrimary = Color(0xFFF5F5F7);
  static const textSecondary = Color(0xFFA0A0AE);
  static const textFaint = Color(0xFF6B6B78);
}

// Единая мера читаемой колонки (как у ChatGPT/Claude: ~65–75 символов)
const double kContentMaxWidth = 768;

/// Крошечный цветовой акцент каждой модели — используется ТОЛЬКО
/// внутри меню селектора (единственное место, где допустимо больше цвета).
Color _modelAccent(String key) {
  switch (key) {
    case 'spark':
      return const Color(0xFFF59E0B); // янтарный — быстрая
    case 'nova':
      return VesperColors.indigoBright; // индиго — базовая
    case 'zenith':
      return const Color(0xFF22D3EE); // циан — код
    case 'quantum':
      return const Color(0xFFF472B6); // розовый — максимум
    default:
      return VesperColors.indigoBright;
  }
}

/// Плавное появление нового сообщения: fade + подъём на 8px.
class _Appear extends StatelessWidget {
  final Widget child;
  const _Appear({required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - v)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// SCREEN
// ─────────────────────────────────────────────────────────────────────────

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with TickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  FragmentShader? _shader;
  late final Ticker _ticker;

  // Время шейдера через ValueNotifier — перерисовывается ТОЛЬКО индикатор,
  // а не весь экран на каждый кадр.
  final ValueNotifier<double> _time = ValueNotifier(0.0);
  Duration _lastElapsed = Duration.zero;

  // Кнопка «вниз»: появляется, когда пользователь отскроллил вверх
  bool _showScrollFab = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _loadShader();
    // Перерисовка контейнера инпута при фокусе (focus ring)
    _focusNode.addListener(() => setState(() {}));
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final distance = _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    final show = distance > 300;
    if (show != _showScrollFab) {
      setState(() => _showScrollFab = show);
    }
  }

  Future<void> _loadShader() async {
    try {
      final program =
          await FragmentProgram.fromAsset('shaders/metaballs.frag');
      if (!mounted) return;
      setState(() {
        _shader = program.fragmentShader();
      });
    } catch (_) {}
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    _time.value += dt; // без setState — экран не перестраивается
  }

  void _syncTicker(bool shouldRun) {
    if (shouldRun && !_ticker.isActive) {
      _lastElapsed = Duration.zero;
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
    }
  }

  double _phaseToDouble(VesperPhase phase) {
    switch (phase) {
      case VesperPhase.idle:
        return 0.0;
      case VesperPhase.search:
        return 1.0;
      case VesperPhase.split:
        return 2.0;
      case VesperPhase.merge:
        return 3.0;
      case VesperPhase.reveal:
        return 4.0;
    }
  }

  void _sendMessage() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    ref.read(chatProvider.notifier).sendMessage(text);
    _controller.clear();
    _focusNode.unfocus();
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatProvider);
    final showIndicator =
        state.phase != VesperPhase.idle && state.phase != VesperPhase.reveal;

    // Тикер работает пока виден индикатор ИЛИ пустой экран
    // (там медленно «дышит» метаболл-орб) — в остальное время CPU свободен
    _syncTicker(showIndicator || state.messages.isEmpty);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 600;

        return Scaffold(
          backgroundColor: VesperColors.bg,
          drawer: const _VesperDrawer(),
          body: SafeArea(
            child: Column(
              children: [
                _buildTopBar(state, isWide),
                Expanded(
                  child: state.messages.isEmpty
                      ? _buildEmptyState()
                      : _buildMessageList(state),
                ),
                _ThinkingIndicator(
                  visible: showIndicator,
                  shader: _shader,
                  time: _time,
                  phase: _phaseToDouble(state.phase),
                ),
                _buildInputArea(state, isWide),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopBar(ChatState state, bool isWide) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 12, 4),
      child: Row(
        children: [
          Builder(
            builder: (context) => IconButton(
              splashRadius: 20,
              icon: const Icon(Icons.menu_rounded,
                  color: VesperColors.textSecondary, size: 22),
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          ),
          const SizedBox(width: 4),
          // Логотип: плоский, без свечения — тихий бренд, как у Claude
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: VesperColors.surfaceHigh,
              border: Border.all(
                color: VesperColors.indigoBright.withOpacity(0.35),
              ),
            ),
            child: const Icon(Icons.auto_awesome,
                size: 15, color: VesperColors.indigoBright),
          ),
          const SizedBox(width: 10),
          if (isWide)
            const Text(
              'Vesper',
              style: TextStyle(
                color: VesperColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.1,
              ),
            )
          else
            const Spacer(),
          if (!isWide)
            _ModelSelector(
              selectedKey: state.selectedModel,
              compact: true,
              onChanged: (key) =>
                  ref.read(chatProvider.notifier).setModel(key),
            ),
          const Spacer(),
          IconButton(
            splashRadius: 20,
            icon: const Icon(Icons.tune_rounded,
                color: VesperColors.textSecondary, size: 20),
            onPressed: _openSettingsSheet,
          ),
        ],
      ),
    );
  }

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour >= 5 && hour < 12) return 'Доброе утро';
    if (hour >= 12 && hour < 18) return 'Добрый день';
    if (hour >= 18 && hour < 23) return 'Добрый вечер';
    return 'Доброй ночи';
  }

  static const _suggestions = [
    'Объясни квантовую запутанность просто',
    'Напиши скрипт на Python',
    'Придумай идеи для проекта',
    'Помоги с код-ревью',
  ];

  void _sendSuggestion(String text) {
    _controller.text = text;
    _sendMessage();
  }

  Widget _buildEmptyState() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Живой метаболл-орб вместо статичной иконки:
            // тот же шейдер, что и в индикаторе — единый язык бренда
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: VesperColors.surface,
                border: Border.all(color: VesperColors.border),
                boxShadow: [
                  BoxShadow(
                    color: VesperColors.indigoBright.withOpacity(0.15),
                    blurRadius: 32,
                    spreadRadius: -4,
                  ),
                ],
              ),
              child: _shader != null
                  ? ValueListenableBuilder<double>(
                      valueListenable: _time,
                      builder: (context, t, _) => ClipOval(
                        child: CustomPaint(
                          painter: MetaballsPainter(
                            shader: _shader!,
                            // Замедляем в idle: орб «дышит», а не работает
                            time: t * 0.4,
                            phase: 0.0,
                          ),
                        ),
                      ),
                    )
                  : const Icon(Icons.auto_awesome,
                      color: VesperColors.indigoBright, size: 26),
            ),
            const SizedBox(height: 24),
            Text(
              _greeting,
              style: const TextStyle(
                color: VesperColors.textPrimary,
                fontSize: 24,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.4,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Спросите что угодно — Vesper подберёт эксперта',
              style: TextStyle(
                color: VesperColors.textFaint,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 28),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in _suggestions)
                  _SuggestionChip(
                    label: s,
                    onTap: () => _sendSuggestion(s),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageList(ChatState state) {
    final isBusy = state.phase != VesperPhase.idle;

    return Stack(
      children: [
        ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          itemCount: state.messages.length,
          itemBuilder: (context, index) {
            final msg = state.messages[index];
            final isUser = msg['role'] == 'User';
            final isLast = index == state.messages.length - 1;

            Widget bubble = _MessageBubble(
              text: msg['text'] ?? '',
              isUser: isUser,
              // Пульсирующий курсор — только у последнего ответа во время стрима
              isStreaming: isLast && !isUser && isBusy,
              // Панель действий — только под завершённым последним ответом
              showActions: isLast && !isUser && !isBusy,
            );

            // Fade-in + подъём только для последнего сообщения —
            // история при скролле не анимируется
            if (isLast) bubble = _Appear(child: bubble);

            // Центральная колонка: как у всех топовых чатов
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: kContentMaxWidth),
                child: bubble,
              ),
            );
          },
        ),
        // Кнопка «вниз» — обязательна для стриминга в длинном чате
        Positioned(
          right: 16,
          bottom: 12,
          child: AnimatedScale(
            scale: _showScrollFab ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: Material(
              color: VesperColors.surfaceHigh,
              shape: const CircleBorder(
                side: BorderSide(color: VesperColors.border),
              ),
              elevation: 4,
              shadowColor: Colors.black.withOpacity(0.4),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _scrollToBottom,
                child: const SizedBox(
                  width: 36,
                  height: 36,
                  child: Icon(Icons.arrow_downward_rounded,
                      size: 18, color: VesperColors.textSecondary),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInputArea(ChatState state, bool isWide) {
    final hasFocus = _focusNode.hasFocus;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kContentMaxWidth),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                splashRadius: 20,
                icon: Icon(
                  state.isThinking
                      ? Icons.psychology_alt_rounded
                      : Icons.psychology_alt_outlined,
                  size: 20,
                  color: state.isThinking
                      ? VesperColors.indigoBright
                      : VesperColors.textFaint,
                ),
                tooltip: 'Режим размышления',
                onPressed: () => ref
                    .read(chatProvider.notifier)
                    .toggleThinking(!state.isThinking),
              ),
              if (isWide) ...[
                _ModelSelector(
                  selectedKey: state.selectedModel,
                  compact: false,
                  onChanged: (key) =>
                      ref.read(chatProvider.notifier).setModel(key),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                // Focus ring: бордер и мягкое свечение при фокусе — как в вебе
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  constraints:
                      const BoxConstraints(minHeight: 46, maxHeight: 140),
                  decoration: BoxDecoration(
                    color: VesperColors.surface,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: hasFocus
                          ? VesperColors.indigoBright.withOpacity(0.4)
                          : VesperColors.border,
                      width: 1,
                    ),
                    boxShadow: hasFocus
                        ? [
                            BoxShadow(
                              color:
                                  VesperColors.indigoBright.withOpacity(0.12),
                              blurRadius: 20,
                              spreadRadius: -6,
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(
                              left: 18, right: 4, top: 12, bottom: 12),
                          child: TextField(
                            controller: _controller,
                            focusNode: _focusNode,
                            minLines: 1,
                            maxLines: 6,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _sendMessage(),
                            style: const TextStyle(
                              color: VesperColors.textPrimary,
                              fontSize: 15,
                              height: 1.5,
                            ),
                            cursorColor: VesperColors.indigoBright,
                            decoration: const InputDecoration(
                              isCollapsed: true,
                              border: InputBorder.none,
                              hintText: 'Напишите Vesper…',
                              hintStyle: TextStyle(
                                color: VesperColors.textFaint,
                                fontSize: 15,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(right: 5, bottom: 5),
                        child: _SendButton(onTap: _sendMessage),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openSettingsSheet() {
    final state = ref.read(chatProvider);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _SettingsSheet(
        initialThinking: state.isThinking,
        initialDetail: state.detailLevel,
        onThinkingChanged: (v) =>
            ref.read(chatProvider.notifier).toggleThinking(v),
        onDetailChanged: (v) =>
            ref.read(chatProvider.notifier).setDetailLevel(v),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// SUGGESTION CHIP — подсказка на пустом экране
// ─────────────────────────────────────────────────────────────────────────

class _SuggestionChip extends StatefulWidget {
  final String label;
  final VoidCallback onTap;

  const _SuggestionChip({required this.label, required this.onTap});

  @override
  State<_SuggestionChip> createState() => _SuggestionChipState();
}

class _SuggestionChipState extends State<_SuggestionChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: _hovered
                  ? VesperColors.surfaceHigh
                  : VesperColors.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: _hovered
                    ? VesperColors.indigoBright.withOpacity(0.30)
                    : VesperColors.border,
              ),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                color: _hovered
                    ? VesperColors.textPrimary
                    : VesperColors.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// MESSAGE BUBBLE
//
// Пользователь — тихий плоский пузырь справа.
// Ассистент — БЕЗ пузыря: чистый текст на фоне (как ChatGPT/Claude).
// Это убирает дорогой BackdropFilter из каждого сообщения.
// ─────────────────────────────────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final String text;
  final bool isUser;
  final bool isStreaming;
  final bool showActions;

  const _MessageBubble({
    required this.text,
    required this.isUser,
    this.isStreaming = false,
    this.showActions = false,
  });

  @override
  Widget build(BuildContext context) {
    if (isUser) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Flexible(
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.78,
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                decoration: BoxDecoration(
                  // Плоско и тихо: surfaceHigh + лёгкий индиго-намёк.
                  // Никаких теней и градиентов — акцент остаётся на ответе AI.
                  color: Color.alphaBlend(
                    VesperColors.indigoBright.withOpacity(0.10),
                    VesperColors.surfaceHigh,
                  ),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(20),
                    topRight: Radius.circular(20),
                    bottomLeft: Radius.circular(20),
                    bottomRight: Radius.circular(6),
                  ),
                  border: Border.all(color: VesperColors.borderFaint),
                ),
                child: _MessageContent(
                  text: text,
                  baseColor: VesperColors.textPrimary,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Ответ ассистента: аватар + текст без контейнера
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: VesperColors.surfaceHigh,
              border: Border.all(
                color: VesperColors.indigoBright.withOpacity(0.35),
              ),
            ),
            child: const Icon(
              Icons.auto_awesome,
              size: 13,
              color: VesperColors.indigoBright,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _MessageContent(
                    text: text,
                    baseColor: VesperColors.textPrimary,
                    fontSize: 15,
                  ),
                  // Пульсирующий курсор — «AI ещё пишет»
                  if (isStreaming)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: _StreamingCursor(),
                    ),
                  // Действия под завершённым ответом (fade-in)
                  if (showActions && text.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: _Appear(child: _MessageActions(text: text)),
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

/// Пульсирующая индиго-точка в конце стримящегося ответа.
class _StreamingCursor extends StatefulWidget {
  const _StreamingCursor();

  @override
  State<_StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<_StreamingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(
        CurvedAnimation(parent: _c, curve: Curves.easeInOut),
      ),
      child: Container(
        width: 9,
        height: 9,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: VesperColors.indigoBright,
        ),
      ),
    );
  }
}

/// Панель действий под последним ответом: копировать / оценка.
/// Стандарт индустрии — тихие иконки 16px, заметные только при наведении.
class _MessageActions extends StatefulWidget {
  final String text;
  const _MessageActions({required this.text});

  @override
  State<_MessageActions> createState() => _MessageActionsState();
}

class _MessageActionsState extends State<_MessageActions> {
  bool _copied = false;
  int _rating = 0; // 0 — нет, 1 — нравится, -1 — не нравится

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ActionIcon(
          icon: _copied ? Icons.check_rounded : Icons.copy_rounded,
          tooltip: _copied ? 'Скопировано' : 'Копировать',
          active: _copied,
          onTap: _copy,
        ),
        const SizedBox(width: 2),
        _ActionIcon(
          icon: _rating == 1
              ? Icons.thumb_up_alt_rounded
              : Icons.thumb_up_alt_outlined,
          tooltip: 'Хороший ответ',
          active: _rating == 1,
          onTap: () => setState(() => _rating = _rating == 1 ? 0 : 1),
        ),
        const SizedBox(width: 2),
        _ActionIcon(
          icon: _rating == -1
              ? Icons.thumb_down_alt_rounded
              : Icons.thumb_down_alt_outlined,
          tooltip: 'Плохой ответ',
          active: _rating == -1,
          onTap: () => setState(() => _rating = _rating == -1 ? 0 : -1),
        ),
      ],
    );
  }
}

class _ActionIcon extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  const _ActionIcon({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onTap,
  });

  @override
  State<_ActionIcon> createState() => _ActionIconState();
}

class _ActionIconState extends State<_ActionIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.active
        ? VesperColors.indigoBright
        : _hovered
            ? VesperColors.textSecondary
            : VesperColors.textFaint;

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(7),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(widget.icon, size: 16, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// CONTENT SEGMENTS
// ─────────────────────────────────────────────────────────────────────────

enum _SegmentKind { text, artifact, thinking }

class _ContentSegment {
  final _SegmentKind kind;
  final String text;
  final String? artifactTitle;
  final String? artifactType;
  final String? artifactCode;
  final String? thinkingText;
  final bool thinkingStreaming;

  const _ContentSegment.text(this.text)
      : kind = _SegmentKind.text,
        artifactTitle = null,
        artifactType = null,
        artifactCode = null,
        thinkingText = null,
        thinkingStreaming = false;

  const _ContentSegment.artifact({
    required this.artifactTitle,
    required this.artifactType,
    required this.artifactCode,
  })  : kind = _SegmentKind.artifact,
        text = '',
        thinkingText = null,
        thinkingStreaming = false;

  const _ContentSegment.thinking(this.thinkingText,
      {required this.thinkingStreaming})
      : kind = _SegmentKind.thinking,
        text = '',
        artifactTitle = null,
        artifactType = null,
        artifactCode = null;

  bool get isArtifact => kind == _SegmentKind.artifact;
  bool get isThinking => kind == _SegmentKind.thinking;
}

final RegExp _blockPattern = RegExp(
  r'<artifact\s+([^>]*?)>([\s\S]*?)<\/artifact>|<think>([\s\S]*?)<\/think>',
  caseSensitive: false,
);
final RegExp _artifactAttrPattern = RegExp(
  r'''(\w+)\s*=\s*"([^"]*)"''',
);
final RegExp _openThinkPattern = RegExp(r'<think>', caseSensitive: false);

List<_ContentSegment> _splitContentSegments(String input) {
  final segments = <_ContentSegment>[];
  int last = 0;

  for (final match in _blockPattern.allMatches(input)) {
    if (match.start > last) {
      final plain = input.substring(last, match.start);
      if (plain.trim().isNotEmpty) segments.add(_ContentSegment.text(plain));
    }

    final artifactAttrs = match.group(1);
    if (artifactAttrs != null) {
      final code = (match.group(2) ?? '').trim();
      final attrs = <String, String>{
        for (final m in _artifactAttrPattern.allMatches(artifactAttrs))
          m.group(1)!.toLowerCase(): m.group(2)!,
      };
      segments.add(_ContentSegment.artifact(
        artifactTitle: attrs['title'] ?? 'artifact',
        artifactType: attrs['type'] ?? 'text',
        artifactCode: code,
      ));
    } else {
      final thought = (match.group(3) ?? '').trim();
      segments.add(_ContentSegment.thinking(thought, thinkingStreaming: false));
    }
    last = match.end;
  }

  String tail = last < input.length ? input.substring(last) : '';
  final openMatch = _openThinkPattern.firstMatch(tail);
  if (openMatch != null) {
    final before = tail.substring(0, openMatch.start);
    if (before.trim().isNotEmpty) segments.add(_ContentSegment.text(before));
    final liveThought = tail.substring(openMatch.end);
    segments.add(_ContentSegment.thinking(liveThought, thinkingStreaming: true));
    tail = '';
  }

  if (tail.trim().isNotEmpty) segments.add(_ContentSegment.text(tail));
  if (segments.isEmpty) segments.add(_ContentSegment.text(input));

  return segments;
}

class _MessageContent extends StatelessWidget {
  final String text;
  final Color baseColor;
  final double fontSize;

  const _MessageContent({
    required this.text,
    required this.baseColor,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    final segments = _splitContentSegments(text);

    if (segments.length == 1 && segments.first.kind == _SegmentKind.text) {
      return _MessageMarkdown(
          text: text, baseColor: baseColor, fontSize: fontSize);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final seg in segments)
          if (seg.isArtifact)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: ArtifactCard(
                artifactId: "${seg.artifactTitle}_${seg.artifactCode.hashCode}",
                title: seg.artifactTitle!,
                type: seg.artifactType!,
                code: seg.artifactCode!,
              ),
            )
          else if (seg.isThinking)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ThinkingBlock(
                text: seg.thinkingText ?? '',
                isStreaming: seg.thinkingStreaming,
              ),
            )
          else
            _MessageMarkdown(
                text: seg.text, baseColor: baseColor, fontSize: fontSize),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// SHIMMER TEXT — бегущий световой блик (фирменный приём Claude)
// ─────────────────────────────────────────────────────────────────────────

class _ShimmerText extends StatefulWidget {
  final String text;
  final bool active;

  const _ShimmerText({required this.text, required this.active});

  @override
  State<_ShimmerText> createState() => _ShimmerTextState();
}

class _ShimmerTextState extends State<_ShimmerText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat();
  }

  @override
  void didUpdateWidget(_ShimmerText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_c.isAnimating) _c.repeat();
    if (!widget.active && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  static const _style = TextStyle(
    fontSize: 12.5,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.1,
  );

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      return Text(widget.text,
          style: _style.copyWith(color: VesperColors.textSecondary));
    }

    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value; // 0..1 — блик едет слева н��право
        return ShaderMask(
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment(-1.5 + t * 3.0, 0),
            end: Alignment(-0.5 + t * 3.0, 0),
            colors: const [
              VesperColors.textFaint,
              VesperColors.textPrimary,
              VesperColors.textFaint,
            ],
          ).createShader(bounds),
          child: Text(widget.text, style: _style.copyWith(color: Colors.white)),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// THINKING BLOCK
//
// Стриминг: shimmer-текст + «дышащая» индиго-кромка + мини-метаболл.
// Раскрытые мысли — как blockquote с тонкой индиго-линией слева.
// ─────────────────────────────────────────────────────────────────────────

class _ThinkingBlock extends StatefulWidget {
  final String text;
  final bool isStreaming;

  const _ThinkingBlock({required this.text, required this.isStreaming});

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  bool _userOverride = false;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.isStreaming) {
      _expanded = true;
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_ThinkingBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isStreaming && widget.isStreaming) {
      _userOverride = false;
      _pulse.repeat(reverse: true);
      setState(() => _expanded = true);
    } else if (oldWidget.isStreaming && !widget.isStreaming) {
      _pulse.stop();
      if (!_userOverride) {
        Future.delayed(const Duration(milliseconds: 700), () {
          if (mounted && !_userOverride) setState(() => _expanded = false);
        });
      }
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _toggle() {
    _userOverride = true;
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _toggle,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  if (widget.isStreaming)
                    _PulsingOrb(pulse: _pulse)
                  else
                    const Icon(Icons.auto_awesome,
                        size: 14, color: VesperColors.indigoBright),
                  const SizedBox(width: 9),
                  _ShimmerText(
                    text: widget.isStreaming
                        ? 'Vesper размышляет…'
                        : 'Ход размышлений',
                    active: widget.isStreaming,
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 220),
                    child: const Icon(Icons.expand_more_rounded,
                        size: 18, color: VesperColors.textFaint),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                  // Мысли как blockquote: без курсива (плохо читается
                  // на кириллице), с тонкой индиго-линией слева
                  child: Container(
                    padding: const EdgeInsets.only(left: 12),
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          color:
                              VesperColors.indigoBright.withOpacity(0.30),
                          width: 2,
                        ),
                      ),
                    ),
                    child: Text(
                      widget.text.isEmpty ? '…' : widget.text,
                      style: const TextStyle(
                        color: VesperColors.textSecondary,
                        fontSize: 13,
                        height: 1.55,
                      ),
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );

    // «Дышащая» кромка + мягкое свечение при стриминге
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final p = _pulse.value;
        final streaming = widget.isStreaming;
        return Container(
          constraints: const BoxConstraints(maxWidth: 440),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: VesperColors.surface.withOpacity(0.45),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: streaming
                  ? VesperColors.indigoBright.withOpacity(0.25 + 0.20 * p)
                  : VesperColors.border,
            ),
            boxShadow: streaming
                ? [
                    BoxShadow(
                      color: VesperColors.indigoBright
                          .withOpacity(0.10 + 0.15 * p),
                      blurRadius: 24,
                      spreadRadius: -6,
                    ),
                  ]
                : null,
          ),
          child: child,
        );
      },
      child: content,
    );
  }
}

/// Пульсирующая индиго-точка — «мини-метаболл» для шапки блока размышлений.
/// Тот же язык жидкого света, что и в вашем шейдере.
class _PulsingOrb extends StatelessWidget {
  final Animation<double> pulse;

  const _PulsingOrb({required this.pulse});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) {
        final p = pulse.value;
        return Container(
          width: 14,
          height: 14,
          alignment: Alignment.center,
          child: Container(
            width: 8 + 3 * p,
            height: 8 + 3 * p,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: VesperColors.indigoBright.withOpacity(0.55 + 0.45 * p),
              boxShadow: [
                BoxShadow(
                  color: VesperColors.indigoBright.withOpacity(0.35 * p),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// GLASS CARD — стеклянное тело + 1px градиентная кромка (edge lighting)
// ─────────────────────────────────────────────────────────────────────────

class _GlassCard extends StatelessWidget {
  final Widget child;
  final bool glow; // при hover / стриминге

  const _GlassCard({required this.child, this.glow = false});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(15),
        // Подложка = «граница»: блик сверху → нейтраль → почти ничто
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            glow
                ? VesperColors.indigoBright.withOpacity(0.45)
                : VesperColors.glassEdgeTop,
            VesperColors.border,
            VesperColors.borderFaint,
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
        boxShadow: glow
            ? [
                BoxShadow(
                  color: VesperColors.indigoBright.withOpacity(0.18),
                  blurRadius: 28,
                  spreadRadius: -8,
                ),
              ]
            : null,
      ),
      padding: const EdgeInsets.all(1), // толщина кромки
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            color: VesperColors.surface.withOpacity(0.72),
            child: child,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// ARTIFACT ICONS & CARD
// ─────────────────────────────────────────────────────────────────────────

/// Иконка в зависимости от расширения/языка
IconData _iconForArtifactType(String type) {
  switch (type.toLowerCase()) {
    case 'python':
    case 'py':
      return Icons.data_object_rounded;
    case 'dart':
    case 'flutter':
      return Icons.flutter_dash_rounded;
    case 'javascript':
    case 'js':
    case 'typescript':
    case 'ts':
      return Icons.javascript_rounded;
    case 'json':
      return Icons.data_array_rounded;
    case 'html':
      return Icons.html_rounded;
    case 'css':
      return Icons.css_rounded;
    case 'markdown':
    case 'md':
      return Icons.article_rounded;
    default:
      return Icons.insert_drive_file_rounded;
  }
}

/// Карточка Артефакта: стекло + градиентная кромка + hover-свечение +
/// fade-out превью кода
class ArtifactCard extends ConsumerStatefulWidget {
  final String artifactId;
  final String title;
  final String type;
  final String code;

  const ArtifactCard({
    super.key,
    required this.artifactId,
    required this.title,
    required this.type,
    required this.code,
  });

  @override
  ConsumerState<ArtifactCard> createState() => _ArtifactCardState();
}

class _ArtifactCardState extends ConsumerState<ArtifactCard> {
  bool _hovered = false;

  Future<void> _downloadFile(BuildContext context) async {
    try {
      final directory = Directory.current;
      final file = File('${directory.path}/${widget.title}');
      await file.writeAsString(widget.code);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Файл сохранен: ${file.path}',
              style: const TextStyle(color: Colors.white)),
          backgroundColor: Colors.green.withOpacity(0.8),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Ошибка сохранения: $e',
              style: const TextStyle(color: Colors.white)),
          backgroundColor: Colors.redAccent.withOpacity(0.8),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _runCode(BuildContext context) {
    ref.read(chatProvider.notifier).runCode(widget.code, widget.artifactId);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => TerminalDialog(artifactId: widget.artifactId),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 440),
        margin: const EdgeInsets.symmetric(vertical: 8.0),
        child: _GlassCard(
          glow: _hovered,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context),
              _buildPreview(),
              _buildActions(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        // Полупрозрачный слой, не сплошной цвет — стекло не «ломается»
        color: Color(0x08FFFFFF), // white @ 3%
        border: Border(bottom: BorderSide(color: VesperColors.borderFaint)),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: VesperColors.indigoBright.withOpacity(0.14),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: VesperColors.indigoBright.withOpacity(0.20),
              ),
            ),
            child: Icon(
              _iconForArtifactType(widget.type),
              size: 16,
              color: VesperColors.indigoBright,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: VesperColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.1,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  widget.type.toUpperCase(),
                  style: const TextStyle(
                    color: VesperColors.textFaint,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            splashRadius: 20,
            icon: const Icon(Icons.copy_rounded,
                size: 18, color: VesperColors.textSecondary),
            tooltip: 'Копировать код',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: widget.code));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Код скопирован'),
                    behavior: SnackBarBehavior.floating),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    return Stack(
      children: [
        Container(
          constraints: const BoxConstraints(maxHeight: 120),
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          color: VesperColors.codeBg.withOpacity(0.6),
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: Text(
              widget.code,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: VesperColors.textSecondary,
                height: 1.6,
              ),
            ),
          ),
        ),
        // Fade-out: код «растворяется» вместо жёсткого обреза
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 44,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    VesperColors.codeBg.withOpacity(0),
                    VesperColors.codeBg.withOpacity(0.9),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActions(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: VesperColors.borderFaint)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton.icon(
            onPressed: () => _downloadFile(context),
            icon: const Icon(Icons.download_rounded, size: 16),
            label: const Text('Скачать', style: TextStyle(fontSize: 13)),
            style: TextButton.styleFrom(
              foregroundColor: VesperColors.textSecondary,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: VesperColors.indigoBright.withOpacity(0.15),
              foregroundColor: VesperColors.indigoBright,
              elevation: 0,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => _runCode(context),
            icon: const Icon(Icons.play_arrow_rounded, size: 16),
            label: const Text('Запустить',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// TERMINAL DIALOG
// ─────────────────────────────────────────────────────────────────────────

class TerminalDialog extends ConsumerWidget {
  final String artifactId;

  const TerminalDialog({super.key, required this.artifactId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runState = ref.watch(chatProvider).runResults[artifactId];
    final isRunning = runState?.isRunning ?? true;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(20),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxWidth: 700, maxHeight: 500),
        decoration: BoxDecoration(
          color: const Color(0xFF0A0A0F),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: VesperColors.border, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.5),
              blurRadius: 30,
              spreadRadius: 5,
            )
          ],
        ),
        child: Column(
          children: [
            // Шапка терминала
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: VesperColors.surfaceHigh,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
                border: const Border(
                    bottom: BorderSide(color: VesperColors.border)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.terminal_rounded,
                      size: 18, color: VesperColors.textSecondary),
                  const SizedBox(width: 8),
                  const Text(
                    'Терминал Vesper',
                    style: TextStyle(
                        color: VesperColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  // Строка статуса: цветная точка + текст, как у Vercel/Replit
                  if (isRunning)
                    const _ShimmerText(text: 'Выполняется…', active: true)
                  else
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: (runState?.exitCode ?? 0) == 0
                                ? const Color(0xFF4ADE80)
                                : const Color(0xFFF87171),
                          ),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          (runState?.exitCode ?? 0) == 0
                              ? 'Выполнено · exit 0'
                              : 'Ошибка · exit ${runState?.exitCode}',
                          style: const TextStyle(
                            color: VesperColors.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(width: 16),
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    child: const Icon(Icons.close_rounded,
                        size: 20, color: VesperColors.textFaint),
                  ),
                ],
              ),
            ),
            // Тело терминала
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                child: isRunning
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '~ Ожидание ответа от Ядра...',
                              style: TextStyle(
                                  color: VesperColors.textFaint,
                                  fontFamily: 'monospace',
                                  fontSize: 13),
                            ),
                          ],
                        ),
                      )
                    : SingleChildScrollView(
                        child: SelectionArea(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // stdout — нейтральный, а не «хакерский» зелёный:
                              // тише и профессиональнее
                              if (runState?.stdout.isNotEmpty == true)
                                Text(
                                  runState!.stdout,
                                  style: const TextStyle(
                                      color: VesperColors.textSecondary,
                                      fontFamily: 'monospace',
                                      fontSize: 12.5,
                                      height: 1.6),
                                ),
                              if (runState?.stderr.isNotEmpty == true)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    runState!.stderr,
                                    style: TextStyle(
                                        color: const Color(0xFFF87171)
                                            .withOpacity(0.9),
                                        fontFamily: 'monospace',
                                        fontSize: 12.5,
                                        height: 1.6),
                                  ),
                                ),
                              if (runState?.stdout.isEmpty == true &&
                                  runState?.stderr.isEmpty == true)
                                const Text(
                                  '(нет вывода)',
                                  style: TextStyle(
                                      color: VesperColors.textFaint,
                                      fontFamily: 'monospace',
                                      fontSize: 12.5),
                                ),
                            ],
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// MARKDOWN RENDERING (with code blocks + optional LaTeX)
//
// Типографика Inter: чем крупнее кегль — тем меньше letterSpacing.
// Вертикальный ритм: над заголовком в ~2 раза больше воздуха, чем под ним.
// ─────────────────────────────────────────────────────────────────────────

class _MessageMarkdown extends StatelessWidget {
  final String text;
  final Color baseColor;
  final double fontSize;

  const _MessageMarkdown({
    required this.text,
    required this.baseColor,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    final segments = _splitMathSegments(text);

    if (segments.length == 1 && !segments.first.isMath) {
      return _buildMarkdown(segments.first.content);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final seg in segments)
          if (seg.isMath)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: _MathBlock(
                tex: seg.content,
                displayMode: seg.displayMode,
                baseColor: baseColor,
                fontSize: fontSize,
              ),
            )
          else if (seg.content.trim().isNotEmpty)
            _buildMarkdown(seg.content),
      ],
    );
  }

  Widget _buildMarkdown(String data) {
    return MarkdownBody(
      data: data,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(
          color: baseColor,
          fontSize: fontSize,
          height: 1.6, // основной текст: просторный интерлиньяж
          letterSpacing: 0,
        ),
        pPadding: const EdgeInsets.only(bottom: 4),
        strong: TextStyle(
            color: baseColor, fontSize: fontSize, fontWeight: FontWeight.w700),
        em: TextStyle(
            color: baseColor, fontSize: fontSize, fontStyle: FontStyle.italic),
        listBullet: TextStyle(
            color: baseColor.withOpacity(0.7), fontSize: fontSize),
        listIndent: 22,
        listBulletPadding: const EdgeInsets.only(right: 6),
        blockquote: TextStyle(
          color: baseColor.withOpacity(0.75),
          fontSize: fontSize,
          height: 1.6,
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(
                color: VesperColors.indigoBright.withOpacity(0.5), width: 3),
          ),
        ),
        blockquotePadding: const EdgeInsets.only(left: 14),
        // Заголовки: отрицательный трекинг (Inter спроектирован под это)
        h1: TextStyle(
            color: baseColor,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            height: 1.3),
        h2: TextStyle(
            color: baseColor,
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.25,
            height: 1.35),
        h3: TextStyle(
            color: baseColor,
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.1,
            height: 1.4),
        // Вертикальный ритм: сверху 2x больше, чем снизу
        h1Padding: const EdgeInsets.only(top: 20, bottom: 8),
        h2Padding: const EdgeInsets.only(top: 18, bottom: 6),
        h3Padding: const EdgeInsets.only(top: 14, bottom: 4),
        blockSpacing: 12,
        code: TextStyle(
          color: VesperColors.indigoBright,
          backgroundColor: VesperColors.surfaceHigh,
          fontFamily: 'monospace',
          fontSize: fontSize - 1,
        ),
        codeblockPadding: EdgeInsets.zero,
        codeblockDecoration: const BoxDecoration(color: Colors.transparent),
        a: TextStyle(
          color: VesperColors.indigoBright,
          decoration: TextDecoration.underline,
          decorationColor: VesperColors.indigoBright.withOpacity(0.4),
        ),
        tableBorder: TableBorder.all(color: VesperColors.border),
        tableHead: TextStyle(
            color: baseColor,
            fontWeight: FontWeight.w600,
            fontSize: fontSize - 1),
        tableBody: TextStyle(
            color: baseColor.withOpacity(0.9), fontSize: fontSize - 1),
        horizontalRuleDecoration: const BoxDecoration(
          border: Border(top: BorderSide(color: VesperColors.border)),
        ),
      ),
      builders: {
        'code': _CodeBlockBuilder(),
      },
    );
  }
}

class _MathSegment {
  final String content;
  final bool isMath;
  final bool displayMode;
  const _MathSegment(this.content,
      {this.isMath = false, this.displayMode = false});
}

List<_MathSegment> _splitMathSegments(String input) {
  final pattern = RegExp(r'\$\$([\s\S]+?)\$\$|\$([^\n\$]+?)\$');
  final segments = <_MathSegment>[];
  int last = 0;

  for (final match in pattern.allMatches(input)) {
    if (match.start > last) {
      segments.add(_MathSegment(input.substring(last, match.start)));
    }
    final blockTex = match.group(1);
    final inlineTex = match.group(2);
    if (blockTex != null) {
      segments.add(
          _MathSegment(blockTex.trim(), isMath: true, displayMode: true));
    } else if (inlineTex != null) {
      segments.add(
          _MathSegment(inlineTex.trim(), isMath: true, displayMode: false));
    }
    last = match.end;
  }

  if (last < input.length) {
    segments.add(_MathSegment(input.substring(last)));
  }

  if (segments.isEmpty) {
    segments.add(_MathSegment(input));
  }

  return segments;
}

class _MathBlock extends StatelessWidget {
  final String tex;
  final bool displayMode;
  final Color baseColor;
  final double fontSize;

  const _MathBlock({
    required this.tex,
    required this.displayMode,
    required this.baseColor,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    Widget math;
    try {
      math = Math.tex(
        tex,
        textStyle: TextStyle(
            color: baseColor, fontSize: fontSize + (displayMode ? 2 : 0)),
        mathStyle: displayMode ? MathStyle.display : MathStyle.text,
        onErrorFallback: (err) => Text(
          tex,
          style: TextStyle(
            color: baseColor.withOpacity(0.7),
            fontFamily: 'monospace',
            fontSize: fontSize,
          ),
        ),
      );
    } catch (_) {
      math = Text(
        tex,
        style: TextStyle(
          color: baseColor.withOpacity(0.7),
          fontFamily: 'monospace',
          fontSize: fontSize,
        ),
      );
    }

    if (!displayMode) return math;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
      decoration: BoxDecoration(
        color: VesperColors.surfaceHigh.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: VesperColors.border),
      ),
      child: Center(
          child: SingleChildScrollView(
              scrollDirection: Axis.horizontal, child: math)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// CUSTOM CODE BLOCK BUILDER
// ─────────────────────────────────────────────────────────────────────────

class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final content = element.textContent;
    final isBlock =
        content.contains('\n') || element.attributes['class'] != null;

    if (!isBlock) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: VesperColors.surfaceHigh,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: VesperColors.borderFaint),
        ),
        child: Text(
          content,
          style: TextStyle(
            color: VesperColors.indigoBright,
            fontFamily: 'monospace',
            fontSize: (preferredStyle?.fontSize ?? 14) - 1,
          ),
        ),
      );
    }

    final language = _extractLanguage(element) ?? 'plaintext';
    final code = content.endsWith('\n')
        ? content.substring(0, content.length - 1)
        : content;

    return _CodeBlock(code: code, language: language);
  }

  String? _extractLanguage(md.Element element) {
    final cls = element.attributes['class'];
    if (cls == null) return null;
    return cls.startsWith('language-') ? cls.substring(9) : cls;
  }
}

class _CodeBlock extends StatefulWidget {
  final String code;
  final String language;

  const _CodeBlock({required this.code, required this.language});

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: VesperColors.codeBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VesperColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF16161F),
              border:
                  Border(bottom: BorderSide(color: VesperColors.borderFaint)),
            ),
            child: Row(
              children: [
                Text(
                  widget.language,
                  style: const TextStyle(
                    color: VesperColors.textFaint,
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
                const Spacer(),
                _CopyButton(copied: _copied, onTap: _copy),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: MediaQuery.of(context).size.width - 90,
              ),
              child: HighlightView(
                widget.code,
                language: widget.language,
                theme: atomOneDarkTheme,
                padding: const EdgeInsets.all(14),
                textStyle: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.6,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  final bool copied;
  final VoidCallback onTap;

  const _CopyButton({required this.copied, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                copied ? Icons.check_rounded : Icons.copy_rounded,
                size: 14,
                color: copied ? Colors.greenAccent : VesperColors.textFaint,
              ),
              const SizedBox(width: 5),
              Text(
                copied ? 'Скопировано' : 'Копировать',
                style: TextStyle(
                  fontSize: 11.5,
                  color: copied ? Colors.greenAccent : VesperColors.textFaint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// SEND BUTTON & OTHER UI ELEMENTS
// ─────────────────────────────────────────────────────────────────────────

class _SendButton extends StatelessWidget {
  final VoidCallback onTap;
  const _SendButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            // Плоский акцентный цвет вместо градиента — тише и увереннее
            color: VesperColors.indigoBright,
          ),
          child: const Icon(
            Icons.arrow_upward_rounded,
            color: Colors.white,
            size: 18,
          ),
        ),
      ),
    );
  }
}

class _ThinkingIndicator extends StatelessWidget {
  final bool visible;
  final FragmentShader? shader;
  final ValueListenable<double> time;
  final double phase;

  const _ThinkingIndicator({
    required this.visible,
    required this.shader,
    required this.time,
    required this.phase,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SizeTransition(
          sizeFactor: animation,
          axisAlignment: -1,
          child: child,
        ),
      ),
      child: visible
          ? Padding(
              key: const ValueKey('thinking-visible'),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Center(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: VesperColors.surfaceHigh.withOpacity(0.6),
                    border: Border.all(color: VesperColors.border),
                    boxShadow: [
                      BoxShadow(
                        color: VesperColors.indigoBright.withOpacity(0.28),
                        blurRadius: 24,
                        spreadRadius: -4,
                      ),
                    ],
                  ),
                  child: shader != null
                      // Перерисовывается только этот CustomPaint,
                      // а не весь экран — через ValueListenableBuilder
                      ? ValueListenableBuilder<double>(
                          valueListenable: time,
                          builder: (context, t, _) => ClipOval(
                            child: CustomPaint(
                              painter: MetaballsPainter(
                                shader: shader!,
                                time: t,
                                phase: phase,
                              ),
                            ),
                          ),
                        )
                      : const _ShimmerDots(),
                ),
              ),
            )
          : const SizedBox(
              width: double.infinity, key: ValueKey('thinking-hidden')),
    );
  }
}

class _ShimmerDots extends StatefulWidget {
  const _ShimmerDots();

  @override
  State<_ShimmerDots> createState() => _ShimmerDotsState();
}

class _ShimmerDotsState extends State<_ShimmerDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (i) {
            final t = (_controller.value + i * 0.22) % 1.0;
            final opacity = 0.35 + 0.65 * (0.5 - (t - 0.5).abs()) * 2;
            final scale = 0.7 + 0.3 * (0.5 - (t - 0.5).abs()) * 2;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Transform.scale(
                scale: scale,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: VesperColors.indigoBright.withOpacity(opacity),
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class _SettingsSheet extends StatefulWidget {
  final bool initialThinking;
  final double initialDetail;
  final ValueChanged<bool> onThinkingChanged;
  final ValueChanged<double> onDetailChanged;

  const _SettingsSheet({
    required this.initialThinking,
    required this.initialDetail,
    required this.onThinkingChanged,
    required this.onDetailChanged,
  });

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late bool _thinking = widget.initialThinking;
  late double _detail = widget.initialDetail;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: Container(
        padding: EdgeInsets.fromLTRB(
            20, 10, 20, 24 + MediaQuery.of(context).padding.bottom),
        decoration: const BoxDecoration(
          color: VesperColors.surface,
          border: Border(
            top: BorderSide(color: VesperColors.border),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: VesperColors.borderStrong,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              'Настройки ответа',
              style: TextStyle(
                color: VesperColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.1,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: VesperColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.psychology_alt_outlined,
                      size: 18, color: VesperColors.indigoBright),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Размышление',
                          style: TextStyle(
                              color: VesperColors.textPrimary,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w500)),
                      Text('Vesper думает дольше, ответ точнее',
                          style: TextStyle(
                              color: VesperColors.textFaint, fontSize: 12)),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: _thinking,
                  activeColor: VesperColors.indigoBright,
                  onChanged: (v) {
                    setState(() => _thinking = v);
                    widget.onThinkingChanged(v);
                  },
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: VesperColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.tune_rounded,
                      size: 18, color: VesperColors.indigoBright),
                ),
                const SizedBox(width: 12),
                const Text('Подробность',
                    style: TextStyle(
                        color: VesperColors.textPrimary,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w500)),
                const Spacer(),
                Text('${(_detail * 100).round()}%',
                    style: const TextStyle(
                        color: VesperColors.textFaint, fontSize: 12.5)),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: VesperColors.indigoBright,
                inactiveTrackColor: VesperColors.surfaceHigh,
                thumbColor: Colors.white,
                overlayColor: VesperColors.indigoBright.withOpacity(0.15),
                trackHeight: 3,
              ),
              child: Slider(
                value: _detail,
                onChanged: (v) {
                  setState(() => _detail = v);
                  widget.onDetailChanged(v);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelSelector extends StatelessWidget {
  final String selectedKey;
  final ValueChanged<String> onChanged;
  final bool compact;

  const _ModelSelector({
    required this.selectedKey,
    required this.onChanged,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final current = VesperModel.byKey(selectedKey);

    return Material(
      color: Colors.transparent,
      child: PopupMenuButton<String>(
        initialValue: selectedKey,
        onSelected: onChanged,
        color: VesperColors.surfaceHigh,
        elevation: 8,
        offset: compact ? const Offset(0, 40) : const Offset(0, -8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: VesperColors.border),
        ),
        itemBuilder: (context) => VesperModel.all.map((model) {
          final isActive = model.key == selectedKey;
          final accent = _modelAccent(model.key);
          return PopupMenuItem<String>(
            value: model.key,
            height: 58,
            child: Row(
              children: [
                // Цветовой акцент модели — точка 6px
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent,
                    boxShadow: isActive
                        ? [
                            BoxShadow(
                              color: accent.withOpacity(0.5),
                              blurRadius: 6,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        model.label,
                        style: TextStyle(
                          color: isActive
                              ? VesperColors.textPrimary
                              : VesperColors.textSecondary,
                          fontSize: 14,
                          fontWeight:
                              isActive ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        model.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: VesperColors.textFaint,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isActive) ...[
                  const SizedBox(width: 10),
                  const Icon(Icons.check_rounded,
                      size: 16, color: VesperColors.indigoBright),
                ],
              ],
            ),
          );
        }).toList(),
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: compact ? 12 : 14, vertical: compact ? 7 : 11),
          constraints: compact
              ? const BoxConstraints(minHeight: 34)
              : const BoxConstraints(minHeight: 46),
          decoration: BoxDecoration(
            color: VesperColors.surface,
            borderRadius: BorderRadius.circular(compact ? 17 : 24),
            border: Border.all(color: VesperColors.border, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Точка-акцент текущей модели вместо иконки
              Container(
                width: compact ? 6 : 7,
                height: compact ? 6 : 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _modelAccent(current.key),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                current.label,
                style: TextStyle(
                  color: VesperColors.textPrimary,
                  fontSize: compact ? 12.5 : 13.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.expand_more_rounded,
                  size: compact ? 15 : 17, color: VesperColors.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}

class _VesperDrawer extends ConsumerWidget {
  const _VesperDrawer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatProvider);

    return Drawer(
      // Темнее основного фона — контентная область кажется «поднятой»
      backgroundColor: const Color(0xFF0A0A0F),
      width: 288,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            const SizedBox(height: 4),
            _buildNewChatButton(context, ref),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 6),
              child: Text(
                'ЧАТЫ',
                style: TextStyle(
                  color: VesperColors.textFaint,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            Expanded(
              child: state.availableChats.isEmpty
                  ? const Center(
                      child: Text(
                        'Пока нет чатов',
                        style: TextStyle(
                          color: VesperColors.textFaint,
                          fontSize: 13,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      itemCount: state.availableChats.length,
                      itemBuilder: (context, index) {
                        final chat = state.availableChats[index];
                        final isActive = chat.id == state.currentSessionId;
                        return _ChatListTile(
                          title: chat.title,
                          isActive: isActive,
                          onTap: () {
                            ref
                                .read(chatProvider.notifier)
                                .switchChat(chat.id);
                            Navigator.of(context).pop();
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: VesperColors.surfaceHigh,
              border: Border.all(
                color: VesperColors.indigoBright.withOpacity(0.35),
              ),
            ),
            child: const Icon(Icons.auto_awesome,
                size: 15, color: VesperColors.indigoBright),
          ),
          const SizedBox(width: 10),
          const Text(
            'Vesper',
            style: TextStyle(
              color: VesperColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNewChatButton(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            ref.read(chatProvider.notifier).createNewChat();
            Navigator.of(context).pop();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: VesperColors.border, width: 1),
            ),
            child: const Row(
              children: [
                // edit_square вместо «плюса» — как у ChatGPT
                Icon(Icons.edit_square,
                    size: 16, color: VesperColors.textSecondary),
                SizedBox(width: 10),
                Text(
                  'Новый чат',
                  style: TextStyle(
                    color: VesperColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatListTile extends StatefulWidget {
  final String title;
  final bool isActive;
  final VoidCallback onTap;

  const _ChatListTile({
    required this.title,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_ChatListTile> createState() => _ChatListTileState();
}

class _ChatListTileState extends State<_ChatListTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Активный чат — тихая индиго-капсула; неактивные — просто текст.
    // Никаких бордеров и иконок в каждой строке — так делает Claude.
    final bg = widget.isActive
        ? VesperColors.indigoBright.withOpacity(0.08)
        : _hovered
            ? Colors.white.withOpacity(0.04)
            : Colors.transparent;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: widget.onTap,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: widget.isActive
                      ? VesperColors.textPrimary
                      : VesperColors.textSecondary,
                  fontSize: 14,
                  fontWeight:
                      widget.isActive ? FontWeight.w500 : FontWeight.w400,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MetaballsPainter extends CustomPainter {
  final FragmentShader shader;
  final double time;
  final double phase;
  final Color color;

  MetaballsPainter({
    required this.shader,
    required this.time,
    required this.phase,
    this.color = const Color.fromRGBO(74, 0, 130, 1.0),
  });

  @override
  void paint(Canvas canvas, Size size) {
    shader.setFloat(0, time);
    shader.setFloat(1, size.width / 2);
    shader.setFloat(2, size.height / 2);
    shader.setFloat(3, color.red / 255.0);
    shader.setFloat(4, color.green / 255.0);
    shader.setFloat(5, color.blue / 255.0);
    shader.setFloat(6, color.opacity);
    shader.setFloat(7, phase);

    final paint = Paint()..shader = shader;
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant MetaballsPainter oldDelegate) {
    return oldDelegate.time != time ||
        oldDelegate.phase != phase ||
        oldDelegate.color != color;
  }
}
