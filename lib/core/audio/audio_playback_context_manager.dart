import 'package:flutter/foundation.dart';

///A utility for managing audio playback sessions.
///This makes sure only one session exists at a time and there are no
///multiple playbacks happening simultaneously.
class AudioPlaybackContextManager {
  AudioPlaybackContextManager._();

  static VoidCallback? _pauseAudio;

  ///Register a callback to pause audio before starting the playback
  static void registerPauseAudioCallback(VoidCallback callback) {
    _pauseAudio = callback;
  }

  ///When a new audio session is about to commence/resume,
  ///call this to pause the last playing session.
  static void onPlaybackStarted() {
    _pauseAudio?.call();
  }
}
