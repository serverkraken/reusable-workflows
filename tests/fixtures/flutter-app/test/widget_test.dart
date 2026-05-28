import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:catalog_test_flutter_app/main.dart';

void main() {
  testWidgets('renders the greeting widget', (tester) async {
    await tester.pumpWidget(const FixtureApp());
    expect(find.byKey(const Key('greeting')), findsOneWidget);
  });
}
