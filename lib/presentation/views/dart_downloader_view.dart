import 'package:dart_downloader/core/downloader.dart';
import 'package:dart_downloader/models/download_request.dart';
import 'package:dart_downloader/presentation/widgets/file_download_widget.dart';
import 'package:flutter/material.dart';

class DartDownloaderView extends StatefulWidget {
  const DartDownloaderView({super.key});

  @override
  State<DartDownloaderView> createState() => _DartDownloaderViewState();
}

class _DartDownloaderViewState extends State<DartDownloaderView> {
  late final List<Downloader> _downloaders = [];

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadFiles);
  }

  @override
  void dispose() {
    for (var downloader in _downloaders) {
      downloader.dispose();
    }
    super.dispose();
  }

  void _loadFiles() {
    for (var _ in DownloadRequest.requests) {
      final newDownloader = Downloader();
      _downloaders.add(newDownloader);
    }
    setState(() {});
  }

  void _download() {
    for (int i = 0; i < DownloadRequest.requests.length; i++) {
      final downloader = _downloaders[i];
      downloader.download(url: DownloadRequest.requests[i].url);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Dart Downloader Demo"),
      ),
      body: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                style: ButtonStyle(
                  backgroundColor: MaterialStateProperty.resolveWith(
                    (states) => Theme.of(context).primaryColor,
                  ),
                  foregroundColor: MaterialStateProperty.resolveWith(
                    (states) => Theme.of(context).primaryColorLight,
                  ),
                ),
                child: const Text("Download Files"),
                onPressed: () {
                  _download();
                },
              ),
            ),
            const SizedBox(height: 20),
            for (int i = 0; i < _downloaders.length; i++)
              FileDownloadWidget(
                fileName: _downloaders[i].downloadFileName,
                downloader: _downloaders[i],
                showPlayButton: DownloadRequest.requests[i].canPlay,
              ),
          ],
        ),
      ),
    );
  }
}
