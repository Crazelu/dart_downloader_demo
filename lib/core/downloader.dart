import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:dart_downloader/core/cancel_or_pause_token.dart';
import 'package:dart_downloader/models/download_result.dart';
import 'package:dart_downloader/core/exception.dart';
import 'package:dart_downloader/core/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class Downloader {
  late final CancelOrPauseToken _cancelOrPauseToken;

  Downloader() {
    _cancelOrPauseToken = CancelOrPauseToken();
    _cancelOrPauseToken.eventNotifier.addListener(_tokenEventListener);
    _downloadResultNotifier.addListener(_downloadResultListener);
  }

  late final _logger = Logger(Downloader);

  static const _cacheDirectory = "cacheDirectory";

  bool _isDownloading = false;
  bool _isPaused = false;
  bool _isCancelled = false;
  bool _canBuffer = false;
  int _totalBytes = 0;
  int _currentChunk = 1;
  int _bytesPerChunk = 0;
  int _maxChunks = 300;
  int _maxRetriesPerChunk = 3;

  String _url = "";
  String? _path;
  String? _fileName;

  late final _downloadProgressController = StreamController<int>();
  late final _formattedDownloadProgressController = StreamController<String>();

  late Completer<File?> _completer = Completer<File?>();
  final _downloadResultNotifier = ValueNotifier<DownloadResult?>(null);
  late final _fileSizeCompleter = Completer<int>();

  ///Listener attached to [_downloadResultNotifier].
  void _downloadResultListener() {
    final result = _downloadResultNotifier.value;
    if (result != null && result.isDownloadComplete) {
      _isDownloading = false;
      if (!_isCancelled && !_isPaused && !_completer.isCompleted) {
        _completer.complete(result.file);
      }
    }
  }

  ///Listener attached to [_cancelOrPauseToken].
  void _tokenEventListener() {
    if (_isCancelled) return;

    if (_cancelOrPauseToken.eventNotifier.value == Event.cancel) {
      _isDownloading = false;
      _isCancelled = true;
      _completer.completeError(DownloadCancelException());
    }
    if (_cancelOrPauseToken.eventNotifier.value == Event.pause) {
      _isDownloading = false;
      _isPaused = true;
      _completer.completeError(DownloadPauseException());
      _completer = Completer<File?>();
    }
  }

  ///Stream of download progress in bytes.
  Stream<int> get progress => _downloadProgressController.stream;

  ///Stream of download progress formatted for readability (e.g 5.3/8.5 MB).
  Stream<String> get formattedProgress =>
      _formattedDownloadProgressController.stream;

  ///Size of file to be downloaded in bytes.
  Future<int> get getFileSize async {
    if (_fileSizeCompleter.isCompleted) {
      return _totalBytes;
    }
    return _fileSizeCompleter.future;
  }

  ///Loads metadata and queues chunk downloads if buffering is supported.
  ///If buffering isn't supported, the entire file is downloaded in one go.
  ///
  ///Metadata is not reloaded on [resumingDownload].
  Future<File?> download({
    required String url,
    bool resumingDownload = false,
    String? path,
    String? fileName,
    int? maxChunks,
    int? retryCount,
  }) async {
    try {
      if (resumingDownload) {
        _queueDownloads();
        return _completer.future;
      }

      _url = url;
      _path = path;
      _fileName = fileName;
      _maxChunks = maxChunks ?? _maxChunks;
      _maxRetriesPerChunk = retryCount ?? _maxRetriesPerChunk;

      await _loadMetadata();

      _queueDownloads();

      return _completer.future;
    } on DownloaderException catch (e) {
      _logger.log(e.message);
      return null;
    } catch (e) {
      _logger.log("download -> $e");
      rethrow;
    }
  }

  ///Retrieves file name from [_url].
  String get _getFileName {
    try {
      return _url.split('/').last;
    } catch (e) {
      return "";
    }
  }

  ///Creates and returns a [File] with [fileName] in [directory].
  Future<File> _getFile(String fileName) async {
    if (_path != null) return File(_path!);

    final dir = await getApplicationDocumentsDirectory();
    String fileDirectory = "${dir.path}/$_cacheDirectory";

    await Directory(fileDirectory).create(recursive: true);

    return File("$fileDirectory/$fileName");
  }

  ///Queues chunk downloads with retries if buffering is supported.
  ///Otherwise, the entire audio content is downloaded once.
  Future<void> _queueDownloads() async {
    try {
      final fileName = _fileName ?? _getFileName;
      if (fileName.isEmpty) {
        throw const DownloaderException(
          message: "Unable to determine file name",
        );
      }

      if (!_canBuffer) {
        _logger.log("Can't buffer. Downloading entire file instead");

        await _downloadEntireFile();
        return;
      }

      int tries = 1;

      while (_currentChunk <= _maxChunks && tries != _maxRetriesPerChunk) {
        final bytes = await _downloadChunk();

        if (!_isDownloading) break;

        if (bytes.isNotEmpty) {
          //write to file
          final downloadedFile =
              _downloadResultNotifier.value?.file ?? await _getFile(fileName);

          await downloadedFile.writeAsBytes(
            bytes,
            mode: _currentChunk == 1 ? FileMode.write : FileMode.append,
          );

          _currentChunk++;
          tries = 0;

          _downloadResultNotifier.value = DownloadResult(
            file: downloadedFile,
            id: DateTime.now().toIso8601String(),
            isDownloadComplete: _currentChunk >= _maxChunks,
          );
        } else {
          tries++;
        }
      }
    } catch (e) {
      _logger.log("_queueDownloads -> $e");
      if (e is DownloaderException) rethrow;
    }
  }

  ///Downloads file chunk from [_url] in the current range
  ///specified by [_currentChunk] and [_bytesPerChunk] and returns the downloaded bytes.
  Future<Uint8List> _downloadChunk() async {
    try {
      final fileName = _fileName ?? _getFileName;
      if (fileName.isEmpty) {
        throw const DownloaderException(
          message: "Unable to determine file name",
        );
      }

      int startBytes;
      if (_currentChunk == 1) {
        startBytes = 0;
      } else {
        startBytes = ((_currentChunk - 1) * _bytesPerChunk) + 1;
      }

      int endBytes = _currentChunk * _bytesPerChunk;
      if (endBytes > _totalBytes) {
        endBytes = _totalBytes;
      }

      _logger.log(
          "($fileName) -> Starting chunk download for range $startBytes-$endBytes");

      final response = await http.get(
        Uri.parse(_url),
        headers: {"Range": "bytes=$startBytes-$endBytes"},
      );

      return response.bodyBytes;
    } catch (e) {
      _logger.log("_downloadChunk -> $e");
      if (e is DownloaderException) rethrow;
    }
    return Uint8List.fromList([]);
  }

  ///Downloads the entire file from [_url].
  Future<File?> _downloadEntireFile() async {
    try {
      String fileName = _fileName ?? _getFileName;
      if (fileName.isEmpty) {
        throw const DownloaderException(
          message: "Unable to determine file name",
        );
      }

      final response = await http.get(Uri.parse(_url));
      final fileBytes = response.bodyBytes;

      File downloadedFile;

      if (_path != null) {
        downloadedFile = File(_path!);
      } else {
        final dir = await getApplicationDocumentsDirectory();
        String fileDirectory = "${dir.path}/$_cacheDirectory";

        await Directory(fileDirectory).create(recursive: true);
        downloadedFile = File("$fileDirectory/$fileName");
      }

      if (await downloadedFile.exists()) {
        throw DownloaderException(
          message: "File at ${downloadedFile.path} already exists",
        );
      }

      await downloadedFile.writeAsBytes(fileBytes);

      _downloadResultNotifier.value = DownloadResult(
        file: downloadedFile,
        id: DateTime.now().toIso8601String(),
        isDownloadComplete: true,
      );

      return _completer.future;
    } catch (e) {
      _logger.log("_downloadEntireFile -> $e");
      if (e is DownloaderException) rethrow;
    }

    return null;
  }

  ///Computes maximum chunks allowed for [totalBytes].
  int _getMaxChunks(int totalBytes) {
    try {
      if (totalBytes == 0) {
        _cancelOrPauseToken.cancel();
        return 0;
      }

      const int K = 1024;
      const int M = K * K;
      const int G = M * K;
      const int T = G * K;

      final List<int> dividers = [T, G, M, K, 1];

      int result = 10;

      for (int i = 0; i < dividers.length; i++) {
        final divider = dividers[i];
        if (totalBytes >= divider) {
          if (i >= 3) return 1;
          result = math.pow(10, 3 - i).toInt();
          break;
        }
      }
      if (result > _maxChunks) return _maxChunks;
      return result;
    } catch (e) {
      _logger.log(e);
      return 1;
    }
  }

  ///Loads file metadata including file size in bytes and flag for whether
  ///buffered download is possible.
  Future<void> _loadMetadata() async {
    final response = await http.head(Uri.parse(_url));
    final headers = response.headers;

    _canBuffer = headers["accept-ranges"] == "bytes";
    _totalBytes = int.parse(headers["content-length"] ?? "0");

    if (!_fileSizeCompleter.isCompleted) {
      _fileSizeCompleter.complete(_totalBytes);
    }

    _bytesPerChunk = _totalBytes ~/ _getMaxChunks(_totalBytes);
  }

  ///Pauses download.
  void pause() {
    if (_canBuffer && _isDownloading) _cancelOrPauseToken.pause();

    if (!_canBuffer) {
      _logger.log(
        "This download cannot be paused and resumed as the file server doesn't support buffering.",
      );
    }
  }

  ///Resumes download.
  ///This must be called only when a download has been paused.
  ///Calling this in a non paused state will throw [DownloaderException].
  Future<File?> resume() async {
    try {
      if (!_isPaused) {
        throw const DownloaderException(
          message:
              "No active download session found. Only call this when there's a paused download.",
        );
      }

      if (_completer.isCompleted) {
        _completer = Completer<File?>();
      }
      return await download(url: _url, resumingDownload: true);
    } catch (e) {
      _logger.log("resume -> $e");
    }
    return null;
  }

  ///Cancels download.
  void cancel() {
    if (!_isCancelled) _cancelOrPauseToken.cancel();
  }

  ///Releases resources.
  void dispose() {
    _cancelOrPauseToken.eventNotifier.removeListener(_tokenEventListener);
    _downloadResultNotifier.removeListener(_downloadResultListener);
    _cancelOrPauseToken.dispose();
    _downloadProgressController.close();
    _formattedDownloadProgressController.close();
  }
}
