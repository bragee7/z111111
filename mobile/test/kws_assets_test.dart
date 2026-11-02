
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the two things that silently break the voice guard:
///
///  1. a keyword whose BPE tokens do not exist in the model's vocabulary can
///     NEVER fire - the spotter simply never matches it;
///  2. a model file missing from the APK means the engine has to download
///     (or fails), so it is not "works offline from the first launch".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('bundled KWS model', () {
    test('all model files ship inside the APK', () async {
      const files = [
        'assets/kws/encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
        'assets/kws/decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
        'assets/kws/joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
        'assets/kws/tokens.txt',
      ];
      for (final f in files) {
        final data = await rootBundle.load(f);
        expect(data.lengthInBytes, greaterThan(100),
            reason: '$f is missing or empty in the APK');
      }
    });

    test('the bundled model is the int8 one (small, quantised)', () async {
      final data = await rootBundle.load(
        'assets/kws/encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
      );
      // an int8 encoder is ~4.6 MB; the fp32 one is ~11.6 MB
      expect(data.lengthInBytes, lessThan(8 * 1024 * 1024));
    });
  });

  group('keyword table', () {
    late Set<String> modelTokens;
    late Map<String, List<String>> table;

    setUpAll(() async {
      final raw = await rootBundle.loadString('assets/kws/tokens.txt');
      modelTokens = {
        for (final line in raw.split('\n'))
          if (line.trim().isNotEmpty) line.trim().split(' ').first
      };
      final kw = await rootBundle.loadString('assets/kws_keywords.txt');
      table = {};
      for (final line in kw.split('\n')) {
        final t = line.trim();
        if (t.isEmpty) continue;
        final i = t.indexOf('@');
        expect(i, greaterThan(0),
            reason: 'keyword line has no @phrase: "$t"');
        final tokens = t.substring(0, i).trim().split(' ');
        final phrase = t.substring(i + 1).trim().toUpperCase();
        table[phrase] = tokens;
      }
    });

    test('the table is not empty and covers the emergency phrases', () {
      expect(table.length, greaterThanOrEqualTo(10));
      for (final p in [
        'HELP ME',
        'HELP',
        'EMERGENCY',
        'SAVE ME',
        'I NEED HELP',
        'AMBULANCE',
      ]) {
        expect(table.containsKey(p), isTrue,
            reason: 'trigger phrase "$p" is missing from the keyword table');
      }
    });

    test('EVERY token of EVERY phrase exists in the model vocabulary', () {
      // This is the check that the old hand-rolled "▁" + whole-word join
      // failed: "EMERGENCY" is ▁E M ER G EN C Y, not ▁EMERGENCY.
      final bad = <String>[];
      for (final entry in table.entries) {
        for (final tok in entry.value) {
          if (!modelTokens.contains(tok)) {
            bad.add('${entry.key}: "$tok"');
          }
        }
      }
      expect(bad, isEmpty,
          reason: 'keyword tokens that the model can never hear: $bad');
    });

    test('the default trigger "Help me" maps to real tokens', () {
      final tokens = table['HELP ME'];
      expect(tokens, isNotNull);
      expect(tokens, isNotEmpty);
      for (final tok in tokens!) {
        expect(modelTokens.contains(tok), isTrue);
      }
    });

    test('multi-word phrases are segmented, not whole-word joined', () {
      // "EMERGENCY" is not a single BPE unit - it must be split.
      final tokens = table['EMERGENCY']!;
      expect(tokens.length, greaterThan(1),
          reason: 'EMERGENCY should be split into several BPE units');
      // and the whole-word form must NOT be in the vocabulary
      expect(modelTokens.contains('▁EMERGENCY'), isFalse);
    });
  });
}
