import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app_links/app_links.dart';
import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfx/pdfx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:google_fonts/google_fonts.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _cleanupTempFiles();
  runApp(const MyApp());
}

Future<void> _cleanupTempFiles() async {
  try {
    final tempDir = await getTemporaryDirectory();
    final files = tempDir.listSync();
    for (var file in files) {
      if (file.path.contains('decrypted_view') ||
          file.path.contains('shared_')) {
        try {
          file.deleteSync();
        } catch (e) {
          debugPrint("Could not delete: ${file.path}");
        }
      }
    }
  } catch (e) {
    debugPrint("Cleanup error: $e");
  }
}

const platform = MethodChannel('signature.channel');

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.interTextTheme(ThemeData.light().textTheme)
            .copyWith(
              displayLarge: GoogleFonts.poppins(fontWeight: FontWeight.bold),
              displayMedium: GoogleFonts.poppins(fontWeight: FontWeight.bold),
              displaySmall: GoogleFonts.poppins(fontWeight: FontWeight.bold),
              headlineLarge: GoogleFonts.poppins(fontWeight: FontWeight.w600),
              headlineMedium: GoogleFonts.poppins(fontWeight: FontWeight.w600),
              headlineSmall: GoogleFonts.poppins(fontWeight: FontWeight.w600),
              titleLarge: GoogleFonts.poppins(fontWeight: FontWeight.w600),
              titleMedium: GoogleFonts.poppins(fontWeight: FontWeight.w500),
              titleSmall: GoogleFonts.poppins(fontWeight: FontWeight.w500),
            ),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme)
            .copyWith(
              displayLarge: GoogleFonts.poppins(fontWeight: FontWeight.bold),
              displayMedium: GoogleFonts.poppins(fontWeight: FontWeight.bold),
              displaySmall: GoogleFonts.poppins(fontWeight: FontWeight.bold),
              headlineLarge: GoogleFonts.poppins(fontWeight: FontWeight.w600),
              headlineMedium: GoogleFonts.poppins(fontWeight: FontWeight.w600),
              headlineSmall: GoogleFonts.poppins(fontWeight: FontWeight.w600),
              titleLarge: GoogleFonts.poppins(fontWeight: FontWeight.w600),
              titleMedium: GoogleFonts.poppins(fontWeight: FontWeight.w500),
              titleSmall: GoogleFonts.poppins(fontWeight: FontWeight.w500),
            ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool isProcessing = false;
  String? processingMessage;
  final _appLinks = AppLinks();

  @override
  void initState() {
    super.initState();
    _initIncomingLinks();
  }

  void _initIncomingLinks() async {
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        _prepareFileFromUri(initialUri.toString());
      }
    } catch (e) {
      debugPrint("Initial link error: $e");
    }

    _appLinks.uriLinkStream.listen(
      (uri) {
        _prepareFileFromUri(uri.toString());
      },
      onError: (err) {
        debugPrint("Link stream error: $err");
      },
    );
  }

  Future<void> _prepareFileFromUri(String uriString) async {
    try {
      String? filePath;

      if (uriString.startsWith('content://')) {
        filePath = await platform.invokeMethod('getPathFromUri', {
          'uri': uriString,
        });
      } else if (uriString.startsWith('file://')) {
        filePath = Uri.parse(uriString).toFilePath();
      } else {
        filePath = uriString;
      }

      if (filePath != null && filePath.isNotEmpty) {
        _decryptFile(File(filePath));
      } else {
        _showError("Could not access file");
      }
    } catch (e) {
      _showError("Could not resolve file path: $e");
    }
  }

  Future<SecretKey> deriveKey() async {
    final String signature = await platform.invokeMethod('getSignature');
    final bytes = utf8.encode(signature);
    final hash = await Sha256().hash(bytes);
    return SecretKey(hash.bytes);
  }

  Future<void> _encryptFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );

    if (result == null || result.files.single.path == null) return;

    if (!mounted) return;

    setState(() {
      isProcessing = true;
      processingMessage = 'Encrypting PDF...';
    });

    try {
      final file = File(result.files.single.path!);
      final key = await deriveKey();
      final aes = AesGcm.with256bits();
      final pdfBytes = await file.readAsBytes();

      final secretBox = await aes.encrypt(pdfBytes, secretKey: key);

      // Combine: nonce (12 bytes) + ciphertext + MAC (16 bytes)
      final encryptedData = Uint8List.fromList([
        ...secretBox.nonce,
        ...secretBox.cipherText,
        ...secretBox.mac.bytes,
      ]);

      // Save with .fsbd extension
      final originalName = result.files.single.name.replaceAll('.pdf', '');
      final downloadsDir = Directory('/storage/emulated/0/Download');
      final outputFile = File('${downloadsDir.path}/$originalName.fsbd');

      await outputFile.writeAsBytes(encryptedData);

      if (!mounted) return;

      _showSuccess('Encrypted successfully!\nSaved to: ${outputFile.path}');

      // Optionally share the file
      await Share.shareXFiles([
        XFile(outputFile.path),
      ], subject: 'Encrypted File: $originalName.fsbd');
    } catch (e) {
      _showError("Encryption Failed: $e");
    } finally {
      if (mounted) {
        setState(() {
          isProcessing = false;
          processingMessage = null;
        });
      }
    }
  }

  Future<void> _decryptFile(File file) async {
    if (!mounted) return;

    setState(() {
      isProcessing = true;
      processingMessage = 'Decrypting file...';
    });

    try {
      final key = await deriveKey();
      final aes = AesGcm.with256bits();
      final data = await file.readAsBytes();

      if (data.length < 28) throw Exception("Invalid file size.");

      final nonce = data.sublist(0, 12);
      final macBytes = data.sublist(data.length - 16);
      final cipherText = data.sublist(12, data.length - 16);

      final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));
      final decryptedBytes = await aes.decrypt(secretBox, secretKey: key);

      final tempDir = await getTemporaryDirectory();
      final tempFile = File(
        '${tempDir.path}/decrypted_view_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
      await tempFile.writeAsBytes(decryptedBytes);

      if (!mounted) return;

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => PDFScreen(
            path: tempFile.path,
            onDispose: () async {
              try {
                if (await tempFile.exists()) {
                  await tempFile.delete();
                }
              } catch (e) {
                debugPrint("Could not delete temp file: $e");
              }
            },
          ),
        ),
      );
    } catch (e) {
      _showError("Decryption Failed: $e");
    } finally {
      if (mounted) {
        setState(() {
          isProcessing = false;
          processingMessage = null;
        });
      }
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                msg,
                style: GoogleFonts.inter(fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  void _showSuccess(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle_outline, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                msg,
                style: GoogleFonts.inter(fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [const Color(0xFF1E1E2E), const Color(0xFF2A2A3E)]
                : [const Color(0xFFF8F9FF), const Color(0xFFE8EAFF)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Custom App Bar
              Container(
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Dhinesh Secure Vault',
                            style: GoogleFonts.poppins(
                              fontSize: 23,
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: isProcessing
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(32),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surface,
                                  borderRadius: BorderRadius.circular(24),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.1),
                                      blurRadius: 30,
                                      offset: const Offset(0, 15),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  children: [
                                    SizedBox(
                                      width: 60,
                                      height: 60,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 4,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    Text(
                                      processingMessage ?? 'Processing...',
                                      style: GoogleFonts.poppins(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          )
                        : SingleChildScrollView(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.start,
                              children: [
                                // Hero Icon
                                Container(
                                  padding: const EdgeInsets.all(28),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [
                                        Theme.of(
                                          context,
                                        ).colorScheme.primary.withOpacity(0.1),
                                        Theme.of(
                                          context,
                                        ).colorScheme.primary.withOpacity(0.05),
                                      ],
                                    ),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.lock_person_rounded,
                                    size: 90,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                ),
                                const SizedBox(height: 32),

                                // Title
                                Text(
                                  'Secure Your Files',
                                  style: GoogleFonts.poppins(
                                    fontSize: 28,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 12),

                                // Subtitle
                                Text(
                                  'Protect your files with .fsbd encryption\n(Files Secured By Dhinesh)',
                                  style: GoogleFonts.inter(
                                    fontSize: 16,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface.withOpacity(0.6),
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 32),

                                // Action Cards
                                _buildActionCard(
                                  context,
                                  icon: Icons.lock_outline,
                                  title: 'Encrypt PDF',
                                  subtitle: 'Secure with .fsbd',
                                  gradient: LinearGradient(
                                    colors: [
                                      Theme.of(context).colorScheme.primary,
                                      Theme.of(
                                        context,
                                      ).colorScheme.primary.withOpacity(0.8),
                                    ],
                                  ),
                                  onTap: _encryptFile,
                                ),
                                const SizedBox(height: 16),

                                _buildActionCard(
                                  context,
                                  icon: Icons.lock_open_outlined,
                                  title: 'Decrypt & View',
                                  subtitle: 'View .fsbd files',
                                  gradient: LinearGradient(
                                    colors: [
                                      Theme.of(context).colorScheme.secondary,
                                      Theme.of(
                                        context,
                                      ).colorScheme.secondary.withOpacity(0.8),
                                    ],
                                  ),
                                  onTap: () async {
                                    final result = await FilePicker.platform
                                        .pickFiles(
                                          type: FileType.custom,
                                          allowedExtensions: ['fsbd'],
                                        );
                                    if (result != null &&
                                        result.files.single.path != null) {
                                      _decryptFile(
                                        File(result.files.single.path!),
                                      );
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Gradient gradient,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Ink(
            decoration: BoxDecoration(
              gradient: gradient,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(icon, size: 32, color: Colors.white),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: GoogleFonts.poppins(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            color: Colors.white.withOpacity(0.9),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.arrow_forward_ios,
                    color: Colors.white,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PDFScreen extends StatefulWidget {
  final String path;
  final VoidCallback? onDispose;

  const PDFScreen({super.key, required this.path, this.onDispose});

  @override
  State<PDFScreen> createState() => _PDFScreenState();
}

class _PDFScreenState extends State<PDFScreen> {
  late PdfController pdfController;
  int currentPage = 1;
  int totalPages = 0;
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _initPdf();
  }

  void _initPdf() async {
    try {
      pdfController = PdfController(
        document: PdfDocument.openFile(widget.path),
      );

      final document = await PdfDocument.openFile(widget.path);
      setState(() {
        totalPages = document.pagesCount;
        isLoading = false;
      });
    } catch (e) {
      debugPrint("PDF init error: $e");
      setState(() {
        isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    pdfController.dispose();
    widget.onDispose?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return WillPopScope(
      onWillPop: () async {
        // Ensure file is deleted when back button is pressed
        widget.onDispose?.call();
        return true;
      },
      child: Scaffold(
        extendBodyBehindAppBar: false,
        appBar: AppBar(
          title: Text(
            "Secure Viewer",
            style: GoogleFonts.poppins(
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          elevation: 0,
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Colors.white,
          actions: [
            if (totalPages > 0)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 16.0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.3),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      '$currentPage / $totalPages',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: isDark
                  ? [const Color(0xFF1E1E2E), const Color(0xFF2A2A3E)]
                  : [const Color(0xFFF5F5F5), const Color(0xFFE8E8E8)],
            ),
          ),
          child: isLoading
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Loading PDF...',
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                )
              : Stack(
                  children: [
                    PdfView(
                      controller: pdfController,
                      scrollDirection: Axis.vertical,
                      pageSnapping: false,
                      physics: const BouncingScrollPhysics(),
                      onPageChanged: (page) {
                        setState(() {
                          currentPage = page;
                        });
                      },
                      onDocumentLoaded: (document) {
                        setState(() {
                          totalPages = document.pagesCount;
                        });
                      },
                      onDocumentError: (error) {
                        debugPrint("Document error: $error");
                      },
                    ),
                    // Watermark overlay to prevent screenshots
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Colors.transparent,
                                Theme.of(
                                  context,
                                ).colorScheme.primary.withOpacity(0.02),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        bottomNavigationBar: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 10,
                offset: const Offset(0, -5),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.info_outline,
                size: 16,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                'This file is view-only and cannot be downloaded',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
