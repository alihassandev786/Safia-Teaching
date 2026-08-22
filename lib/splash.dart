import 'dart:async';
import 'package:flutter/material.dart';
import 'package:saifia_teachings/home.dart';

class SplashScreen extends StatefulWidget {
  final bool isDark;
  final VoidCallback onToggleTheme;

  const SplashScreen({
    super.key,
    required this.isDark,
    required this.onToggleTheme,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  Timer? _t;

  @override
  void initState() {
    super.initState();

    _t = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => Home(
            isDark: widget.isDark,
            onToggleTheme: widget.onToggleTheme,
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(0xFFFDEDD8),
      body: SafeArea(
        child: Center(
           child: Padding(
             padding: const EdgeInsets.only(bottom:30 ),
             child: Image.asset(
                "assets/images/ff.png",
                fit: BoxFit.contain,
                width:400, // optional
              ),
           ),
          ),
        ),
    );
  }
}
