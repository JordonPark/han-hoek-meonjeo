import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

enum GameSound { countdown, start, correct, wrong, finish }

class GameAudio {
  bool musicEnabled = true;
  bool effectsEnabled = true;

  AudioPlayer? _music;
  AudioPlayer? _effect;
  Future<void> _operations = Future<void>.value();
  bool _active = true;
  bool _closed = false;
  bool _inRound = false;

  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  Future<AudioPlayer> _createPlayer() async {
    final player = AudioPlayer();
    try {
      await player.setAudioContext(
        AudioContext(
          iOS: AudioContextIOS(category: AVAudioSessionCategory.ambient),
          android: const AudioContextAndroid(
            usageType: AndroidUsageType.game,
            contentType: AndroidContentType.music,
            audioFocus: AndroidAudioFocus.none,
          ),
        ),
      );
      return player;
    } on Exception {
      await player.dispose();
      rethrow;
    }
  }

  void _enqueue(Future<void> Function() operation) {
    if (!_supported || _closed) return;
    _operations = _operations.then((_) async {
      try {
        await operation();
      } on Exception catch (error) {
        debugPrint('Game audio unavailable: $error');
      }
    });
  }

  void play(GameSound sound) {
    if (!_active || !effectsEnabled) return;
    _enqueue(() async {
      if (!_active || !effectsEnabled || _closed) return;
      final player = _effect ??= await _createPlayer();
      await player.stop();
      await player.play(AssetSource('audio/${sound.name}.wav'), volume: 0.7);
    });
  }

  void setRoundPlaying(bool playing) {
    _inRound = playing;
    _syncMusic();
  }

  void setActive(bool active) {
    _active = active;
    _syncMusic();
    if (!active) _enqueue(() async => _effect?.stop());
  }

  void saveSettings({required bool music, required bool effects}) {
    musicEnabled = music;
    effectsEnabled = effects;
    _syncMusic();
    if (!effectsEnabled) _enqueue(() async => _effect?.stop());
  }

  void _syncMusic() {
    _enqueue(() async {
      if (!_active || !musicEnabled || !_inRound || _closed) {
        await _music?.stop();
        return;
      }
      final player = _music ??= await _createPlayer();
      if (player.state == PlayerState.playing) return;
      await player.setReleaseMode(ReleaseMode.loop);
      await player.play(AssetSource('audio/music.wav'), volume: 0.32);
    });
  }

  void dispose() {
    if (_closed) return;
    _enqueue(() async {
      try {
        await _effect?.dispose();
      } finally {
        await _music?.dispose();
      }
    });
    _closed = true;
  }
}
