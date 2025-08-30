import 'package:flutter/material.dart';

class AppConstants {
  static const String baseUrl = 'https://asia-southeast1-nexuspolice-13560.cloudfunctions.net/';
  static const String appTitle = 'Philippine National Police';
  static const String appMotto = 'SERVICE • HONOR • JUSTICE';
  static const String developerCredit = 'DEVELOPED BY RCC4A AND RICTMD4A';
  static const int locationWarningNotificationId = 99;
  // Update checker endpoint (PHP script)
  static const String updateCheckUrl = 'https://pro4a-1key.com/nexus/checkUpdate';
}

class AppThemes {
  static final ThemeData lightTheme = ThemeData(
    brightness: Brightness.light,
    primaryColor: const Color(0xFFFFFFFF),
    scaffoldBackgroundColor: const Color(0xFFF2F2F7),
    cardColor: const Color(0xFFFFFFFF),
    colorScheme: const ColorScheme.light().copyWith(
      secondary: const Color(0xFF007AFF),
      primary: const Color(0xFF007AFF),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    ),
    cardTheme: CardThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: Color(0xFF000000)),
      bodyMedium: TextStyle(color: Color(0xFF000000)),
    ),
  );

  static final ThemeData darkTheme = ThemeData(
    brightness: Brightness.dark,
    primaryColor: const Color(0xFF000000),
    scaffoldBackgroundColor: const Color(0xFF000000),
    cardColor: const Color(0xFF1C1C1E),
    colorScheme: const ColorScheme.dark().copyWith(
      secondary: const Color(0xFF0A84FF),
      primary: const Color(0xFF0A84FF),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    ),
    cardTheme: CardThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: Color(0xFFFFFFFF)),
      bodyMedium: TextStyle(color: Color(0xFFFFFFFF)),
    ),
  );
}

class AppSettings {
  static const Duration locationTimeout = Duration(seconds: 15);
  static const Duration apiUpdateInterval = Duration(seconds: 2);
  static const Duration batteryUpdateInterval = Duration(seconds: 30);
  static const Duration networkUpdateInterval = Duration(seconds: 10);
  static const int distanceFilter = 5; // int, not double
}