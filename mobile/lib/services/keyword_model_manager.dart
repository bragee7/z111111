import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// On-device model bundle for the Zipformer keyword spotter.
///
/// KWS-ONLY (no speech-to-text stage): the spotter hears trigger WORDS
/// directly from the mic stream, so the download stays small (~13 MB) and
/// detection latency stays low. Full-fp32 CPU build — the mobile int8
/// variant SIGABRTs in Reshape/downsample, never use it.
class KwsModelPaths {
  const KwsModelPaths({
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
  });

  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;
}

typedef KwsProgress = void Function(String stage, int done, int total);

class KeywordModelManager {
  static const kwsUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/'
      'sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2';

  /// The model files are shipped INSIDE the APK (assets/kws/), so the
  /// listener works from the very first launch with no network at all.
  /// int8 encoder + int8 joiner + int8 decoder: measured identical to fp32
  /// (100% recall on the 40-clip benchmark) at 5.2 MB instead of 13.7 MB.
  static const _bundled = <String>[
    'encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
    'decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
    'joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
    'tokens.txt',
  ];

  static const _encoderName =
      'encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx';
  static const _decoderName =
      'decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx';
  static const _joinerName =
      'joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx';
  static const _tokensName = 'tokens.txt';

  /// Fallback names, in case a future bundle ships fp32 only.
  static const _encoderFp32 = 'encoder-epoch-12-avg-2-chunk-16-left-64.onnx';
  static const _decoderFp32 = 'decoder-epoch-12-avg-2-chunk-16-left-64.onnx';
  static const _joinerFp32 = 'joiner-epoch-12-avg-2-chunk-16-left-64.onnx';

  static Future<Directory> _bundleDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/sherpa_kws');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _p(Directory dir, String name) => '${dir.path}/$name';

  static bool _readyIn(Directory dir) {
    for (final name in _bundled) {
      if (!File(_p(dir, name)).existsSync()) return false;
    }
    return true;
  }

  static KwsModelPaths _pathsIn(Directory dir) => KwsModelPaths(
        encoder: _p(dir, _encoderName),
        decoder: _p(dir, _decoderName),
        joiner: _p(dir, _joinerName),
        tokens: _p(dir, _tokensName),
      );

  /// Previously downloaded bundle, or null when nothing is cached yet
  /// (first run — the background isolate downloads it on toggle-ON).
  static Future<KwsModelPaths?> cachedPaths() async {
    final dir = await _bundleDir();
    if (!_readyIn(dir)) return null;
    return _pathsIn(dir);
  }

  /// Copies the model out of the APK into the app's private storage.
  ///
  /// sherpa-onnx needs real file paths, and the APK's assets are compressed
  /// and not seekable, so the files are unpacked once. ~5 MB, well under a
  /// second, and it means the voice guard never needs the network.
  static Future<KwsModelPaths?> _fromBundledAssets() async {
    try {
      final dir = await _bundleDir();
      if (_readyIn(dir)) return _pathsIn(dir);
      onProgress?.call('unpacking', 0, _bundled.length);
      var done = 0;
      for (final name in _bundled) {
        final target = File(_p(dir, name));
        if (!await target.exists()) {
          final data = await rootBundle.load('assets/kws/$name');
          await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
        }
        done++;
        onProgress?.call('unpacking', done, _bundled.length);
      }
      if (!_readyIn(dir)) return null;
      return _pathsIn(dir);
    } catch (_) {
      return null;
    }
  }

  /// Progress callback for the last operation (set by the caller).
  static KwsProgress? onProgress;

  static Future<KwsModelPaths> ensureBundle({KwsProgress? onProgress}) async {
    // 1) the copy shipped inside the APK - no network, instant.
    final bundled = await _fromBundledAssets();
    if (bundled != null) return bundled;

    // 2) fall back to downloading (only if the APK copy is missing/corrupt).
    final dir = await _bundleDir();

    String p(String name) => _p(dir, name);

    bool ready() => _readyIn(dir);

    KwsModelPaths paths() => _pathsIn(dir);

    // Cached from a previous run — no download, instant start.
    if (ready()) return paths();

    final tmp = File('${dir.path}/bundle.tar.bz2');
    try {
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(kwsUrl));
        final resp = await req.close();
        if (resp.statusCode != 200) {
          throw 'KWS download HTTP ${resp.statusCode}';
        }
        final total = resp.contentLength;
        final sink = tmp.openWrite();
        int done = 0;
        await for (final chunk in resp) {
          done += chunk.length;
          sink.add(chunk);
          onProgress?.call('downloading', done, total <= 0 ? done : total);
        }
        await sink.close();
      } finally {
        client.close();
      }
      onProgress?.call('extracting', 0, 1);
      final raw = await tmp.readAsBytes();
      final tarBytes = BZip2Decoder().decodeBytes(raw);
      final archive = TarDecoder().decodeBytes(tarBytes);
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final base = entry.name.split('/').last;
        if (!_wanted.contains(base)) continue;
        await File(p(base)).writeAsBytes(entry.content as List<int>);
      }
      onProgress?.call('extracting', 1, 1);
    } finally {
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
    }

    if (!ready()) throw 'KWS bundle incomplete after download';
    return paths();
  }

  static const _wanted = <String>{
    _encoderName,
    _decoderName,
    _joinerName,
    _tokensName,
    _encoderFp32,
    _decoderFp32,
    _joinerFp32,
  };

  /// First-column BPE tokens (e.g. `▁HELP`), uppercased. Used to validate
  /// custom trigger words BEFORE they reach the spotter — a word the
  /// bundle cannot tokenize could never fire, so it is rejected with a
  /// clear error instead of silently never working.
  static Future<Set<String>> loadTokenSet(String tokensPath) async {
    final lines = await File(tokensPath).readAsLines();
    final set = <String>{};
    for (final line in lines) {
      final token = line.split(' ').first.trim();
      if (token.isNotEmpty) set.add(token.toUpperCase());
    }
    return set;
  }

  /// The build-time keyword table: exact BPE segmentation for the common
  /// emergency phrases, generated with `sherpa-onnx-cli text2token` and
  /// shipped in the APK.
  ///
  /// Format per line: `<bpe tokens> @<PHRASE>`.
  ///
  /// This exists because a hand-rolled "▁" + whole-word join is wrong for
  /// most phrases: the model's BPE splits "EMERGENCY" into
  /// "▁E M ER G EN C Y" and "SAVE ME" into "▁SA VE ▁ME", so the whole-word
  /// form does not exist in the vocabulary and the trigger could never fire.
  static Future<Map<String, String>> loadKeywordTokens() async {
    final out = <String, String>{};
    try {
      final raw = await rootBundle.loadString('assets/kws_keywords.txt');
      for (final line in raw.split('\n')) {
        final t = line.trim();
        if (t.isEmpty) continue;
        final i = t.indexOf('@');
        if (i <= 0) continue;
        final tokens = t.substring(0, i).trim();
        final phrase = t.substring(i + 1).trim().toUpperCase();
        if (tokens.isEmpty || phrase.isEmpty) continue;
        out[phrase] = tokens;
      }
    } catch (_) {
      // Table missing: fall back to the whole-word tokenisation.
    }
    return out;
  }
}
