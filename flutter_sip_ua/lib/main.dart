import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sip/sip_user_agent.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

void main() {
  runApp(const FlutterSipUaApp());
}

class FlutterSipUaApp extends StatefulWidget {
  const FlutterSipUaApp({super.key});

  @override
  State<FlutterSipUaApp> createState() => _FlutterSipUaAppState();
}

class _FlutterSipUaAppState extends State<FlutterSipUaApp> {
  final SipUserAgent _ua = SipUserAgent();

  @override
  void dispose() {
    _ua.stop();
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
