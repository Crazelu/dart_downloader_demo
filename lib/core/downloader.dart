import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:dart_downloader/core/cancel_or_pause_token.dart';
import 'package:dart_downloader/models/download_result.dart';
import 'package:dart_downloader/core/exception.dart';
import 'package:dart_downloader/core/logger.dart';
import 'package:dart_downloader/models/download_state.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/subjects.dart';

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
  bool _justResumed = false;
  bool _canBuffer = false;
  int _totalBytes = 0;
  int _currentChunk = 1;
  int _bytesPerChunk = 0;
  int _maxChunks = 300;
  int _maxRetriesPerChunk = 3;

  String _url = "";
  String? _path;
  String? _fileName;

  late final _downloadProgressController = BehaviorSubject<int>();
  late final _formattedDownloadProgressController = BehaviorSubject<String>();
  late final _downloadStateController = BehaviorSubject<DownloadState>();

  late Completer<File?> _completer = Completer<File?>();
  final _downloadResultNotifier = ValueNotifier<DownloadResult?>(null);

  late final _fileSizeCompleter = Completer<int>();

  final _canBufferNotifier = ValueNotifier<bool>(false);
  ValueNotifier<bool> get canPauseNotifier => _canBufferNotifier;

  ///Listener attached to [_downloadResultNotifier].
  void _downloadResultListener() {
    final result = _downloadResultNotifier.value;
    if (result != null && result.isDownloadComplete) {
      _isDownloading = false;
      if (!_isCancelled && !_isPaused && !_completer.isCompleted) {
        _completer.complete(result.file);
        _downloadStateController.add(const Completed());
      }
    }
  }

  ///Listener attached to [_cancelOrPauseToken].
  void _tokenEventListener() {
    if (_isCancelled) return;

    if (_cancelOrPauseToken.eventNotifier.value == Event.cancel) {
      _isDownloading = false;
      _isCancelled = true;
      _downloadStateController.add(const Cancelled());
      _completer.completeError(DownloadCancelException());
    }
    if (_cancelOrPauseToken.eventNotifier.value == Event.pause) {
      _isDownloading = false;
      _isPaused = true;
      _downloadStateController.add(const Paused());
      _completer.completeError(DownloadPauseException());
      _completer = Completer<File?>();
    }
  }

  File? get downloadedFile => _downloadResultNotifier.value?.file;

  ///Stream of download progress in bytes.
  Stream<int> get progress => _downloadProgressController.stream;

  ///Stream of download progress formatted for readability (e.g 5.3/8.5 MB).
  Stream<String> get formattedProgress =>
      _formattedDownloadProgressController.stream;

  Stream<DownloadState> get downloadState => _downloadStateController.stream;

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
        _justResumed = true;
        _isPaused = false;
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

  ///Filename of content at [_url].
  String get downloadFileName => _fileName ?? _getFileName;

  ///Retrieves file name from [_url].
  String get _getFileName {
    try {
      return _url.split('/').last;
    } catch (e) {
      return "";
    }
  }

  ///Creates and returns a [File] with [fileName] in [_cacheDirectory]
  ///if [_path] is `null`. Otherwise, a [File] is created at [_path].
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

      _isDownloading = true;
      _downloadStateController.add(const Downloading());

      if (!_canBuffer) {
        _logger.log("Can't buffer. Downloading entire file instead");

        await _downloadEntireFile();
        return;
      }

      int tries = 1;

      while (_currentChunk <= _maxChunks && tries != _maxRetriesPerChunk) {
        final bytes = await _downloadChunk();

        if (!_isDownloading) {
          _logger.log("Download terminated");
          break;
        }

        _justResumed = false;

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
      _handleError(e);
    }
  }

  ///Size of partially (if download is in progress)
  ///or fully (if download is complete) downloaded file.
  int _downloadedBytesLength = 0;

  ///Adds download progress to streams.
  void _setDownloadProgress(int byteLength) {
    _downloadedBytesLength += byteLength;
    _downloadProgressController.add(byteLength);

    final formattedFileSize = _formatByte(_totalBytes);
    final formattedPartialDownloadedFileSize =
        _formatByte(_downloadedBytesLength);

    _formattedDownloadProgressController
        .add("$formattedPartialDownloadedFileSize/$formattedFileSize");
  }

  ///Formats bytes to a readable form
  String _formatByte(int value) {
    try {
      if (value == 0) return '0 B';

      const int K = 1024;
      const int M = K * K;
      const int G = M * K;
      const int T = G * K;

      final List<int> dividers = [T, G, M, K, 1];
      final List<String> units = ["TB", "GB", "MB", "KB", "B"];

      if (value < 0) value = value * -1;
      String result = '';
      for (int i = 0; i < dividers.length; i++) {
        final divider = dividers[i];
        if (value >= divider) {
          result = _format(value, divider, units[i]);
          break;
        }
      }
      return result;
    } catch (e) {
      return '0 B';
    }
  }

  String _format(int value, int divider, String unit) {
    final result = divider > 1 ? value / divider : value;

    if (result.toInt() == result.round()) return '${result.round()} $unit';
    return '${result.toStringAsFixed(1)} $unit';
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

      final bytesCompleter = Completer<Uint8List>();

      int startBytes;
      if (_justResumed) {
        startBytes = _downloadedBytesLength + 1;
      } else if (_currentChunk == 1) {
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

      final request = http.Request("GET", Uri.parse(_url));
      request.headers.addAll({"Range": "bytes=$startBytes-$endBytes"});
      final response = await http.Client().send(request);
      List<int> fileBytes = [];

      response.stream.listen(
        (bytes) {
          if (_isPaused || _isCancelled) return;

          _setDownloadProgress(bytes.length);
          fileBytes.addAll(bytes);
        },
        onDone: () {
          bytesCompleter.complete(Uint8List.fromList(fileBytes));
        },
        onError: (e) {
          _logger.log("_downloadChunk StreamedResponse onError-> $e");
          _handleError(e);
        },
        cancelOnError: true,
      );

      return bytesCompleter.future;
    } catch (e) {
      _logger.log("_downloadChunk -> $e");
      _handleError(e);
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

      final request = http.Request("GET", Uri.parse(_url));
      final response = await http.Client().send(request);
      List<int> fileBytes = [];

      response.stream.listen(
        (bytes) {
          if (_isPaused || _isCancelled) return;

          _setDownloadProgress(bytes.length);
          fileBytes.addAll(bytes);
        },
        onDone: () async {
          try {
            if (_isPaused || _isCancelled) return;

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
              // throw DownloaderException(
              //   message: "File at ${downloadedFile.path} already exists",
              // );
              await downloadedFile.delete();
            }

            await downloadedFile.writeAsBytes(fileBytes);

            _downloadResultNotifier.value = DownloadResult(
              file: downloadedFile,
              id: DateTime.now().toIso8601String(),
              isDownloadComplete: true,
            );
          } catch (e) {
            _logger.log("_downloadEntireFile StreamedResponse onDone -> $e");
            _handleError(e);
          }
        },
        onError: (e) {
          _logger.log("_downloadEntireFile StreamedResponse onError-> $e");
          _handleError(e);
        },
        cancelOnError: true,
      );

      return _completer.future;
    } catch (e) {
      _logger.log("_downloadEntireFile -> $e");
      _handleError(e);
    }

    return null;
  }

  void _handleError(
    Object error, {
    bool rethrowOnlyOwnedException = true,
  }) {
    _downloadStateController.add(const Cancelled());
    if (rethrowOnlyOwnedException && error is DownloaderException) {
      throw error;
    } else {
      throw error;
    }
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

      result ~/= 3;
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

    _maxChunks = _getMaxChunks(_totalBytes);
    _bytesPerChunk = _totalBytes ~/ _maxChunks;
    _canBufferNotifier.value = _canBuffer;
  }

  ///Pauses download.
  void pause() {
    if (_canBuffer && _isDownloading) {
      _isDownloading = false;
      _cancelOrPauseToken.pause();
    }

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
      if (_isCancelled || !_isPaused) {
        throw const DownloaderException(
          message:
              "No active download session found. Only call this when there's a paused download.",
        );
      }

      if (_completer.isCompleted) {
        _completer = Completer<File?>();
      }
      _cancelOrPauseToken.resume();
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
    _downloadStateController.close();
    _downloadResultNotifier.dispose();
    _canBufferNotifier.dispose();
  }
}
