import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app_music/main.dart';

void main() {
  testWidgets('MusicApp builds and shows login screen', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MusicApp());

    // Verify that login screen is shown
    expect(find.text('Welcome Back!'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
  });
}
