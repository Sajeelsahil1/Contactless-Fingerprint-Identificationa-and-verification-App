import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:ui' as ui;
import 'package:image/image.dart'
    as img; // Using your project's existing alias 'img'
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:async';
// --- NEW DEPENDENCIES ---
import 'package:camera/camera.dart';
// FIX: Removed 'vibration' and added 'services' for built-in haptics
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:flutter/foundation.dart';
// ------------------------

final logger = Logger();
late List<CameraDescription> _cameras;

// --- HELPER CLASSES & TOP-LEVEL FUNCTIONS ---

// Helper class to pass camera data to the background isolate.
class CameraImageData {
  final int width;
  final int height;
  final Uint8List bytes;

  CameraImageData(this.width, this.height, this.bytes);
}

// Helper class to pass enhancement data to the background isolate.
class EnhancementData {
  final String imagePath;
  final String tempDirPath;

  EnhancementData(this.imagePath, this.tempDirPath);
}

// Background function for clarity analysis.
Future<double> computeClarityScore(CameraImageData imageData) async {
  try {
    final image = img.Image.fromBytes(
      width: imageData.width,
      height: imageData.height,
      bytes: imageData.bytes.buffer,
      format: img.Format.uint8,
      order: img.ChannelOrder.red,
    );

    final width = image.width;
    final height = image.height;
    final cropX = (width * 0.15).toInt();
    final cropY = (height * 0.10).toInt();
    final cropWidth = (width * 0.70).toInt();
    final cropHeight = (height * 0.80).toInt();

    final roiImage = img.copyCrop(image,
        x: cropX, y: cropY, width: cropWidth, height: cropHeight);

    double mean = 0.0;
    for (var p in roiImage) {
      mean += p.r;
    }
    mean /= roiImage.length;

    double variance = 0.0;
    for (var p in roiImage) {
      variance += (p.r - mean) * (p.r - mean);
    }
    variance /= roiImage.length;
    return variance;
  } catch (e) {
    print("Error computing clarity score: $e");
    return 0.0;
  }
}

// Background function for sharpening and saving the image.
Future<String> enhanceImage(EnhancementData data) async {
  final originalBytes = await File(data.imagePath).readAsBytes();
  final originalImage = img.decodeImage(originalBytes);

  if (originalImage == null) {
    throw Exception('Could not decode image');
  }

  // --- NEW ENHANCEMENT PIPELINE FOR CLARITY ---

  // 1. Apply a strong sharpening filter to enhance ridges and valleys.
  final sharpenKernel = [-1, -1, -1, -1, 9, -1, -1, -1, -1];
  final enhancedImage = img.convolution(originalImage, filter: sharpenKernel);

  // 2. Slightly increase the overall contrast to make the sharpened details pop.
  img.adjustColor(enhancedImage, contrast: 1.2);

  // -----------------------------------------

  final newPath = path.join(data.tempDirPath, 'enhanced_fingerprint.jpg');
  await File(newPath).writeAsBytes(img.encodeJpg(enhancedImage));

  return newPath;
}
// --------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _cameras = await availableCameras();
  runApp(const FingerprintApp());
}

class FingerprintApp extends StatelessWidget {
  const FingerprintApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fingerprint Recognition',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.deepPurple,
        scaffoldBackgroundColor: Colors.transparent,
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 8,
            shadowColor: Colors.black26,
          ),
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Colors.white),
          headlineSmall:
              TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      home: const SplashScreen(),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  _SplashScreenState createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn),
    );

    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _controller.forward();

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const FingerprintHome()),
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.deepPurple,
              Colors.blueAccent,
            ],
          ),
        ),
        child: Center(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: ScaleTransition(
              scale: _scaleAnimation,
              child: const Text(
                'Contactless Fingerprint APP',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class FingerprintHome extends StatefulWidget {
  const FingerprintHome({super.key});

  @override
  State<FingerprintHome> createState() => _FingerprintHomeState();
}

class _FingerprintHomeState extends State<FingerprintHome>
    with SingleTickerProviderStateMixin {
  File? _capturedImage;
  bool _loading = false;
  String _loadingMessage = "";
  bool testerMode = false;
  final _serverUrl = "https://d21e3f662806.ngrok-free.app";

  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _captureImage() async {
    try {
      final enhancedImagePath = await Navigator.push<String?>(
        context,
        MaterialPageRoute(
          builder: (context) => AutoCaptureScreen(camera: _cameras[0]),
        ),
      );

      if (enhancedImagePath != null) {
        final enhancedImageFile = File(enhancedImagePath);

        final manuallyCroppedFile = await Navigator.push<File?>(
          context,
          MaterialPageRoute(
            builder: (_) => CropperPage(imageFile: enhancedImageFile),
          ),
        );

        if (manuallyCroppedFile != null) {
          setState(() {
            _capturedImage = manuallyCroppedFile;
          });
        }
      }
    } catch (e) {
      print('Error during new capture process: $e');
      _showPopup(
          'Error', 'Failed to capture or process the image. Please try again.');
    }
  }

  void _showPopup(String title, String message) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: Colors.black.withOpacity(0.8),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("OK", style: TextStyle(color: Colors.white)),
          )
        ],
      ),
    );
  }

  Future<void> _getUsers() async {
    final res = await http.get(Uri.parse("$_serverUrl/users"));
    if (res.statusCode == 200) {
      final users = jsonDecode(res.body);
      _showUsersPopup(users);
    } else {
      _showPopup("❌ Error", "Failed to fetch users.");
    }
  }

  void _showUsersPopup(List users) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.black.withOpacity(0.8),
        title:
            const Text("Current Users", style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            children: [
              for (var user in users) ...[
                ListTile(
                  title: Text(
                    "ID: ${user['user_id']}, Name: ${user['username']}",
                    style: const TextStyle(color: Colors.white),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit, color: Colors.white),
                        onPressed: () {
                          _updateUser(user['user_id']);
                          Navigator.pop(context);
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.white),
                        onPressed: () {
                          _deleteUser(user['user_id']);
                          Navigator.pop(context);
                        },
                      ),
                    ],
                  ),
                ),
              ]
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close", style: TextStyle(color: Colors.white)),
          )
        ],
      ),
    );
  }

  Future<void> _updateUser(String userId) async {
    final res = await http.get(Uri.parse("$_serverUrl/user/$userId"));

    if (res.statusCode == 200) {
      final user = jsonDecode(res.body);
      TextEditingController usernameCtrl =
          TextEditingController(text: user['username']);
      TextEditingController phoneCtrl =
          TextEditingController(text: user['phone']);

      if (!mounted) return;

      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: Colors.black.withOpacity(0.8),
          title:
              const Text("Update User", style: TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: Column(
              children: [
                TextField(
                  controller: usernameCtrl,
                  decoration: const InputDecoration(
                    labelText: "Username",
                    labelStyle: TextStyle(color: Colors.white70),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white70),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white),
                    ),
                  ),
                  style: const TextStyle(color: Colors.white),
                ),
                TextField(
                  controller: phoneCtrl,
                  decoration: const InputDecoration(
                    labelText: "Phone Number",
                    labelStyle: TextStyle(color: Colors.white70),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white70),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white),
                    ),
                  ),
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child:
                  const Text("Cancel", style: TextStyle(color: Colors.white)),
            ),
            ElevatedButton(
              onPressed: () async {
                final updatedUsername = usernameCtrl.text.trim();
                final updatedPhone = phoneCtrl.text.trim();
                if (updatedUsername.isEmpty || updatedPhone.isEmpty) {
                  _showPopup("❌ Error", "All fields are required.");
                  return;
                }

                final updateRes = await http.put(
                  Uri.parse("$_serverUrl/update/$userId"),
                  headers: {"Content-Type": "application/json"},
                  body: jsonEncode({
                    "username": updatedUsername,
                    "phone": updatedPhone,
                  }),
                );

                if (updateRes.statusCode == 200) {
                  _showPopup("✅ Success", "User updated successfully.");
                  if (mounted) {
                    Navigator.pop(context);
                  }
                } else {
                  _showPopup("❌ Error", "Failed to update user.");
                }
              },
              child: const Text("Update"),
            ),
          ],
        ),
      );
    } else {
      _showPopup("❌ Error", "Failed to fetch user details.");
    }
  }

  Future<void> _deleteUser(String userId) async {
    final res = await http.delete(Uri.parse("$_serverUrl/delete/$userId"));
    if (res.statusCode == 200) {
      _showPopup("✅ Success", "User $userId deleted successfully.");
    } else {
      _showPopup("❌ Error", "Failed to delete user.");
    }
  }

  Future<void> _registerFingerprint() async {
    final idCtrl = TextEditingController();
    final usernameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.black.withOpacity(0.8),
        title: const Text("Register", style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: idCtrl,
                maxLength: 4,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: "4-digit ID",
                  labelStyle: TextStyle(color: Colors.white70),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white70),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white),
                  ),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              TextField(
                controller: usernameCtrl,
                decoration: const InputDecoration(
                  labelText: "Username",
                  labelStyle: TextStyle(color: Colors.white70),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white70),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white),
                  ),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: "Phone Number",
                  labelStyle: TextStyle(color: Colors.white70),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white70),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white),
                  ),
                ),
                style: const TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel", style: TextStyle(color: Colors.white)),
          ),
          ElevatedButton(
            child: const Text("Submit"),
            onPressed: () async {
              final id = idCtrl.text.trim();
              final username = usernameCtrl.text.trim();
              final phone = phoneCtrl.text.trim();
              Navigator.pop(context);

              if (id.length != 4 ||
                  username.isEmpty ||
                  phone.isEmpty ||
                  _capturedImage == null) {
                _showPopup(
                    "❌ Error", "Fill all fields and capture fingerprint.");
                return;
              }

              setState(() {
                _loading = true;
                _loadingMessage = "Registering Fingerprint...";
              });

              final req = http.MultipartRequest(
                  "POST", Uri.parse("$_serverUrl/register"));
              req.fields['user_id'] = id;
              req.fields['username'] = username;
              req.fields['phone'] = phone;
              req.files.add(await http.MultipartFile.fromPath(
                  "file", _capturedImage!.path));
              final res = await req.send();
              final body = await res.stream.bytesToString();
              final json = jsonDecode(body);
              setState(() => _loading = false);
              _showPopup(res.statusCode == 200 ? "✅ Success" : "❌ Failed",
                  json['message']);
            },
          )
        ],
      ),
    );
  }

  Future<void> _verifyFingerprint() async {
    final idCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.black.withOpacity(0.8),
        title: const Text("Verify", style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: idCtrl,
          maxLength: 4,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: "4-digit ID",
            labelStyle: TextStyle(color: Colors.white70),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white70),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white),
            ),
          ),
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel", style: TextStyle(color: Colors.white)),
          ),
          ElevatedButton(
            child: const Text("Submit"),
            onPressed: () async {
              final id = idCtrl.text.trim();
              Navigator.pop(context);

              if (id.length != 4 || _capturedImage == null) {
                _showPopup(
                    "❌ Error", "Valid ID and captured fingerprint required.");
                return;
              }

              setState(() {
                _loading = true;
                _loadingMessage = "Verifying Fingerprint...";
              });

              int maxRetries = 3;
              int attempt = 0;
              bool success = false;

              while (attempt < maxRetries && !success) {
                try {
                  final req = http.MultipartRequest(
                      "POST", Uri.parse("$_serverUrl/verify"));
                  req.fields['user_id'] = id;
                  req.files.add(await http.MultipartFile.fromPath(
                      "file", _capturedImage!.path));
                  logger.i('Sending verification request for user_id: $id');
                  final res = await req.send();
                  final body = await res.stream.bytesToString();

                  logger.i('Verification response status: ${res.statusCode}');
                  logger.i('Verification response body: $body');

                  if (res.statusCode == 200) {
                    final json = jsonDecode(body);
                    setState(() => _loading = false);
                    success = true;

                    if (!mounted) return;
                    _showPopup("🎯 Match",
                        "User: ${json['username']}\nUSER IS VERIFIED ✅");

                    if (testerMode) {
                      _showPopup(
                        "🧪 Tester Mode",
                        "Final Accuracy: ${json['accuracy']}%\n"
                            "ORB Score: ${json['orb_score']}\n"
                            "Minutiae Score: ${json['minutiae_score']}",
                      );
                    }
                  } else {
                    final json = jsonDecode(body);
                    final status = json['status'] ?? '';
                    final message =
                        json['message'] ?? 'Unknown error occurred.';
                    setState(() => _loading = false);
                    success = true;

                    if (!mounted) return;
                    switch (status) {
                      case 'blurry':
                        _showPopup("❌ Blurry Image",
                            "Fingerprint image is too blurry. Please recapture.");
                        break;
                      case 'no_fingerprint':
                        _showPopup("❌ No Fingerprint Detected",
                            "No fingerprint pattern was detected in the image.");
                        break;
                      case 'no_user':
                        _showPopup("❌ User Not Found",
                            "No matching user found for ID $id.");
                        break;
                      case 'low_quality':
                        _showPopup("❌ Low Quality Image",
                            "Image quality is too low. Recapture, please.");
                        break;
                      case 'spoof':
                        _showPopup("❌ Spoof Detected",
                            "Spoofed fingerprint detected. Verification failed.");
                        break;
                      case 'anomaly':
                        _showPopup("❌ Anomaly Detected",
                            "Anomalous fingerprint features detected.");
                        break;
                      default:
                        _showPopup("❌ Verification Failed", message);
                        break;
                    }
                  }
                } catch (e, stackTrace) {
                  logger.e('Verification error: $e\n$stackTrace');
                  attempt++;
                  if (attempt >= maxRetries) {
                    setState(() => _loading = false);
                    if (!mounted) return;
                    _showPopup("❌ Error",
                        "Verification failed after $attempt attempts.\n\nError: ${e.toString()}");
                  } else {
                    await Future.delayed(const Duration(seconds: 2));
                  }
                }
              }
            },
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.deepPurple,
                Colors.blueAccent,
              ],
            ),
          ),
        ),
        BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            color: Colors.black.withOpacity(0.3),
          ),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            title: const Text("Fingerprint App",
                style: TextStyle(color: Colors.white)),
            centerTitle: true,
            actions: [
              Row(
                children: [
                  const Text(
                    "Tester",
                    style: TextStyle(color: Colors.white),
                  ),
                  Switch(
                    value: testerMode,
                    onChanged: (value) {
                      setState(() {
                        testerMode = value;
                      });
                    },
                    activeColor: Colors.white,
                    inactiveThumbColor: Colors.grey,
                  ),
                  const SizedBox(width: 12),
                ],
              ),
            ],
          ),
          body: SafeArea(
            child: Center(
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const SizedBox(height: 20),
                      const Text(
                        'USE THUMB ONLY',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _capturedImage != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.file(
                                _capturedImage!,
                                width: MediaQuery.of(context).size.width * 0.5,
                                height: MediaQuery.of(context).size.width * 0.5,
                                fit: BoxFit.cover,
                              ),
                            )
                          : Icon(
                              Icons.fingerprint,
                              size: MediaQuery.of(context).size.width * 0.3,
                              color: Colors.white.withOpacity(0.7),
                            ),
                      const SizedBox(height: 30),
                      _buildAnimatedButton(
                        onPressed: _captureImage,
                        icon: Icons.camera,
                        label: "Capture Fingerprint",
                        gradient: const LinearGradient(
                          colors: [Colors.deepPurple, Colors.purpleAccent],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildAnimatedButton(
                        onPressed: _registerFingerprint,
                        icon: Icons.fingerprint,
                        label: "Register",
                        gradient: const LinearGradient(
                          colors: [Colors.green, Colors.greenAccent],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildAnimatedButton(
                        onPressed: _verifyFingerprint,
                        icon: Icons.verified_user,
                        label: "Verify",
                        gradient: const LinearGradient(
                          colors: [Colors.blue, Colors.blueAccent],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildAnimatedButton(
                        onPressed: _getUsers,
                        icon: Icons.list,
                        label: "Current Users",
                        gradient: const LinearGradient(
                          colors: [Colors.orange, Colors.deepOrangeAccent],
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_loading)
          Container(
            color: Colors.black54,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: Colors.white),
                  const SizedBox(height: 16),
                  Text(
                    _loadingMessage,
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                  ),
                  const SizedBox(height: 16),
                  const SizedBox(
                    width: 200,
                    child: LinearProgressIndicator(color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildAnimatedButton({
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
    required LinearGradient gradient,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, color: Colors.white),
        label: Text(label, style: const TextStyle(color: Colors.white)),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
      ),
    );
  }
}

// Your existing CropperPage (unchanged)
enum DragMode {
  move,
  resizeTopLeft,
  resizeTopRight,
  resizeBottomLeft,
  resizeBottomRight
}

class CropperPage extends StatefulWidget {
  final File imageFile;

  const CropperPage({super.key, required this.imageFile});

  @override
  State<CropperPage> createState() => _CropperPageState();
}

class _CropperPageState extends State<CropperPage>
    with SingleTickerProviderStateMixin {
  bool _isLoading = true;
  ui.Image? _image;
  img.Image? originalImage;
  Rect cropRect = Rect.zero;
  Offset? _lastTouch;
  bool _showPreview = false;
  int _rotationTurns = 0;
  double scaleX = 1;
  double scaleY = 1;
  DragMode? _dragMode;
  late AnimationController _animationController;
  late Animation<Rect?> _rectAnimation;
  Timer? _updateTimer;
  bool _needsUpdate = false;
  Rect? _pendingRect;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _rectAnimation = RectTween(begin: cropRect, end: cropRect).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _loadImage();
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _loadImage() async {
    final data = await widget.imageFile.readAsBytes();
    originalImage = img.decodeImage(data)!;
    if (originalImage == null) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Error'),
          content: const Text('Failed to load image.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    await _updateUiImage();
    _initializeCropBox();
    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _updateUiImage() async {
    final rotated = img.copyRotate(originalImage!, angle: _rotationTurns * 90);
    final bytes = Uint8List.fromList(img.encodeJpg(rotated));
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    setState(() {
      _image = frame.image;
    });
  }

  void _initializeCropBox() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final screenSize = MediaQuery.of(context).size;
      final imageRatio = _image!.width / _image!.height;
      final screenRatio = screenSize.width / screenSize.height;

      double drawWidth, drawHeight;
      if (imageRatio > screenRatio) {
        drawWidth = screenSize.width;
        drawHeight = screenSize.width / imageRatio;
      } else {
        drawHeight = screenSize.height;
        drawWidth = screenSize.height * imageRatio;
      }

      scaleX = originalImage!.width / drawWidth;
      scaleY = originalImage!.height / drawHeight;

      final size = (drawWidth < drawHeight ? drawWidth : drawHeight) * 0.8;

      setState(() {
        cropRect = Rect.fromLTWH(
          (drawWidth - size) / 2,
          (drawHeight - size) / 2,
          size,
          size,
        );
        _rectAnimation = RectTween(begin: cropRect, end: cropRect).animate(
          CurvedAnimation(
              parent: _animationController, curve: Curves.easeInOut),
        );
      });
    });
  }

  void _rotateImage() {
    _rotationTurns = (_rotationTurns + 1) % 4;
    _updateUiImage();
    _initializeCropBox();
  }

  DragMode? _getDragMode(Offset position) {
    const edgeSize = 20.0;
    if ((position - cropRect.topLeft).distance <= edgeSize) {
      return DragMode.resizeTopLeft;
    }
    if ((position - cropRect.topRight).distance <= edgeSize) {
      return DragMode.resizeTopRight;
    }
    if ((position - cropRect.bottomLeft).distance <= edgeSize) {
      return DragMode.resizeBottomLeft;
    }
    if ((position - cropRect.bottomRight).distance <= edgeSize) {
      return DragMode.resizeBottomRight;
    }
    if (cropRect.contains(position)) return DragMode.move;
    return null;
  }

  void _onPanStart(DragStartDetails details) {
    _dragMode = _getDragMode(details.localPosition);
    _lastTouch = details.localPosition;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_dragMode == null || _lastTouch == null) return;

    final delta = details.localPosition - _lastTouch!;
    Rect newRect = cropRect;
    final screenSize = MediaQuery.of(context).size;

    switch (_dragMode!) {
      case DragMode.move:
        newRect = cropRect.shift(delta);
        break;
      case DragMode.resizeTopLeft:
        newRect = Rect.fromPoints(
          cropRect.topLeft + delta,
          cropRect.bottomRight,
        );
        break;
      case DragMode.resizeTopRight:
        newRect = Rect.fromPoints(
          Offset(cropRect.left, cropRect.bottom),
          Offset(cropRect.right + delta.dx, cropRect.top + delta.dy),
        );
        break;
      case DragMode.resizeBottomLeft:
        newRect = Rect.fromPoints(
          Offset(cropRect.left + delta.dx, cropRect.top),
          Offset(cropRect.right, cropRect.bottom + delta.dy),
        );
        break;
      case DragMode.resizeBottomRight:
        newRect = Rect.fromPoints(
          cropRect.topLeft,
          cropRect.bottomRight + delta,
        );
        break;
    }

    double drawWidth, drawHeight;
    final imageRatio = _image!.width / _image!.height;
    final screenRatio = screenSize.width / screenSize.height;
    if (imageRatio > screenRatio) {
      drawWidth = screenSize.width;
      drawHeight = screenSize.width / imageRatio;
    } else {
      drawHeight = screenSize.height;
      drawWidth = screenSize.height * imageRatio;
    }

    newRect = Rect.fromLTWH(
      newRect.left.clamp(0.0, drawWidth - 20.0),
      newRect.top.clamp(0.0, drawHeight - 20.0),
      newRect.width.clamp(20.0, drawWidth - newRect.left),
      newRect.height.clamp(20.0, drawHeight - newRect.top),
    );

    _pendingRect = newRect;
    _lastTouch = details.localPosition;

    if (_updateTimer == null || !_updateTimer!.isActive) {
      _needsUpdate = true;
      _updateTimer = Timer(const Duration(milliseconds: 16), () {
        if (_needsUpdate && mounted) {
          setState(() {
            _rectAnimation =
                RectTween(begin: cropRect, end: _pendingRect).animate(
              CurvedAnimation(
                  parent: _animationController, curve: Curves.easeInOut),
            );
            _animationController.forward(from: 0);
            cropRect = _pendingRect!;
          });
          _needsUpdate = false;
        }
      });
    }
  }

  void _onPanEnd(DragEndDetails details) {
    _dragMode = null;
    _lastTouch = null;
  }

  Future<File> _cropImage() async {
    double x = (cropRect.left * scaleX);
    double y = (cropRect.top * scaleY);
    double width = (cropRect.width * scaleX);
    double height = (cropRect.height * scaleY);

    final imageWidth = originalImage!.width.toDouble();
    final imageHeight = originalImage!.height.toDouble();

    x = x.clamp(0.0, imageWidth - 1).roundToDouble();
    y = y.clamp(0.0, imageHeight - 1).roundToDouble();
    width = width.clamp(1.0, imageWidth - x).roundToDouble();
    height = height.clamp(1.0, imageHeight - y).roundToDouble();

    logger.i('Cropping image with: x=$x, y=$y, width=$width, height=$height, '
        'imageWidth=$imageWidth, imageHeight=$imageHeight');

    try {
      final cropped = img.copyCrop(originalImage!,
          x: x.round(),
          y: y.round(),
          width: width.round(),
          height: height.round());
      final bytes = img.encodeJpg(cropped);

      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final output = File('${tempDir.path}/cropped_$timestamp.jpg');
      await output.writeAsBytes(bytes);
      return output;
    } catch (e) {
      logger.e('Error cropping image: $e');
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Crop Fingerprint',
            style: TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            icon: const Icon(Icons.rotate_right, color: Colors.white),
            onPressed: _rotateImage,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Crop Widget is Loading...',
                    style: TextStyle(fontSize: 16, color: Colors.white),
                  ),
                  SizedBox(height: 16),
                  CircularProgressIndicator(color: Colors.white),
                ],
              ),
            )
          : GestureDetector(
              onPanStart: _onPanStart,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              child: AnimatedBuilder(
                animation: _rectAnimation,
                builder: (context, child) {
                  return CustomPaint(
                    painter: _ImagePainter(
                        _image!, _rectAnimation.value ?? cropRect),
                    child: Container(),
                  );
                },
              ),
            ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(12),
        child: _showPreview
            ? Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton(
                    onPressed: () async {
                      try {
                        final file = await _cropImage();
                        Navigator.pop(context, file);
                      } catch (e) {
                        showDialog(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: const Text('Error'),
                            content: Text('Failed to crop image: $e'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('OK'),
                              ),
                            ],
                          ),
                        );
                      }
                    },
                    child: const Text('Looks Good'),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _showPreview = false;
                      });
                    },
                    child: const Text('Re-Crop'),
                  ),
                ],
              )
            : ElevatedButton(
                onPressed: () {
                  setState(() {
                    _showPreview = true;
                  });
                },
                child: const Text('Preview Crop'),
              ),
      ),
    );
  }
}

class _ImagePainter extends CustomPainter {
  final ui.Image image;
  final Rect cropRect;

  _ImagePainter(this.image, this.cropRect);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final imageRect = Rect.fromLTWH(0, 0, size.width, size.height);
    final src =
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());

    canvas.drawImageRect(image, src, imageRect, paint);

    paint
      ..color = Colors.red
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    canvas.drawRect(cropRect, paint);

    const cornerRadius = 6.0;
    paint
      ..color = Colors.red
      ..style = PaintingStyle.fill;

    for (final corner in [
      cropRect.topLeft,
      cropRect.topRight,
      cropRect.bottomLeft,
      cropRect.bottomRight,
    ]) {
      canvas.drawCircle(corner, cornerRadius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ImagePainter oldDelegate) {
    return oldDelegate.cropRect != cropRect || oldDelegate.image != image;
  }
}

// --- NEW CODE: All the new widgets and functions from the test app are below ---

class AutoCaptureScreen extends StatefulWidget {
  final CameraDescription camera;

  const AutoCaptureScreen({super.key, required this.camera});

  @override
  State<AutoCaptureScreen> createState() => _AutoCaptureScreenState();
}

class _AutoCaptureScreenState extends State<AutoCaptureScreen> {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;

  bool _isProcessingFrame = false;
  double _clarityScore = 0.0;
  final double _captureThreshold = 600.0;

  DateTime _lastAnalysisTime = DateTime.now();
  final Duration _analysisInterval = const Duration(milliseconds: 150);

  final ValueNotifier<FlashMode> _flashMode = ValueNotifier(FlashMode.off);

  @override
  void initState() {
    super.initState();
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    _initializeControllerFuture = _controller.initialize().then((_) {
      if (mounted) {
        _controller.setFlashMode(FlashMode.off);
        _controller.setFocusMode(FocusMode.auto);
        _controller.startImageStream(_processCameraImage);
      }
    });
  }

  void _processCameraImage(CameraImage cameraImage) {
    if (DateTime.now().difference(_lastAnalysisTime) < _analysisInterval) {
      return;
    }
    _lastAnalysisTime = DateTime.now();

    if (_isProcessingFrame) return;
    _isProcessingFrame = true;

    final imageData = CameraImageData(
        cameraImage.width, cameraImage.height, cameraImage.planes[0].bytes);

    compute(computeClarityScore, imageData).then((score) {
      if (!mounted) {
        _isProcessingFrame = false;
        return;
      }

      setState(() {
        _clarityScore = score;
      });

      _isProcessingFrame = false;
    });
  }

  void _manualCapture() async {
    if (!mounted ||
        !_controller.value.isInitialized ||
        !_controller.value.isStreamingImages) {
      return;
    }

    await _controller.stopImageStream();

    try {
      // FIX: Replaced vibration with built-in haptic feedback
      HapticFeedback.mediumImpact();

      final originalImageFile = await _controller.takePicture();

      final tempDir = await getTemporaryDirectory();

      final enhancedImagePath = await Navigator.push<String?>(
        context,
        MaterialPageRoute(
          builder: (context) => PreviewScreen(
            imagePath: originalImageFile.path,
            tempDirPath: tempDir.path,
          ),
        ),
      );

      if (mounted && enhancedImagePath != null) {
        Navigator.pop(context, enhancedImagePath);
      } else if (mounted) {
        _controller.startImageStream(_processCameraImage);
      }
    } catch (e) {
      print("Error during manual capture: $e");
      if (mounted) {
        _controller.startImageStream(_processCameraImage);
      }
    }
  }

  @override
  void dispose() {
    try {
      if (_controller.value.isInitialized) {
        _controller.setFlashMode(FlashMode.off);
      }
      if (_controller.value.isStreamingImages) {
        _controller.stopImageStream();
      }
    } catch (e) {
      print("Error during dispose: $e");
    }
    _controller.dispose();
    _flashMode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(child: CameraPreview(_controller)),
                Positioned.fill(child: _buildOverlay()),
              ],
            );
          } else {
            return const Center(child: CircularProgressIndicator());
          }
        },
      ),
    );
  }

  Widget _buildOverlay() {
    final bool isQualityGood = _clarityScore > _captureThreshold;

    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
          color: Colors.black.withOpacity(0.5),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text(
                  "Move thumb until quality is high",
                  style: TextStyle(color: Colors.white, fontSize: 18),
                  textAlign: TextAlign.center,
                ),
              ),
              ValueListenableBuilder<FlashMode>(
                valueListenable: _flashMode,
                builder: (context, value, child) {
                  return IconButton(
                    icon: Icon(
                      value == FlashMode.torch
                          ? Icons.flash_on
                          : Icons.flash_off,
                      color: Colors.white,
                    ),
                    onPressed: () {
                      final newMode = value == FlashMode.torch
                          ? FlashMode.off
                          : FlashMode.torch;
                      _controller.setFlashMode(newMode);
                      _flashMode.value = newMode;
                    },
                  );
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              const Spacer(flex: 1),
              Expanded(flex: 8, child: ThumbGuide()),
              Expanded(
                flex: 1,
                child: QualityBar(
                  score: _clarityScore,
                  threshold: _captureThreshold,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.all(8.0),
          color: Colors.black.withOpacity(0.6),
          child: Text(
            "Clarity Score: ${_clarityScore.toStringAsFixed(2)}",
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 30.0, top: 20.0),
          child: ElevatedButton.icon(
            icon: const Icon(Icons.camera_alt),
            label: const Text("Capture"),
            onPressed: isQualityGood ? _manualCapture : null,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
              textStyle: const TextStyle(fontSize: 20),
              backgroundColor: isQualityGood ? Colors.green : Colors.grey,
            ),
          ),
        ),
      ],
    );
  }
}

class PreviewScreen extends StatelessWidget {
  final String imagePath;
  final String tempDirPath;
  const PreviewScreen(
      {super.key, required this.imagePath, required this.tempDirPath});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Preview & Enhance")),
      body: FutureBuilder<String>(
        future: compute(enhanceImage, EnhancementData(imagePath, tempDirPath)),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            if (snapshot.hasError || snapshot.data == null) {
              return Center(
                  child: Text("Error processing image: ${snapshot.error}"));
            }
            final enhancedPath = snapshot.data!;
            return Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Column(
                      children: [
                        const Text("Original", style: TextStyle(fontSize: 16)),
                        Expanded(child: Image.file(File(imagePath))),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Column(
                      children: [
                        const Text("Enhanced", style: TextStyle(fontSize: 16)),
                        Expanded(child: Image.file(File(enhancedPath))),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red),
                        onPressed: () {
                          Navigator.pop(context, null);
                        },
                        child: const Text("Retry"),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green),
                        onPressed: () {
                          Navigator.pop(context, enhancedPath);
                        },
                        child: const Text("Use It"),
                      ),
                    ],
                  ),
                )
              ],
            );
          }
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 20),
                Text("Enhancing Image..."),
              ],
            ),
          );
        },
      ),
    );
  }
}

class ThumbGuide extends StatelessWidget {
  const ThumbGuide({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white.withOpacity(0.7), width: 3.0),
        borderRadius: const BorderRadius.all(Radius.elliptical(120, 180)),
      ),
    );
  }
}

class QualityBar extends StatelessWidget {
  final double score;
  final double threshold;

  const QualityBar({super.key, required this.score, required this.threshold});

  @override
  Widget build(BuildContext context) {
    double progress = (score / threshold).clamp(0.0, 1.0);
    Color progressColor = progress < 0.4
        ? Colors.red
        : (progress < 0.8 ? Colors.yellow : Colors.green);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 60, horizontal: 20),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white54),
        borderRadius: BorderRadius.circular(10),
      ),
      child: RotatedBox(
        quarterTurns: 3,
        child: LinearProgressIndicator(
          value: progress,
          backgroundColor: Colors.grey.withOpacity(0.5),
          valueColor: AlwaysStoppedAnimation<Color>(progressColor),
          minHeight: 20,
        ),
      ),
    );
  }
}
