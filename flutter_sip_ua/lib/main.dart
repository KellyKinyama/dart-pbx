import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sip/sip_file_logger.dart';
import 'sip/sip_user_agent.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FlutterSipUaApp());
}

class FlutterSipUaApp extends StatefulWidget {
  const FlutterSipUaApp({super.key});

  @override
  State<FlutterSipUaApp> createState() => _FlutterSipUaAppState();
}

class _FlutterSipUaAppState extends State<FlutterSipUaApp> {
  final SipUserAgent _ua = SipUserAgent();
  late final SipFileLogger _fileLogger = SipFileLogger(_buildLogPath());

  @override
  void initState() {
    super.initState();
    // Synchronously open the wire dump and attach it BEFORE the home page
    // restores the saved account (and triggers ua.start). Otherwise the
    // first REGISTER + transport state events race the attach and never
    // make it to disk.
    try {
      _fileLogger.open();
      _ua.attachFileLogger(_fileLogger);
      // ignore: avoid_print
      print('[sip] wire log: ${_fileLogger.path}');
    } catch (e) {
      // ignore: avoid_print
      print('[sip] could not open wire log: $e');
    }
  }

  static String _buildLogPath() {
    final ts = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final dir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}flutter_sip_ua',
    );
    return '${dir.path}${Platform.pathSeparator}sip-$ts.log';
  }

  @override
  void dispose() {
    _ua.stop();
    _fileLogger.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dart SIP',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: FutureBuilder<SharedPreferences>(
        future: SharedPreferences.getInstance(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return HomePage(ua: _ua, prefs: snap.data!);
        },
      ),
    );
  }
}
