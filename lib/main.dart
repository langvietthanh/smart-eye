import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'screens/camera_screen.dart';

/// Danh sách camera của thiết bị — dùng toàn cục
late List<CameraDescription> cameras;

Future<void> main() async {
  // Đảm bảo các plugin được khởi tạo trước khi app chạy
  WidgetsFlutterBinding.ensureInitialized();

  // Lấy danh sách camera có trên thiết bị
  cameras = await availableCameras();

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
