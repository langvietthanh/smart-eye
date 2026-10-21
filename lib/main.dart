import 'package:flutter/material.dart';

import 'screens/camera_screen.dart';

void main() {
  // Đảm bảo các plugin được khởi tạo trước khi app chạy
  WidgetsFlutterBinding.ensureInitialized();

  // Camera discovery belongs to the screen's retryable lifecycle. A plugin or
  // permission failure must not prevent the app and its error UI from starting.
  runApp(const SmartEyeApp());
}

class SmartEyeApp extends StatelessWidget {
  const SmartEyeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Eye',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const CameraScreen(),
    );
  }
}
