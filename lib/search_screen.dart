import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:crypto/crypto.dart';
import 'package:diacritic/diacritic.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_core/theme.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as spdf;
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

void unawaited(Future<void> future) {}

class SearchReturn {
  final int page;
  final double zoom;
  const SearchReturn({required this.page, required this.zoom});
}

class _Hit {
  final int pdfPage;
  final int printedPage;
  final String blockText;
  final int hitIndex;
  final int pageOccIndex;
  final int blockOccIndex;

  const _Hit({
    required this.pdfPage,
    required this.printedPage,
    required this.blockText,
    required this.hitIndex,
    required this.pageOccIndex,
    required this.blockOccIndex,
  });
}

class _ExtractPayload {
  final Uint8List bytes;
  const _ExtractPayload(this.bytes);
}

class _SearchPayload {
  final List<String> pageTexts;
  final String query;
  final int displayOffset;

  const _SearchPayload({
    required this.pageTexts,
    required this.query,
    required this.displayOffset,
  });
}

/// ---------- DISK CACHES ----------
class SearchTextCache {
  static const String _filePrefix = "st_search_pages_v2_";
  static String _hashBytes(Uint8List bytes) => sha1.convert(bytes).toString();

  static Future<File> _cacheFileFor(Uint8List pdfBytes) async {
    final dir = await getApplicationSupportDirectory();
    final hash = _hashBytes(pdfBytes);
    return File("${dir.path}/$_filePrefix$hash.gz");
  }

  static Future<void> prewarm(Uint8List pdfBytes) async {
    try {
      final f = await _cacheFileFor(pdfBytes);
      if (await f.exists()) return;

      final pages = await compute(_extractAllPagesInIsolate, _ExtractPayload(pdfBytes));
      final jsonStr = jsonEncode(pages);
      final compressed = gzip.encode(utf8.encode(jsonStr));
      await f.writeAsBytes(compressed, flush: true);
    } catch (_) {}
  }

  static Future<List<String>?> load(Uint8List pdfBytes) async {
    try {
      final f = await _cacheFileFor(pdfBytes);
      if (!await f.exists()) return null;

      final compressed = await f.readAsBytes();
      final decoded = gzip.decode(compressed);
      final jsonStr = utf8.decode(decoded);
      final parsed = jsonDecode(jsonStr);

      if (parsed is! List) return null;
      return parsed.map((e) => e.toString()).toList();
    } catch (_) {
      return null;
    }
  }
}

class PdfBytesCache {
  static const String _filePrefix = "st_pdf_";
  static String _hashBytes(Uint8List bytes) => sha1.convert(bytes).toString();

  static Future<File> fileFor(Uint8List pdfBytes) async {
    final dir = await getApplicationSupportDirectory();
    final hash = _hashBytes(pdfBytes);
    return File("${dir.path}/$_filePrefix$hash.pdf");
  }

  static Future<File?> ensureSaved(Uint8List pdfBytes) async {
    try {
      final f = await fileFor(pdfBytes);
      if (await f.exists()) return f;
      await f.writeAsBytes(pdfBytes, flush: true);
      return f;
    } catch (_) {
      return null;
    }
  }
}

Future<List<String>> _extractAllPagesInIsolate(_ExtractPayload payload) async {
  final doc = spdf.PdfDocument(inputBytes: payload.bytes);
  final extractor = spdf.PdfTextExtractor(doc);
  final total = doc.pages.count;

  final pages = List<String>.generate(total, (i) {
    return extractor.extractText(startPageIndex: i, endPageIndex: i);
  });

  doc.dispose();
  return pages;
}

/// ---------- NORMALIZATION ----------
String _fold(String s) => removeDiacritics(s);

String _stripInvisible(String s) {
  if (s.isEmpty) return s;
  return s
      .replaceAll('\u00AD', '')
      .replaceAll('\u200B', '')
      .replaceAll('\u200C', '')
      .replaceAll('\u200D', '')
      .replaceAll('\u2060', '');
}

String _normToken(String s) {
  var t = _stripInvisible(s).toLowerCase().trim();
  t = _fold(t);
  t = t.replaceAll(
    RegExp(r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$', unicode: true),
    '',
  );
  return t;
}

String _normTextForSearch(String s) {
  var t = _stripInvisible(s).toLowerCase();
  t = _fold(t);
  t = t.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ');
  t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t;
}

String _normCompact(String s) {
  var t = _stripInvisible(s).toLowerCase();
  t = _fold(t);
  t = t.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');
  return t.trim();
}

List<String> _wordsNorm(String s) {
  final t = _normTextForSearch(s);
  if (t.isEmpty) return [];
  return t.split(' ').where((e) => e.isNotEmpty).toList();
}

List<String> _splitLinesKeepBreaks(String pageText) {
  var t = _stripInvisible(pageText).replaceAll('\r', '\n');
  t = t.replaceAll(RegExp(r'\n{3,}'), '\n\n');

  final raw = t.split('\n');

  final out = <String>[];
  for (final r in raw) {
    final s = r.replaceAll(RegExp(r'[ \t]+'), ' ').trimRight();
    if (s.trim().isEmpty) {
      out.add("");
      continue;
    }
    out.add(s.trim());
  }

  final cleaned = <String>[];
  bool lastEmpty = false;
  for (final x in out) {
    final isEmpty = x.isEmpty;
    if (isEmpty && lastEmpty) continue;
    cleaned.add(x);
    lastEmpty = isEmpty;
  }

  final fixed = <String>[];
  for (int i = 0; i < cleaned.length; i++) {
    final cur = cleaned[i];

    if (cur.isEmpty) {
      final prevIsText = (i > 0) && cleaned[i - 1].isNotEmpty;
      final nextIsText = (i < cleaned.length - 1) && cleaned[i + 1].isNotEmpty;
      if (prevIsText && nextIsText) continue;
    }
    fixed.add(cur);
  }

  return fixed;
}

({String block, int up, int down}) _buildContextBlockWithRange({
  required List<String> linesWithBreaks,
  required int matchIndex,
  int maxNonEmptyLines = 6,
  int minWords = 28,
}) {
  if (linesWithBreaks.isEmpty) return (block: "", up: 0, down: 0);

  bool isBreak(int i) => linesWithBreaks[i].isEmpty;

  int up = matchIndex;
  int down = matchIndex;

  int nonEmpty = linesWithBreaks[matchIndex].trim().isNotEmpty ? 1 : 0;

  int countWords(int a, int b) {
    final s = linesWithBreaks
        .sublist(a, b + 1)
        .where((e) => e.trim().isNotEmpty)
        .join(" ");
    return s.split(RegExp(r"\s+")).where((x) => x.trim().isNotEmpty).length;
  }

  int i = matchIndex - 1;
  while (i >= 0) {
    if (isBreak(i)) break;
    if (nonEmpty >= maxNonEmptyLines) break;
    up = i;
    if (linesWithBreaks[i].trim().isNotEmpty) nonEmpty++;
    i--;
  }

  i = matchIndex + 1;
  while (i < linesWithBreaks.length) {
    if (isBreak(i)) break;
    if (nonEmpty >= maxNonEmptyLines) break;
    down = i;
    if (linesWithBreaks[i].trim().isNotEmpty) nonEmpty++;
    i++;
  }

  int w = countWords(up, down);
  int guard = 0;

  while (w < minWords && guard < 20) {
    guard++;
    bool moved = false;

    if (up > 0 && !isBreak(up - 1)) {
      up = up - 1;
      moved = true;
    }
    if (down < linesWithBreaks.length - 1 && !isBreak(down + 1)) {
      down = down + 1;
      moved = true;
    }
    if (!moved) break;

    int tempNonEmpty = 0;
    for (int k = up; k <= down; k++) {
      if (linesWithBreaks[k].trim().isNotEmpty) tempNonEmpty++;
    }
    if (tempNonEmpty > maxNonEmptyLines + 2) break;

    w = countWords(up, down);
  }

  final block = linesWithBreaks
      .sublist(up, down + 1)
      .where((e) => e.trim().isNotEmpty)
      .join("\n")
      .trim();

  return (block: block, up: up, down: down);
}

List<String> _mergeBrokenWordsForDisplay(List<String> wordsRaw) {
  if (wordsRaw.isEmpty) return wordsRaw;

  ({String lead, String core, String trail}) splitToken(String s) {
    final t = _stripInvisible(s);
    final m = RegExp(
      r'^([^\p{L}\p{N}]*)' r'([\p{L}\p{N}]+)?' r'([^\p{L}\p{N}]*)$',
      unicode: true,
    ).firstMatch(t);

    if (m == null) return (lead: "", core: t, trail: "");
    return (
    lead: (m.group(1) ?? ""),
    core: (m.group(2) ?? ""),
    trail: (m.group(3) ?? "")
    );
  }

  bool isAlphaNum(String s) => RegExp(r'^[\p{L}\p{N}]+$', unicode: true).hasMatch(s);

  final Set<String> safeSuffix = <String>{'s', 'es', 'ed', 'ing'};

  final Set<String> stop = <String>{
    'a',
    'an',
    'and',
    'are',
    'as',
    'at',
    'be',
    'by',
    'for',
    'from',
    'has',
    'have',
    'he',
    'her',
    'his',
    'i',
    'if',
    'in',
    'is',
    'it',
    'its',
    'me',
    'my',
    'not',
    'of',
    'on',
    'or',
    'our',
    'she',
    'that',
    'the',
    'their',
    'them',
    'they',
    'this',
    'to',
    'was',
    'we',
    'were',
    'with',
    'you',
    'your'
  };

  final src = wordsRaw.map(_stripInvisible).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  if (src.isEmpty) return const <String>[];

  bool endsWithHyphen(String w) => w.trimRight().endsWith('-');

  bool canMergeSingleLetter(String aCore, String bCore) {
    if (aCore.length != 1) return false;
    if (bCore.length < 2 || bCore.length > 6) return false;
    if (!isAlphaNum(aCore) || !isAlphaNum(bCore)) return false;

    final a = aCore.toLowerCase();
    final b = bCore.toLowerCase();

    if (a == 'is' || a == 'in' || b == 'is' || b == 'in') return false;

    return true;
  }

  bool canMergeSuffix(String aCore, String bCore) {
    if (!isAlphaNum(aCore) || !isAlphaNum(bCore)) return false;

    final a = aCore.toLowerCase();
    final b = bCore.toLowerCase();

    if (a == 'is' || a == 'in' || b == 'is' || b == 'in') return false;

    if (stop.contains(a) || stop.contains(b)) return false;

    if (!safeSuffix.contains(b)) return false;

    if (aCore.length > 6) return false;

    return true;
  }

  final out = <String>[];
  int i = 0;

  while (i < src.length) {
    var cur = src[i];
    int j = i;

    while (j < src.length - 1) {
      final next = src[j + 1];

      final curP = splitToken(cur);
      final nextP = splitToken(next);

      final aCore = curP.core;
      final bCore = nextP.core;

      if (aCore.isEmpty || bCore.isEmpty) break;

      if (endsWithHyphen(cur)) {
        final head = cur.substring(0, cur.length - 1);
        final headP = splitToken(head);
        if (headP.core.isNotEmpty && isAlphaNum(headP.core) && isAlphaNum(bCore)) {
          cur = "${headP.lead}${headP.core}${bCore}${nextP.trail}";
          j++;
          continue;
        }
      }

      if (aCore.toLowerCase() == 'rec' && bCore.toLowerCase() == 'eives') {
        cur = "${curP.lead}receives${nextP.trail}";
        j++;
        continue;
      }
      if (aCore.toLowerCase() == 'th' && bCore.toLowerCase() == 'is') {
        cur = "${curP.lead}this${nextP.trail}";
        j++;
        continue;
      }
      if (aCore.toLowerCase() == 'c' && bCore.toLowerCase() == 'ompanions') {
        cur = "${curP.lead}companions${nextP.trail}";
        j++;
        continue;
      }
      if (aCore.toLowerCase() == 'r' && bCore.toLowerCase() == 't') {
        cur = "${curP.lead}heart${nextP.trail}";
        j++;
        continue;
      }
      if (aCore.toLowerCase() == 'withou' && bCore.toLowerCase() == 't') {
        cur = "${curP.lead}without${nextP.trail}";
        j++;
        continue;
      }
      if (aCore.toLowerCase() == 't' && bCore.toLowerCase() == 'aṣawwuf') {
        cur = "${curP.lead}taṣawwuf${nextP.trail}";
        j++;
        continue;
      }

      if (canMergeSingleLetter(aCore, bCore)) {
        cur = "${curP.lead}${aCore}${bCore}${nextP.trail}";
        j++;
        continue;
      }

      if (canMergeSuffix(aCore, bCore)) {
        cur = "${curP.lead}${aCore}${bCore}${nextP.trail}";
        j++;
        continue;
      }

      break;
    }

    out.add(cur);
    i = j + 1;
  }

  return out;
}

/// ---------- RECT MATCHING ----------
/// ✅ FIX: Inflate tight bounds so tall letters (f, t, k, l, etc.) don't go outside highlight.
Rect _inflateRectForHighlight(Rect r) {
  if (r.isEmpty) return r;

  final h = r.height;
  final w = r.width;

  // Vertical padding (covers ascenders/descenders) + tiny horizontal padding.
  final double padY = (h * 0.22).clamp(0.8, 3.2);
  final double padX = (w * 0.04).clamp(0.4, 2.4);

  // Slightly more top padding.
  final double padTop = padY * 0.65;
  final double padBottom = padY * 0.35;

  return Rect.fromLTRB(
    r.left - padX,
    r.top - padTop,
    r.right + padX,
    r.bottom + padBottom,
  );
}

List<Rect> _allPhraseRectsFromWordCollection({
  required dynamic textLine,
  required String query,
}) {
  try {
    final qWords = _wordsNorm(query);
    if (qWords.isEmpty) return <Rect>[];

    final dynamic wc = (textLine as dynamic).wordCollection;
    if (wc == null) return <Rect>[];

    final List<dynamic> words = List<dynamic>.from(wc as Iterable);
    if (words.isEmpty) return <Rect>[];

    final wNorm = words.map((w) {
      final txt = ((w as dynamic).text ?? '').toString();
      return _normToken(txt);
    }).toList();

    final rects = <Rect>[];

    if (qWords.length == 1) {
      final q0 = qWords[0];
      final qC = _normCompact(query);

      for (int i = 0; i < wNorm.length; i++) {
        final wn = wNorm[i];
        if (wn.isEmpty) continue;

        // Same-token match
        if (wn == q0 || wn.contains(q0) || (qC.isNotEmpty && wn.contains(qC))) {
          final Rect r = (words[i] as dynamic).bounds as Rect;
          rects.add(_inflateRectForHighlight(r)); // ✅ FIX
          continue;
        }

        // Cross-token join ONLY if query starts with current token (broken word case)
        if (qC.isNotEmpty && wn.isNotEmpty && qC.startsWith(wn) && wn.length < qC.length) {
          String acc = wn;
          Rect? union = (words[i] as dynamic).bounds as Rect;

          int j = i + 1;
          int guard = 0;

          while (j < wNorm.length && guard < 12) {
            guard++;
            final part = wNorm[j];
            if (part.isEmpty) break;

            acc += part;

            final Rect r = (words[j] as dynamic).bounds as Rect;
            union = (union == null) ? r : union.expandToInclude(r);

            if (acc.startsWith(qC)) {
              if (union != null) rects.add(_inflateRectForHighlight(union)); // ✅ FIX
              break;
            }

            if (qC.startsWith(acc)) {
              j++;
              continue;
            }

            break;
          }
        }
      }
      return rects;
    }

    for (int i = 0; i <= wNorm.length - qWords.length; i++) {
      bool ok = true;
      for (int j = 0; j < qWords.length; j++) {
        if (wNorm[i + j] != qWords[j]) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;

      Rect? union;
      for (int j = 0; j < qWords.length; j++) {
        final Rect r = (words[i + j] as dynamic).bounds as Rect;
        union = (union == null) ? r : union.expandToInclude(r);
      }
      if (union != null) rects.add(_inflateRectForHighlight(union)); // ✅ FIX
    }

    return rects;
  } catch (_) {
    return <Rect>[];
  }
}

int _mapPrintedPage({required int pdfPage, required int displayOffset}) {
  final prefacePdfStart = displayOffset + 1;
  if (pdfPage < prefacePdfStart) return pdfPage;
  return pdfPage - displayOffset;
}

List<int> _findOccurrenceStartsInBlock(String block, String query) {
  final qWords = _wordsNorm(query);
  if (qWords.isEmpty) return const <int>[];

  final raw = block.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (raw.isEmpty) return const <int>[];

  final wordsRaw = raw.split(' ').where((e) => e.trim().isNotEmpty).toList();
  if (wordsRaw.isEmpty) return const <int>[];

  final wordsN = wordsRaw.map(_normToken).toList();
  final starts = <int>[];

  // ✅ FIX: stop "previous word + next word" false hits for short queries.
  // Cross-word join ONLY if current token is prefix of query (split word case).
  if (qWords.length == 1) {
    final q0 = qWords[0];
    final qC = _normCompact(query);

    for (int i = 0; i < wordsN.length; i++) {
      final wn = wordsN[i];
      if (wn.isEmpty) continue;

      if (wn == q0 || wn.contains(q0) || (qC.isNotEmpty && wn.contains(qC))) {
        starts.add(i);
        continue;
      }

      if (qC.isNotEmpty && wn.isNotEmpty && qC.startsWith(wn) && wn.length < qC.length) {
        String acc = wn;
        int j = i + 1;
        int guard = 0;

        while (j < wordsN.length && guard < 12) {
          guard++;
          final part = wordsN[j];
          if (part.isEmpty) break;

          acc += part;

          if (acc.startsWith(qC)) {
            starts.add(i);
            break;
          }
          if (qC.startsWith(acc)) {
            j++;
            continue;
          }
          break;
        }
      }
    }
    return starts;
  }

  for (int i = 0; i <= wordsN.length - qWords.length; i++) {
    bool ok = true;
    for (int j = 0; j < qWords.length; j++) {
      if (wordsN[i + j] != qWords[j]) {
        ok = false;
        break;
      }
    }
    if (ok) starts.add(i);
  }

  return starts;
}

List<_Hit> _searchHitsInIsolate(_SearchPayload payload) {
  final q = payload.query.trim();
  if (q.isEmpty) return <_Hit>[];

  final qNorm = _normTextForSearch(q);
  final qCompact = _normCompact(q);
  if (qNorm.isEmpty && qCompact.isEmpty) return <_Hit>[];

  final hits = <_Hit>[];
  int hitIndex = 0;

  for (int p = 0; p < payload.pageTexts.length; p++) {
    final pageText = payload.pageTexts[p];
    if (pageText.trim().isEmpty) continue;

    final lines = _splitLinesKeepBreaks(pageText);

    final lineWordStart = List<int>.filled(lines.length, 0);
    int acc = 0;
    for (int i = 0; i < lines.length; i++) {
      lineWordStart[i] = acc;
      final ln = lines[i];
      if (ln.trim().isEmpty) continue;
      final wc = ln.split(RegExp(r"\s+")).where((e) => e.trim().isNotEmpty).length;
      acc += wc;
    }

    final pageStarts = _findOccurrenceStartsInBlock(pageText, q);
    if (pageStarts.isEmpty) continue;

    final pdfPage = p + 1;
    final printed = _mapPrintedPage(
      pdfPage: pdfPage,
      displayOffset: payload.displayOffset,
    );

    for (int occIdx = 0; occIdx < pageStarts.length; occIdx++) {
      final occStartWord = pageStarts[occIdx];
      final pageOccIndex = occIdx + 1;

      int matchLine = 0;
      for (int li = 0; li < lines.length; li++) {
        final start = lineWordStart[li];
        final nextStart = (li == lines.length - 1) ? (1 << 30) : lineWordStart[li + 1];
        if (occStartWord >= start && occStartWord < nextStart) {
          matchLine = li;
          break;
        }
      }

      final r = _buildContextBlockWithRange(
        linesWithBreaks: lines,
        matchIndex: matchLine,
        maxNonEmptyLines: 6,
        minWords: 28,
      );

      final blockText = r.block;

      int blockOccIndex = 1;
      final blockStarts = _findOccurrenceStartsInBlock(blockText, q);
      if (blockStarts.isNotEmpty) {
        final blockWordStart = lineWordStart[r.up];
        final rel = occStartWord - blockWordStart;

        int bestI = 0;
        int bestD = (blockStarts[0] - rel).abs();
        for (int i = 1; i < blockStarts.length; i++) {
          final d = (blockStarts[i] - rel).abs();
          if (d < bestD) {
            bestD = d;
            bestI = i;
          }
        }
        blockOccIndex = bestI + 1;
      }

      hits.add(_Hit(
        pdfPage: pdfPage,
        printedPage: printed,
        blockText: blockText,
        hitIndex: hitIndex,
        pageOccIndex: pageOccIndex,
        blockOccIndex: blockOccIndex,
      ));
      hitIndex++;
    }
  }

  return hits;
}

/// ---------- UI ----------
class SearchScreen extends StatefulWidget {
  static const Color barColor = Color(0xff1f474e);

  final Uint8List pdfBytes;
  final bool isDark;

  final int initialPage;
  final double initialZoom;

  final double cropScale;
  final double cropDx;
  final double cropDy;

  final double lastPageScale;
  final double lastPageDy;

  final int displayPageOffset;
  final List<Map<String, dynamic>> toc;

  const SearchScreen({
    super.key,
    required this.pdfBytes,
    required this.isDark,
    required this.initialPage,
    required this.initialZoom,
    required this.cropScale,
    required this.cropDx,
    required this.cropDy,
    required this.lastPageScale,
    required this.lastPageDy,
    this.displayPageOffset = 6,
    required this.toc,
  });

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _searchTEC = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final PdfViewerController _ctrl = PdfViewerController();
  final ScrollController _resultsCtrl = ScrollController();

  bool _extracting = false;
  bool _isSearching = false;
  bool _showPdf = false;

  int _totalPages = 0;
  int _currentPage = 1;
  bool _isLastPage = false;

  List<String>? _pageTexts;
  List<_Hit> _hits = [];
  String _lastQuery = "";

  late Uint8List _baseBytes;
  int _currentHit = -1;

  int? _pendingJumpPage;
  double? _pendingZoom;

  bool _docLoaded = false;

  spdf.PdfDocument? _doc;
  spdf.PdfTextExtractor? _extractor;

  String _boundsCacheQueryKey = "";
  final Map<int, List<PdfTextLine>> _boundsCacheByPage = <int, List<PdfTextLine>>{};

  final Set<int> _othersDonePages = <int>{};
  final Map<int, bool> _othersAnnotatingByPage = <int, bool>{};

  Annotation? _selectedAnnotation;
  final Map<int, Annotation> _othersAnnotationByPage = <int, Annotation>{};

  Timer? _highlightDebounce;

  Timer? _bgPreloadTimer;
  bool _bgPreloading = false;
  int _bgCenterPage = 1;
  int _bgRadius = 0;
  int _bgMaxRadius = 4;

  File? _cachedPdfFile;

  bool _navBusy = false;

  int _navToken = 0;
  int get _activeToken => _navToken;

  static const Color _loaderBlue = Color(0xFF66C7FF);

  String _refSpanCacheQuery = "";
  final Map<int, InlineSpan> _refSpanCache = <int, InlineSpan>{};

  double _savedResultsOffset = 0.0;

  @override
  void initState() {
    super.initState();
    _baseBytes = widget.pdfBytes;

    unawaited(_ensureExtracted());
    unawaited(_ensurePdfCached());

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ctrl.jumpToPage(widget.initialPage < 1 ? 1 : widget.initialPage);
      _ctrl.zoomLevel = widget.initialZoom.clamp(1.0, 4.0);
      _searchFocus.requestFocus();
    });
  }

  Future<void> _ensurePdfCached() async {
    final f = await PdfBytesCache.ensureSaved(_baseBytes);
    if (!mounted) return;
    if (f != null) setState(() => _cachedPdfFile = f);
  }

  @override
  void dispose() {
    _resultsCtrl.dispose();
    _highlightDebounce?.cancel();
    _stopBackgroundPreload();
    _searchTEC.dispose();
    _searchFocus.dispose();
    _disposeDoc();
    super.dispose();
  }

  void _disposeDoc() {
    try {
      _doc?.dispose();
    } catch (_) {}
    _doc = null;
    _extractor = null;
  }

  void _ensureDocReady() {
    if (_doc != null && _extractor != null) return;
    _doc = spdf.PdfDocument(inputBytes: _baseBytes);
    _extractor = spdf.PdfTextExtractor(_doc!);
  }

  void _clearBoundsCache() {
    _boundsCacheByPage.clear();
    _boundsCacheQueryKey = _normTextForSearch(_lastQuery.trim());
  }

  void _clearRefSpanCache() {
    _refSpanCache.clear();
    _refSpanCacheQuery = _lastQuery.trim();
  }

  // ------------------------------
  // ✅ Roman + Preface mapping
  // ------------------------------
  String _romanLower(int n) {
    if (n <= 0) return "";
    final map = <int, String>{
      1000: 'm',
      900: 'cm',
      500: 'd',
      400: 'cd',
      100: 'c',
      90: 'xc',
      50: 'l',
      40: 'xl',
      10: 'x',
      9: 'ix',
      5: 'v',
      4: 'iv',
      1: 'i',
    };
    var x = n;
    final buf = StringBuffer();
    for (final e in map.entries) {
      while (x >= e.key) {
        buf.write(e.value);
        x -= e.key;
      }
    }
    return buf.toString();
  }

  int? _prefaceRomanForPdfPage(int pdfPage) {
    if (pdfPage >= 3 && pdfPage <= 8) return pdfPage - 1;
    return null;
  }

  String? _prefaceTitleForPdfPage(int pdfPage) {
    if (pdfPage == 4) return "Note on Transliteration";
    if (pdfPage == 5) return "Ba Fayzan-e-Nazar • Intisab";
    if (pdfPage >= 6 && pdfPage <= 8) return "Content";
    return null;
  }

  String _badgeLabelForPdfPage({required int pdfPage, required int printedPage}) {
    final r = _prefaceRomanForPdfPage(pdfPage);
    if (r != null) return _romanLower(r);
    return "P$printedPage";
  }

  void _onBackPressed() {
    if (_showPdf) {
      setState(() => _showPdf = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_resultsCtrl.hasClients) {
          final max = _resultsCtrl.position.maxScrollExtent;
          final target = _savedResultsOffset.clamp(0.0, max);
          _resultsCtrl.jumpTo(target);
        }
      });
      return;
    }

    final page = (_ctrl.pageNumber < 1) ? _currentPage : _ctrl.pageNumber;
    final zoom = _ctrl.zoomLevel;
    Navigator.of(context).pop(SearchReturn(page: page, zoom: zoom));
  }

  Future<void> _ensureExtracted() async {
    if (_pageTexts != null) return;
    if (_extracting) return;

    setState(() => _extracting = true);

    try {
      final cached = await SearchTextCache.load(_baseBytes);
      if (!mounted) return;

      if (cached != null && cached.isNotEmpty) {
        _pageTexts = cached;
      } else {
        final pages = await compute(_extractAllPagesInIsolate, _ExtractPayload(_baseBytes));
        if (!mounted) return;
        _pageTexts = pages;
        unawaited(SearchTextCache.prewarm(_baseBytes));
      }
    } catch (_) {
      if (!mounted) return;
      _pageTexts = <String>[];
    } finally {
      if (!mounted) return;
      setState(() => _extracting = false);
    }
  }

  void _clearAllHighlights() {
    if (_selectedAnnotation != null) {
      try {
        _ctrl.removeAnnotation(_selectedAnnotation!);
      } catch (_) {}
      _selectedAnnotation = null;
    }

    for (final ann in _othersAnnotationByPage.values) {
      try {
        _ctrl.removeAnnotation(ann);
      } catch (_) {}
    }
    _othersAnnotationByPage.clear();
    _othersDonePages.clear();
    _othersAnnotatingByPage.clear();
  }

  Future<void> _onSubmitSearch(String value) async {
    final q = value.trim();
    if (q.isEmpty) return;

    FocusScope.of(context).unfocus();
    _stopBackgroundPreload();

    setState(() {
      _lastQuery = q;
      _isSearching = true;
      _hits = [];
      _currentHit = -1;
      _showPdf = false;
    });

    _clearAllHighlights();
    _clearBoundsCache();
    _clearRefSpanCache();

    await _ensureExtracted();
    if (!mounted) return;

    final hits = await compute(
      _searchHitsInIsolate,
      _SearchPayload(
        pageTexts: _pageTexts ?? <String>[],
        query: q,
        displayOffset: widget.displayPageOffset,
      ),
    );

    if (!mounted) return;

    setState(() {
      _hits = hits;
      _isSearching = false;
    });

    if (_resultsCtrl.hasClients) {
      _resultsCtrl.jumpTo(0);
      _savedResultsOffset = 0.0;
    }
  }

  List<PdfTextLine> _collectAllOccurrenceTextLinesOnPageCached({
    required int pdfPage,
    required String query,
  }) {
    final qKey = _normTextForSearch(query.trim());
    if (qKey.isEmpty) return <PdfTextLine>[];

    if (_boundsCacheQueryKey != qKey) {
      _boundsCacheQueryKey = qKey;
      _boundsCacheByPage.clear();
    }

    final cached = _boundsCacheByPage[pdfPage];
    if (cached != null) return cached;

    _ensureDocReady();
    final doc = _doc!;
    final extractor = _extractor!;

    final pageIndex = (pdfPage - 1).clamp(0, doc.pages.count - 1);

    final lines = extractor.extractTextLines(
      startPageIndex: pageIndex,
      endPageIndex: pageIndex,
    );

    final out = <PdfTextLine>[];

    for (final tl in lines) {
      final rects = _allPhraseRectsFromWordCollection(
        textLine: tl,
        query: query,
      );
      if (rects.isEmpty) continue;

      for (final r in rects) {
        // ✅ FIX: inflate bounds so tall letters don't go outside highlight.
        final rr = _inflateRectForHighlight(r);
        out.add(PdfTextLine(rr, query, pdfPage));
      }
    }

    _boundsCacheByPage[pdfPage] = out;
    return out;
  }

  Future<void> _ensureOthersHighlightedForPage(int page, int token) async {
    if (token != _activeToken) return;

    final q = _lastQuery.trim();
    if (q.isEmpty) return;
    if (!_docLoaded) return;
    if (page < 1) return;
    if (_totalPages > 0 && page > _totalPages) return;
    if (_othersDonePages.contains(page)) return;

    if (_othersAnnotatingByPage[page] == true) return;
    _othersAnnotatingByPage[page] = true;

    try {
      await Future<void>.delayed(Duration.zero);
      if (token != _activeToken) return;

      final bounds = _collectAllOccurrenceTextLinesOnPageCached(
        pdfPage: page,
        query: q,
      );
      if (token != _activeToken) return;

      if (bounds.isEmpty) {
        _othersDonePages.add(page);
        return;
      }

      final ann = HighlightAnnotation(textBoundsCollection: bounds)
        ..color = Colors.yellow
        ..opacity = 0.7;

      _ctrl.addAnnotation(ann);

      _othersAnnotationByPage[page] = ann;
      _othersDonePages.add(page);
    } catch (_) {
      // ignore
    } finally {
      _othersAnnotatingByPage[page] = false;
    }
  }

  Future<void> _applySelectedHighlight({
    required int selectedPdfPage,
    required int selectedPageOccIndex,
    required String query,
    required int token,
  }) async {
    if (token != _activeToken) return;
    if (!_docLoaded) return;

    if (_selectedAnnotation != null) {
      try {
        _ctrl.removeAnnotation(_selectedAnnotation!);
      } catch (_) {}
      _selectedAnnotation = null;
    }

    final all = _collectAllOccurrenceTextLinesOnPageCached(
      pdfPage: selectedPdfPage,
      query: query,
    );
    if (token != _activeToken) return;

    if (all.isEmpty) return;
    if (selectedPageOccIndex < 1 || selectedPageOccIndex > all.length) return;

    final selLine = all[selectedPageOccIndex - 1];
    final selColor = widget.isDark ? Colors.cyan : Colors.orange;

    final ann = HighlightAnnotation(textBoundsCollection: [selLine])
      ..color = selColor
      ..opacity = 0.60;

    _ctrl.addAnnotation(ann);
    _selectedAnnotation = ann;
  }

  Future<void> _openHitIndex(int idx) async {
    if (idx < 0 || idx >= _hits.length) return;
    final hit = _hits[idx];
    final q = _lastQuery.trim();
    if (q.isEmpty) return;

    if (_resultsCtrl.hasClients) {
      _savedResultsOffset = _resultsCtrl.offset;
    }

    _navToken++;
    final int token = _activeToken;

    _stopBackgroundPreload();
    _highlightDebounce?.cancel();

    _navBusy = true;
    if (mounted) setState(() {});

    try {
      final int currentPageNow = (_ctrl.pageNumber < 1) ? _currentPage : _ctrl.pageNumber;

      if (mounted) {
        setState(() {
          _showPdf = true;
          _currentHit = idx;
        });
      }

      if (_docLoaded && hit.pdfPage == currentPageNow) {
        await _ensureOthersHighlightedForPage(hit.pdfPage, token);
        await _applySelectedHighlight(
          selectedPdfPage: hit.pdfPage,
          selectedPageOccIndex: hit.pageOccIndex,
          query: q,
          token: token,
        );
        if (mounted && token == _activeToken) {
          _startBackgroundPreload(centerPage: hit.pdfPage, token: token);
        }
        return;
      }

      _pendingJumpPage = hit.pdfPage;
      _pendingZoom = _ctrl.zoomLevel;

      _ctrl.jumpToPage(hit.pdfPage);

      await Future<void>.delayed(const Duration(milliseconds: 12));
      if (!mounted || token != _activeToken) return;

      await _ensureOthersHighlightedForPage(hit.pdfPage, token);
      if (!mounted || token != _activeToken) return;

      await _applySelectedHighlight(
        selectedPdfPage: hit.pdfPage,
        selectedPageOccIndex: hit.pageOccIndex,
        query: q,
        token: token,
      );
      if (!mounted || token != _activeToken) return;

      _startBackgroundPreload(centerPage: hit.pdfPage, token: token);
    } finally {
      if (token == _activeToken) {
        _navBusy = false;
        if (mounted) setState(() {});
      }
    }
  }

  void _nextMatch() {
    if (_hits.isEmpty) return;
    final int next = (_currentHit < 0) ? 0 : (_currentHit + 1) % _hits.length;
    unawaited(_openHitIndex(next));
  }

  void _prevMatch() {
    if (_hits.isEmpty) return;
    final int prev =
    (_currentHit < 0) ? (_hits.length - 1) : (_currentHit - 1 + _hits.length) % _hits.length;
    unawaited(_openHitIndex(prev));
  }

  void _stopBackgroundPreload() {
    _bgPreloadTimer?.cancel();
    _bgPreloadTimer = null;
    _bgPreloading = false;
    _bgRadius = 0;
  }

  void _startBackgroundPreload({required int centerPage, required int token}) {
    if (!_docLoaded) return;
    if (_lastQuery.trim().isEmpty) return;

    _stopBackgroundPreload();

    _bgCenterPage = centerPage;
    _bgRadius = 0;
    _bgPreloading = true;

    _bgPreloadTimer = Timer.periodic(const Duration(milliseconds: 45), (_) async {
      if (!mounted) return;
      if (!_bgPreloading) return;
      if (token != _activeToken) {
        _stopBackgroundPreload();
        return;
      }

      final r = _bgRadius;
      final pagesToTry = <int>[];

      if (r == 0) {
        pagesToTry.add(_bgCenterPage);
      } else {
        pagesToTry.add(_bgCenterPage + r);
        pagesToTry.add(_bgCenterPage - r);
      }

      for (final p in pagesToTry) {
        if (p < 1) continue;
        if (_totalPages > 0 && p > _totalPages) continue;
        if (_othersDonePages.contains(p)) continue;

        await _ensureOthersHighlightedForPage(p, token);
        break;
      }

      _bgRadius++;
      if (_bgRadius > _bgMaxRadius) {
        _stopBackgroundPreload();
      }
    });
  }

  Widget _boxButton({
    required Widget child,
    required VoidCallback? onTap,
    bool disabled = false,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: disabled ? null : onTap,
      child: Opacity(
        opacity: disabled ? 0.55 : 1.0,
        child: Container(
          height: 44,
          width: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.18),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withOpacity(0.25), width: 1),
          ),
          child: child,
        ),
      ),
    );
  }

  String _contentTitleForPdfPage(int pdfPage) {
    final pref = _prefaceTitleForPdfPage(pdfPage);
    if (pref != null && pref.trim().isNotEmpty) return pref;

    final prefacePdfStart = widget.displayPageOffset + 1;
    if (pdfPage < prefacePdfStart) return "Content";

    final tocPage = pdfPage - widget.displayPageOffset;

    Map<String, dynamic>? best;
    for (final item in widget.toc) {
      final p = (item["page"] as int?) ?? 0;
      if (p <= tocPage) {
        best = item;
      } else {
        break;
      }
    }
    if (best == null) return "Page $tocPage";
    return (best["title"] ?? "Page $tocPage").toString();
  }

  InlineSpan _referenceParagraphDottedSpan({
    required String block,
    required String query,
    required int blockOccIndex,
    required bool isDark,
  }) {
    final q = query.trim();
    if (q.isEmpty) return TextSpan(text: block);

    final raw0 = _stripInvisible(
      block.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim(),
    );
    if (raw0.isEmpty) return const TextSpan(text: "");

    final tokens0 = raw0.split(' ').where((e) => e.trim().isNotEmpty).toList();
    if (tokens0.isEmpty) return const TextSpan(text: "");

    final wordsRaw = _mergeBrokenWordsForDisplay(tokens0);
    if (wordsRaw.isEmpty) return const TextSpan(text: "");

    final qWords = _wordsNorm(q);
    if (qWords.isEmpty) return TextSpan(text: wordsRaw.join(' '));

    final wordsNorm = wordsRaw.map(_normToken).toList();

    final Color hlBg = isDark ? Colors.yellow.withOpacity(0.28) : Colors.yellow.withOpacity(0.55);

    final occPairs = <List<int>>[];

    // ✅ FIX: same rule for reference preview:
    // no cross-word hit starting from previous token.
    if (qWords.length == 1) {
      final q0 = qWords[0];
      final qC = _normCompact(q);

      for (int i = 0; i < wordsNorm.length; i++) {
        final wn = wordsNorm[i];
        if (wn.isEmpty) continue;

        if (wn == q0 || wn.contains(q0) || (qC.isNotEmpty && wn.contains(qC))) {
          occPairs.add([i, i]);
          continue;
        }

        if (qC.isNotEmpty && wn.isNotEmpty && qC.startsWith(wn) && wn.length < qC.length) {
          String acc = wn;
          int j = i + 1;
          int guard = 0;

          while (j < wordsNorm.length && guard < 12) {
            guard++;
            final part = wordsNorm[j];
            if (part.isEmpty) break;

            acc += part;

            if (acc.startsWith(qC)) {
              occPairs.add([i, j]);
              break;
            }
            if (qC.startsWith(acc)) {
              j++;
              continue;
            }
            break;
          }
        }
      }
    } else {
      for (int i = 0; i <= wordsNorm.length - qWords.length; i++) {
        bool ok = true;
        for (int j = 0; j < qWords.length; j++) {
          if (wordsNorm[i + j] != qWords[j]) {
            ok = false;
            break;
          }
        }
        if (ok) occPairs.add([i, i + qWords.length - 1]);
      }
    }

    if (occPairs.isEmpty) return TextSpan(text: wordsRaw.join(' '));

    final occIdx0 = (blockOccIndex - 1).clamp(0, occPairs.length - 1);
    final start = occPairs[occIdx0][0];
    final end = occPairs[occIdx0][1];

    if (wordsRaw.length <= 45) {
      final spans = <TextSpan>[];
      for (int i = 0; i < wordsRaw.length; i++) {
        final inHit = (i >= start && i <= end);
        spans.add(TextSpan(
          text: wordsRaw[i] + (i == wordsRaw.length - 1 ? "" : " "),
          style: inHit ? TextStyle(fontWeight: FontWeight.w900, backgroundColor: hlBg) : null,
        ));
      }
      return TextSpan(children: spans);
    }

    const int firstN = 18;
    const int lastN = 18;
    const int beforeN = 2;
    const int afterN = 2;

    final segs = <List<int>>[];
    segs.add([0, firstN.clamp(0, wordsRaw.length)]);

    final midStart = (start - beforeN).clamp(0, wordsRaw.length - 1);
    final midEnd = (end + afterN + 1).clamp(0, wordsRaw.length);
    segs.add([midStart, midEnd]);

    final endStart = (wordsRaw.length - lastN).clamp(0, wordsRaw.length);
    segs.add([endStart, wordsRaw.length]);

    segs.sort((a, b) => a[0].compareTo(b[0]));
    final merged = <List<int>>[];
    for (final s in segs) {
      if (merged.isEmpty) {
        merged.add([s[0], s[1]]);
      } else {
        final last = merged.last;
        if (s[0] <= last[1]) {
          last[1] = (s[1] > last[1]) ? s[1] : last[1];
        } else {
          merged.add([s[0], s[1]]);
        }
      }
    }

    final spans = <TextSpan>[];
    for (int si = 0; si < merged.length; si++) {
      final a = merged[si][0];
      final b = merged[si][1];

      if (si > 0) spans.add(const TextSpan(text: " ............... "));

      for (int i = a; i < b; i++) {
        final inHit = (i >= start && i <= end);
        spans.add(TextSpan(
          text: wordsRaw[i] + (i == b - 1 ? "" : " "),
          style: inHit ? TextStyle(fontWeight: FontWeight.w900, backgroundColor: hlBg) : null,
        ));
      }
    }

    return TextSpan(children: spans);
  }

  InlineSpan _getCachedRefSpanForHit(_Hit h) {
    final q = _lastQuery.trim();
    if (q.isEmpty) return TextSpan(text: h.blockText);

    if (_refSpanCacheQuery != q) {
      _refSpanCacheQuery = q;
      _refSpanCache.clear();
    }

    final key = h.hitIndex;
    final cached = _refSpanCache[key];
    if (cached != null) return cached;

    final span = _referenceParagraphDottedSpan(
      block: h.blockText,
      query: q,
      blockOccIndex: h.blockOccIndex,
      isDark: widget.isDark,
    );

    _refSpanCache[key] = span;
    return span;
  }

  Widget _searchTopBar(double topInset) {
    return Container(
      height: topInset + 60,
      color: SearchScreen.barColor,
      padding: EdgeInsets.only(top: topInset),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            _boxButton(
              onTap: _onBackPressed,
              child: const Icon(Icons.arrow_back, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withOpacity(0.25), width: 1),
                ),
                child: Center(
                  child: TextField(
                    controller: _searchTEC,
                    focusNode: _searchFocus,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                    cursorColor: Colors.white,
                    keyboardType: TextInputType.text,
                    textInputAction: TextInputAction.search,
                    onSubmitted: _onSubmitSearch,
                    decoration: InputDecoration(
                      hintText: _extracting ? "Preparing search index..." : "Search word / phrase...",
                      hintStyle: TextStyle(
                        color: Colors.white.withOpacity(0.75),
                        fontWeight: FontWeight.w700,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            _boxButton(
              onTap: () => _onSubmitSearch(_searchTEC.text),
              disabled: _extracting || _isSearching,
              child: const Icon(Icons.search, color: Colors.white, size: 24),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(double bottomInset) {
    final total = _hits.length;
    final shownCurrent = (total == 0) ? 0 : (_currentHit < 0 ? 1 : (_currentHit + 1));

    return Container(
      height: 64 + bottomInset,
      color: SearchScreen.barColor,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _boxButton(
                onTap: () {
                  _stopBackgroundPreload();
                  _highlightDebounce?.cancel();
                  final page = (_ctrl.pageNumber < 1) ? _currentPage : _ctrl.pageNumber;
                  final zoom = _ctrl.zoomLevel;
                  Navigator.of(context).pop(SearchReturn(page: page, zoom: zoom));
                },
                disabled: false,
                child: const Icon(Icons.close, color: Colors.white, size: 22),
              ),
              _boxButton(
                onTap: _prevMatch,
                disabled: _hits.isEmpty,
                child: const Icon(Icons.chevron_left, color: Colors.white, size: 30),
              ),
              Container(
                height: 44,
                width: 170,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withOpacity(0.25), width: 1),
                ),
                child: Text(
                  (total == 0 ? "0" : "$shownCurrent / $total") + (_navBusy ? " ..." : ""),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              _boxButton(
                onTap: _nextMatch,
                disabled: _hits.isEmpty,
                child: const Icon(Icons.chevron_right, color: Colors.white, size: 30),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _resultsList() {
    final isDark = widget.isDark;
    final Color emptyTxt = isDark ? Colors.white70 : Colors.black54;

    if (_extracting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                strokeWidth: 3.2,
                valueColor: AlwaysStoppedAnimation<Color>(_loaderBlue),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              "Preparing search index…",
              style: TextStyle(color: emptyTxt, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      );
    }
    if (_lastQuery.trim().isEmpty) {
      return Center(
        child: Text(
          "Type a word/phrase and press Search/Enter",
          style: TextStyle(color: emptyTxt, fontWeight: FontWeight.w800),
        ),
      );
    }
    if (_isSearching) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                strokeWidth: 3.2,
                valueColor: AlwaysStoppedAnimation<Color>(_loaderBlue),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              "Searching…",
              style: TextStyle(color: emptyTxt, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      );
    }
    if (_hits.isEmpty) {
      return Center(
        child: Text(
          "No results found",
          style: TextStyle(color: emptyTxt, fontWeight: FontWeight.w800),
        ),
      );
    }

    return ListView.builder(
      controller: _resultsCtrl,
      padding: const EdgeInsets.only(top: 10, bottom: 10),
      cacheExtent: 1800,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: _hits.length,
      itemBuilder: (context, i) {
        final h = _hits[i];

        final title = _contentTitleForPdfPage(h.pdfPage);
        final badge = _badgeLabelForPdfPage(pdfPage: h.pdfPage, printedPage: h.printedPage);

        final Color cardBg = isDark ? Colors.white.withOpacity(0.08) : Colors.white;
        final Color cardBorder = isDark ? Colors.white.withOpacity(0.20) : Colors.black.withOpacity(0.10);

        final Color mainText = isDark ? Colors.white : Colors.black;
        final Color subText = isDark ? Colors.white.withOpacity(0.86) : Colors.black.withOpacity(0.72);
        final Color chevron = isDark ? Colors.white.withOpacity(0.6) : Colors.black.withOpacity(0.45);

        final InlineSpan refSpan = _getCachedRefSpanForHit(h);

        return RepaintBoundary(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => unawaited(_openHitIndex(i)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: cardBorder, width: 1),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 66,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(isDark ? 0.20 : 0.30),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        badge,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: mainText,
                          fontWeight: FontWeight.w900,
                          height: 1.05,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              color: mainText,
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                              height: 1.15,
                            ),
                          ),
                          const SizedBox(height: 8),
                          RichText(
                            text: TextSpan(
                              style: TextStyle(
                                color: subText,
                                fontWeight: FontWeight.w800,
                                fontSize: 13.4,
                                height: 1.32,
                              ),
                              children: [refSpan],
                            ),
                            softWrap: true,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.chevron_right, color: chevron),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _scheduleHighlightAndPreload(int page) {
    final token = _activeToken;

    _highlightDebounce?.cancel();
    _highlightDebounce = Timer(const Duration(milliseconds: 130), () {
      if (!mounted) return;
      if (token != _activeToken) return;

      unawaited(_ensureOthersHighlightedForPage(page, token));
      _startBackgroundPreload(centerPage: page, token: token);
    });
  }

  Widget _pdfViewer() {
    final double scale = _isLastPage ? widget.lastPageScale : widget.cropScale;
    final double dy = _isLastPage ? widget.lastPageDy : widget.cropDy;

    final Widget pdf = SfPdfViewerTheme(
      data: const SfPdfViewerThemeData(backgroundColor: Colors.black),
      child: (_cachedPdfFile != null)
          ? SfPdfViewer.file(
        _cachedPdfFile!,
        controller: _ctrl,
        scrollDirection: PdfScrollDirection.vertical,
        pageLayoutMode: PdfPageLayoutMode.continuous,
        canShowScrollHead: false,
        canShowScrollStatus: false,
        enableDoubleTapZooming: true,
        canShowPageLoadingIndicator: false,
        onDocumentLoaded: (details) {
          if (!mounted) return;

          _docLoaded = true;
          _ensureDocReady();

          setState(() {
            _totalPages = details.document.pages.count;
            _currentPage = (_ctrl.pageNumber < 1) ? 1 : _ctrl.pageNumber;
            _isLastPage = (_totalPages > 0 && _currentPage == _totalPages);
          });

          if (_pendingJumpPage != null) {
            final p = _pendingJumpPage!;
            final z = _pendingZoom;
            _pendingJumpPage = null;
            _pendingZoom = null;

            WidgetsBinding.instance.addPostFrameCallback((_) {
              _ctrl.jumpToPage(p);
              if (z != null) _ctrl.zoomLevel = z;
            });
          }

          _scheduleHighlightAndPreload(_currentPage);
        },
        onPageChanged: (details) {
          if (!mounted) return;
          setState(() {
            _currentPage = details.newPageNumber;
            _isLastPage = (_totalPages > 0 && _currentPage == _totalPages);
          });
          _scheduleHighlightAndPreload(details.newPageNumber);
        },
      )
          : SfPdfViewer.memory(
        widget.pdfBytes,
        controller: _ctrl,
        scrollDirection: PdfScrollDirection.vertical,
        pageLayoutMode: PdfPageLayoutMode.continuous,
        canShowScrollHead: false,
        canShowScrollStatus: false,
        enableDoubleTapZooming: true,
        canShowPageLoadingIndicator: false,
        onDocumentLoaded: (details) {
          if (!mounted) return;

          _docLoaded = true;
          _ensureDocReady();

          setState(() {
            _totalPages = details.document.pages.count;
            _currentPage = (_ctrl.pageNumber < 1) ? 1 : _ctrl.pageNumber;
            _isLastPage = (_totalPages > 0 && _currentPage == _totalPages);
          });

          if (_pendingJumpPage != null) {
            final p = _pendingJumpPage!;
            final z = _pendingZoom;
            _pendingJumpPage = null;
            _pendingZoom = null;

            WidgetsBinding.instance.addPostFrameCallback((_) {
              _ctrl.jumpToPage(p);
              if (z != null) _ctrl.zoomLevel = z;
            });
          }

          _scheduleHighlightAndPreload(_currentPage);
        },
        onPageChanged: (details) {
          if (!mounted) return;
          setState(() {
            _currentPage = details.newPageNumber;
            _isLastPage = (_totalPages > 0 && _currentPage == _totalPages);
          });
          _scheduleHighlightAndPreload(details.newPageNumber);
        },
      ),
    );

    final cropped = ClipRect(
      child: Transform.translate(
        offset: Offset(widget.cropDx, 0),
        child: Transform.translate(
          offset: Offset(0, dy),
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.topCenter,
            child: pdf,
          ),
        ),
      ),
    );

    if (!widget.isDark) return cropped;

    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(<double>[
        -1, 0, 0, 0, 255,
        0, -1, 0, 0, 255,
        0, 0, -1, 0, 255,
        0, 0, 0, 1, 0,
      ]),
      child: cropped,
    );
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    final topH = topInset + 60;
    final bottomH = _showPdf ? (64 + bottomInset) : 0.0;

    final Color bg = widget.isDark ? Colors.black : Colors.white;

    return Scaffold(
      backgroundColor: bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(top: topH, bottom: bottomH),
              child: Visibility(
                visible: _showPdf,
                maintainState: true,
                maintainAnimation: true,
                maintainSize: true,
                child: _pdfViewer(),
              ),
            ),
          ),
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(top: topH),
              child: Visibility(
                visible: !_showPdf,
                maintainState: true,
                maintainAnimation: true,
                maintainSize: true,
                child: _resultsList(),
              ),
            ),
          ),
          Positioned(left: 0, right: 0, top: 0, child: _searchTopBar(topInset)),
          if (_showPdf)
            Positioned(left: 0, right: 0, bottom: 0, child: _bottomBar(bottomInset)),
          if (!_showPdf && (_extracting || _isSearching))
            Positioned(
              left: 0,
              right: 0,
              top: topH,
              child: const SizedBox(
                height: 3,
                child: LinearProgressIndicator(
                  minHeight: 3,
                  valueColor: AlwaysStoppedAnimation<Color>(_loaderBlue),
                  backgroundColor: Colors.transparent,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
