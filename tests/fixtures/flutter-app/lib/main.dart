import 'package:flutter/material.dart';

void main() => runApp(const FixtureApp());

class FixtureApp extends StatelessWidget {
  const FixtureApp({super.key});

  static const greeting =
      String.fromEnvironment('GREETING', defaultValue: 'hello');

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text(greeting, key: const Key('greeting')),
        ),
      ),
    );
  }
}
