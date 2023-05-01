import 'package:flutter/material.dart';

class DartDownloaderView extends StatefulWidget {
  const DartDownloaderView({super.key});

  @override
  State<DartDownloaderView> createState() => _DartDownloaderViewState();
}

class _DartDownloaderViewState extends State<DartDownloaderView> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Dart Downloader Demo"),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Text("Hi you're here"),
          ],
        ),
      ),
    );
  }
}
