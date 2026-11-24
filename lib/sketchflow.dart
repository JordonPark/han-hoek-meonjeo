import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

class SketchFlow {
  static const _base =
      'https://github.com/JordonPark/han-hoek-meonjeo/releases/download/sketchflow-mobile-v1';
  static const _modelHash =
      '41fea316430c4992dea6d96502de3a4231fecc5956bcfc390eb6be637363f6dc';
  static const _dataHash =
      '1349bfd0d20c0498f83f1c5a0448195a70d266a5ae66d029757940db361b6962';
  static const downloadMiB = 120;
  static bool get available =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  final OrtSession _session;
  final Map<String, dynamic> _data;
  final Random _random = Random();
  Future<List<List<Offset>>>? _pending;
  bool _disposed = false;

  SketchFlow._(this._session, this._data);

  static Future<Directory> _directory() async {
    final cache = await getApplicationCacheDirectory();
    return Directory('${cache.path}/sketchflow-${_modelHash.substring(0, 12)}');
  }

  static Future<bool> isDownloaded() async {
    if (!available) return false;
    final directory = await _directory();
    return File('${directory.path}/sketchflow.onnx').existsSync() &&
        File('${directory.path}/sketchflow.json').existsSync();
  }

  static Future<SketchFlow> open({
    SketchFlowTransfer? transfer,
    void Function(double progress)? onDownload,
  }) async {
    final directory = await _directory();
    await directory.create(recursive: true);
    const dataSize = 3764098;
    const modelSize = 121792379;
    const total = dataSize + modelSize;
    Future<File> fetch(String name, String hash, int size, int previous) async {
      final file = File('${directory.path}/$name');
      if (await file.exists()) return file;
      if (transfer == null) throw StateError('The model requires a download');
      final temporary = File('${file.path}.part');
      var received = await temporary.exists() ? await temporary.length() : 0;
      if (received > size) received = 0;

      if (received != size) {
        final request = await transfer.client.getUrl(Uri.parse('$_base/$name'));
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        if (received > 0) {
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
        }
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if (response.statusCode == HttpStatus.ok) {
          received = 0;
        } else if (response.statusCode != HttpStatus.partialContent ||
            response.headers.value(HttpHeaders.contentRangeHeader) !=
                'bytes $received-${size - 1}/$size') {
          throw HttpException(
            'Unexpected model response: ${response.statusCode}',
          );
        }

        onDownload?.call((previous + received) / total);
        final sink = temporary.openWrite(
          mode: received > 0 ? FileMode.append : FileMode.write,
        );
        try {
          await sink.addStream(
            response.timeout(const Duration(seconds: 30)).map((chunk) {
              received += chunk.length;
              if (received > size) {
                throw const FormatException('Unexpected model size');
              }
              onDownload?.call((previous + received) / total);
              return chunk;
            }),
          );
        } finally {
          await sink.close();
        }
      }
      if (transfer.paused) throw StateError('Model download paused');
      if (received != size) {
        throw const FormatException('Incomplete model download');
      }
      if ((await sha256.bind(temporary.openRead()).first).toString() != hash) {
        await temporary.delete();
        throw const FormatException('SketchFlow file checksum mismatch');
      }
      return temporary.rename(file.path);
    }

    try {
      final data = await fetch('sketchflow.json', _dataHash, dataSize, 0);
      final model = await fetch(
        'sketchflow.onnx',
        _modelHash,
        modelSize,
        dataSize,
      );
      if (transfer?.paused ?? false) throw StateError('Model download paused');
      final config =
          jsonDecode(await data.readAsString()) as Map<String, dynamic>;
      final session = await OnnxRuntime().createSession(
        model.path,
        options: OrtSessionOptions(intraOpNumThreads: 3, interOpNumThreads: 1),
      );
      return SketchFlow._(session, config);
    } finally {
      transfer?.close();
    }
  }

  Future<List<List<Offset>>>? prepare(String id) {
    if (_disposed || _pending != null) return null;
    final work = _generate(id).whenComplete(() => _pending = null);
    return _pending = work;
  }

  double _gaussian() =>
      sqrt(-2 * log(1 - _random.nextDouble())) *
      cos(2 * pi * _random.nextDouble());

  Future<List<List<Offset>>> _generate(String id) async {
    final values = (_data['conditions'] as Map)[id] as List;
    final condition = await OrtValue.fromList(
      Float32List.fromList(values.cast<double>()),
      [1, 512],
    );
    final points = Float32List.fromList(List.generate(768, (_) => _gaussian()));
    try {
      for (final row in _data['steps'] as List) {
        if (_disposed) return [];
        final step = (row as List).cast<num>();
        final OrtValue input = await OrtValue.fromList(points, [1, 256, 3]);
        OrtValue? timestep;
        Map<String, OrtValue>? outputs;
        try {
          timestep = await OrtValue.fromList(
            Int64List.fromList([step[0].toInt()]),
            [1],
          );
          outputs = await _session.run({
            'points': input,
            'timestep': timestep,
            'condition': condition,
          });
          final noise = (await outputs['noise']!.asFlattenedList()).cast<num>();
          final signal = sqrt(step[1]);
          final scale = sqrt(1 - step[1]);
          for (var i = 0; i < points.length; i++) {
            final predicted = (points[i] - scale * noise[i]) / signal;
            points[i] =
                step[2] * predicted +
                step[3] * points[i] +
                (step[4] == 0 ? 0 : step[4] * _gaussian());
          }
        } finally {
          await input.dispose();
          await timestep?.dispose();
          if (outputs != null) {
            for (final output in outputs.values) {
              await output.dispose();
            }
          }
        }
      }
      return _strokes(points, (_data['penScale'] as num).toDouble());
    } finally {
      await condition.dispose();
    }
  }

  List<List<Offset>> _strokes(Float32List values, double penScale) {
    if (values.any((value) => !value.isFinite)) return [];
    final strokes = <List<Offset>>[];
    var stroke = <Offset>[];
    for (var i = 3; i < values.length; i += 3) {
      if (values[i + 2] > penScale / 2) {
        if (stroke.isEmpty) stroke.add(Offset(values[i - 3], values[i - 2]));
        stroke.add(Offset(values[i], values[i + 1]));
      } else if (stroke.isNotEmpty) {
        strokes.add(stroke);
        stroke = [];
      }
    }
    if (stroke.isNotEmpty) strokes.add(stroke);
    final points = strokes.expand((stroke) => stroke).toList();
    if (points.length < 8) return [];
    final xs = points.map((p) => p.dx);
    final ys = points.map((p) => p.dy);
    final left = xs.reduce(min), right = xs.reduce(max);
    final top = ys.reduce(min), bottom = ys.reduce(max);
    final extent = max(right - left, bottom - top);
    if (extent <= 0) return [];
    final mid = Offset((left + right) / 2, (top + bottom) / 2);
    return strokes
        .map(
          (s) => s
              .map((p) => (p - mid) * (0.85 / extent) + const Offset(0.5, 0.5))
              .toList(),
        )
        .toList();
  }

  Future<void> dispose() async {
    _disposed = true;
    try {
      await _pending;
    } catch (_) {
      // The round already handles failed inference.
    } finally {
      await _session.close();
    }
  }
}

class SketchFlowTransfer {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  bool paused = false;

  void pause() {
    paused = true;
    close();
  }

  void close() => client.close(force: true);
}
