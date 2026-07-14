import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'chat_screen.dart';

void main() {
  runApp(
    // Оборачиваем приложение в ProviderScope для Riverpod
    const ProviderScope(
      child: VesperApp(),
    ),
  );
}

class VesperApp extends StatelessWidget {
  const VesperApp({super.key});

  @override
  Widget build(BuildContext context) {
    final baseTextTheme = GoogleFonts.interTextTheme(ThemeData.dark().textTheme);

    return MaterialApp(
      title: 'Vesper AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D0D12),

        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF8A5CF6),
          surface: Color(0xFF1A1A24),
          onSurface: Color(0xFFF5F5F7),
          onPrimary: Colors.white,
        ),

        // Мягкие «искры» вместо чернильных кругов при тапе
        splashFactory: InkSparkle.splashFactory,

        // Drawer темнее основного фона — основная область кажется «поднятой»
        drawerTheme: const DrawerThemeData(
          backgroundColor: Color(0xFF0A0A0F),
          surfaceTintColor: Colors.transparent,
        ),

        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
        ),

        popupMenuTheme: PopupMenuThemeData(
          color: const Color(0xFF20202C),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0x14FFFFFF)),
          ),
        ),

        dialogTheme: const DialogThemeData(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
        ),

        snackBarTheme: SnackBarThemeData(
          backgroundColor: const Color(0xFF20202C),
          contentTextStyle: GoogleFonts.inter(
            color: const Color(0xFFF5F5F7),
            fontSize: 13.5,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0x14FFFFFF)),
          ),
          behavior: SnackBarBehavior.floating,
        ),

        // Выделение текста индиго вместо системного синего —
        // маленькая деталь, дающая ощущение «доведённого» продукта
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: Color(0xFF8A5CF6),
          selectionColor: Color(0x338A5CF6),
          selectionHandleColor: Color(0xFF8A5CF6),
        ),

        textTheme: baseTextTheme.copyWith(
          bodyMedium: baseTextTheme.bodyMedium?.copyWith(
            fontSize: 15,
            height: 1.6,
            letterSpacing: 0,
            color: const Color(0xFFF5F5F7),
          ),
          titleLarge: baseTextTheme.titleLarge?.copyWith(
            fontSize: 22,
            height: 1.3,
            letterSpacing: -0.4,
            fontWeight: FontWeight.w700,
          ),
          titleMedium: baseTextTheme.titleMedium?.copyWith(
            fontSize: 16,
            height: 1.4,
            letterSpacing: -0.1,
            fontWeight: FontWeight.w600,
          ),
          labelSmall: baseTextTheme.labelSmall?.copyWith(
            fontSize: 11,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF6B6B78),
          ),
        ),
      ),
      home: const ChatScreen(),
    );
  }
}
