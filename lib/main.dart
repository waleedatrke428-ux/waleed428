import 'package:flutter/material.dart';

void main() {
  runApp(const CloudMobileApp());
}

class CloudMobileApp extends StatelessWidget {
  const CloudMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cloud Mobile Starter',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const StarterHomePage(),
    );
  }
}

class StarterHomePage extends StatelessWidget {
  const StarterHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cloud Mobile Starter')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Ready to build in the cloud.',
            key: ValueKey('starter-message'),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
