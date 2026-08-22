import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle, Clipboard, ClipboardData;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_core/theme.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as spdf;
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:url_launcher/url_launcher.dart';

import 'search_screen.dart';
import 'drawer_screen.dart';

/// ✅ FIX: unawaited helper
void unawaited(Future<void> future) {}

class Home extends StatefulWidget {
  final bool isDark;
  final VoidCallback onToggleTheme;

  const Home({
    super.key,
    required this.isDark,
    required this.onToggleTheme,
  });

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  static const Color barColor = Color(0xff1f474e);

  // ✅ VISUAL CROP
  static const double _cropScale = 1.30;
  static const double _cropDx = 0.0;
  static const double _cropDy = -10.0;

  // ✅ LAST page crop fix
  static const double _lastPageScale = 1.18;
  static const double _lastPageDy = 0.0;

  static const double _tapSlop = 32.0;

  late bool _isDark;
  bool _barsVisible = true;

  // dim
  final ValueNotifier<double> _dimN = ValueNotifier<double>(0.0);
  bool _auto = false;
  static const double _autoDimValue = 0.35;
  double _lastManualDim = 0.0;

  // ✅ Preface mapping
  static const int _prefacePdfStart = 9;
  static const int _pageOffset = _prefacePdfStart - 1; // ✅ 8

  int _displayContentPage(int pdfPage) {
    if (pdfPage < _prefacePdfStart) return pdfPage;
    return pdfPage - _pageOffset;
  }

  final PdfViewerController _lightCtrl = PdfViewerController();
  final PdfViewerController _darkCtrl = PdfViewerController();
  PdfViewerController get _currentCtrl => _isDark ? _darkCtrl : _lightCtrl;

  int _resumePage = 1;
  double _resumeZoom = 1.0;

  Uint8List? _pdfBytes;
  bool _pdfReady = false;

  // ✅ IMPORTANT: viewer-loaded flag (real readiness)
  bool _viewerLoaded = false;

  spdf.PdfDocument? _pdfDoc;

  int _totalPages = 0;
  int _currentPage = 1;
  bool _isLastPage = false;

  // slider
  double _pageSliderValue = 1.0;
  bool _isDraggingSlider = false;
  Timer? _sliderDebounce;

  // bookmarks
  final Set<int> _bookmarkedPages = <int>{};
  final Map<int, String> _pageSnippetCache = <int, String>{};
  final Set<int> _snippetLoading = <int>{};

  static const String _kBookmarksKey = "st_pdf_bookmarks_pages_v1";
  static const String _kSnippetsKey = "st_pdf_bookmarks_snippets_v1";

  // selection overlay
  OverlayEntry? _selectionMenu;
  String _selectedText = "";
  Rect? _selectedRect;

  // ✅ GIF timing: minimum time (increased for smoother guaranteed load)
  static const Duration _minGifDuration = Duration(seconds: 6);
  bool _minGifDone = false;
  Timer? _gifMinTimer;

  void _startMinGifTimer() {
    _gifMinTimer?.cancel();
    _minGifDone = false;
    _gifMinTimer = Timer(_minGifDuration, () {
      if (!mounted) return;
      setState(() => _minGifDone = true);
    });
  }

  // ✅ Show GIF until BOTH:
  // (1) min time done, AND (2) viewer is fully loaded (onDocumentLoaded fired)
  bool get _shouldShowGifInMiddle => !(_minGifDone && _viewerLoaded);

  bool _looksArabic(String s) {
    final re = RegExp(
      r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]',
    );
    return re.hasMatch(s);
  }

  final List<Map<String, dynamic>> _toc = const [
    {"title": "PREFACE", "page": 1},
    {"title": "ACKNOWLEDGEMENT", "page": 5},
    {"title": "INTRODUCTION", "page": 8},
    {"title": "Background", "page": 16},
    {"title": "Subtle Centres of Consciousness (latā’if)", "page": 18},
    {"title": "Aalam-e-Amr", "page": 20},
    {"title": "Aalam-e-Khalq", "page": 21},
    {"title": "The Position and Association of each latīfa", "page": 23},
    {"title": "Brief Explanation of the latā’if", "page": 25},
    {"title": "latīfa Qalb", "page": 25},
    {"title": "latīfa Ruh", "page": 25},
    {"title": "latīfa Sirr", "page": 25},
    {"title": "latīfa Khafi", "page": 26},
    {"title": "latīfa Akhfa", "page": 26},
    {"title": "latīfa Nafsi", "page": 26},
    {"title": "latīfa Qaalbi", "page": 27},
    {"title": "The Method of Nafy wa-Ithbāt", "page": 28},
    {"title": "Meditation (Murāqaba)", "page": 31},
    {"title": "Intentions (Waqoof-e Murāqaba)", "page": 35},
    {"title": "Intentions (Usūl-e Murāqaba)", "page": 42},
    {
      "title":
      "Sayings of Hazrat Sayyid Muhammad Bahā’ al-Dīn\nNaqshband al-Bukhārī",
      "page": 64
    },
    {"title": "What is Wajd?", "page": 80},
    {"title": "Instructions for a beginner starting\non the path", "page": 84},
    {"title": "Lessons of the Silsila-e-Chishtia Saifia", "page": 86},
    {"title": "First Lesson (Chishtia)", "page": 86},
    {"title": "Second Lesson (Chishtia)", "page": 87},
    {"title": "Third Lesson (Chishtia)", "page": 87},
    {"title": "Fourth Lesson (Chishtia)", "page": 88},
    {"title": "Lessons of the Silsila-e-Qadria Saifia", "page": 90},
    {"title": "First Lesson (Qadria)", "page": 91},
    {"title": "Second Lesson (Qadria)", "page": 92},
    {"title": "Third Lesson (Qadria)", "page": 93},
    {"title": "Fourth Lesson (Qadria)", "page": 93},
    {"title": "Fifth Lesson (Qadria)", "page": 94},
    {"title": "Sixth Lesson (Qadria)", "page": 95},
    {"title": "Seventh Lesson (Qadria)", "page": 95},
    {"title": "Eighth Lesson (Qadria)", "page": 96},
    {"title": "Ninth Lesson (Qadria)", "page": 97},
    {"title": "Lessons of the Silsila-e-Suhrawardia Saifia", "page": 99},
    {"title": "Ninth Lesson (Suhrawardia)", "page": 99},
    {"title": "Khatam-e-Khawajgan", "page": 102},
    {
      "title":
      "Spiritual Lineage of the Naqshbandia Mujaddidia\nSaifia Silsila",
      "page": 141
    },
    {"title": "Spiritual Lineage of the Chishtia Saifia Silsila", "page": 146},
    {"title": "Spiritual Lineage of the Qadria Saifia Silsila", "page": 152},
    {"title": "Spiritual Lineage of the Suhrawardia Saifia Silsila", "page": 156},
    {
      "title":
      "Peer Syed Muhammad Ali Raza Bukhari Sahibs\nAncestral History from Ahlulbayt",
      "page": 161
    },
  ];

  @override
  void initState() {
    super.initState();
    _isDark = widget.isDark;

    // ✅ minimum gif timer
    _startMinGifTimer();

    _loadPersistedBookmarks();

    // ✅ preload bytes/doc fast
    _preloadPdfStrong();
  }

  @override
  void didUpdateWidget(covariant Home oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isDark != widget.isDark) {
      setState(() => _isDark = widget.isDark);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w800)),
        duration: const Duration(milliseconds: 900),
        backgroundColor: const Color(0xFF1976D2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _loadPersistedBookmarks() async {
    try {
      final sp = await SharedPreferences.getInstance();

      final pages = sp.getStringList(_kBookmarksKey) ?? const <String>[];
      final loadedPages = pages
          .map((e) => int.tryParse(e) ?? -1)
          .where((p) => p > 0)
          .toSet();

      final snippetsJson = sp.getString(_kSnippetsKey);
      final Map<int, String> loadedSnips = {};
      if (snippetsJson != null && snippetsJson.isNotEmpty) {
        final decoded = jsonDecode(snippetsJson);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final k = int.tryParse(entry.key.toString());
            final v = entry.value?.toString() ?? "";
            if (k != null && k > 0 && v.isNotEmpty) loadedSnips[k] = v;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _bookmarkedPages
          ..clear()
          ..addAll(loadedPages);
        _pageSnippetCache
          ..clear()
          ..addAll(loadedSnips);
      });
    } catch (_) {}
  }

  Future<void> _persistBookmarks() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final pages = _bookmarkedPages.toList()..sort();
      await sp.setStringList(
        _kBookmarksKey,
        pages.map((e) => e.toString()).toList(),
      );

      final map = <String, String>{};
      for (final e in _pageSnippetCache.entries) {
        map[e.key.toString()] = e.value;
      }
      await sp.setString(_kSnippetsKey, jsonEncode(map));
    } catch (_) {}
  }

  Future<void> _preloadPdfStrong() async {
    if (mounted) {
      setState(() {
        _pdfReady = false;
        _pdfBytes = null;
        _viewerLoaded = false; // ✅ reset
      });
    }

    try {
      final data = await rootBundle.load('assets/st.pdf');
      final bytes = data.buffer.asUint8List();

      if (!mounted) return;

      _pdfDoc?.dispose();
      _pdfDoc = spdf.PdfDocument(inputBytes: bytes);
      _totalPages = _pdfDoc!.pages.count;

      setState(() {
        _pdfBytes = bytes;
        _pdfReady = true;
        _currentPage = 1;
        _pageSliderValue = 1.0;
        _isLastPage = (_totalPages > 0 && _currentPage == _totalPages);
      });

      unawaited(SearchTextCache.prewarm(bytes));

      for (final p in _bookmarkedPages) {
        if (!_pageSnippetCache.containsKey(p)) _ensureSnippetForPage(p);
      }
    } catch (e) {
      debugPrint("PDF preload failed: $e");
      if (!mounted) return;
      setState(() {
        _pdfReady = false;
        _pdfBytes = null;
        _viewerLoaded = false;
      });
    }
  }

  void _toggleBars() => setState(() => _barsVisible = !_barsVisible);

  void _toggleAuto() {
    setState(() {
      if (!_auto) {
        _lastManualDim = _dimN.value;
        _auto = true;
        _dimN.value = _autoDimValue;
      } else {
        _auto = false;
        _dimN.value = _lastManualDim;
      }
    });
  }

  void _onDimChanged(double v) {
    final newDim = v.clamp(0.0, 0.85);
    _auto = false;
    _lastManualDim = newDim;
    _dimN.value = newDim;
  }

  void _toggleThemeWithResume() {
    final currentCtrl = _isDark ? _darkCtrl : _lightCtrl;
    _resumePage = currentCtrl.pageNumber;
    _resumeZoom = currentCtrl.zoomLevel;

    final nextCtrl = _isDark ? _lightCtrl : _darkCtrl;

    setState(() => _isDark = !_isDark);
    widget.onToggleTheme();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final p = _resumePage < 1 ? 1 : _resumePage;
      nextCtrl.jumpToPage(p);
      nextCtrl.zoomLevel = _resumeZoom.clamp(1.0, 4.0);
    });
  }

  String _contentTitleForPdfPage(int pdfPage) {
    if (pdfPage < _prefacePdfStart) return "Front Matter";

    final tocPage = pdfPage - _pageOffset;
    Map<String, dynamic>? best;

    for (final item in _toc) {
      final p = item["page"] as int;
      if (p <= tocPage) {
        best = item;
      } else {
        break;
      }
    }
    if (best == null) return "Page ${_displayContentPage(pdfPage)}";
    return best["title"] as String;
  }

  String _buildFirstLast3(String raw) {
    final words = raw
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .split(' ')
        .where((w) => w.trim().isNotEmpty)
        .toList();

    if (words.isEmpty) return "…";

    final first3 = words.take(3).join(' ');
    final last3 =
    words.skip((words.length - 3).clamp(0, words.length)).join(' ');

    if (words.length <= 3) return first3;
    return "$first3 …… $last3";
  }

  Future<void> _ensureSnippetForPage(int page) async {
    if (_pageSnippetCache.containsKey(page)) return;
    if (_snippetLoading.contains(page)) return;
    _snippetLoading.add(page);

    try {
      final doc = _pdfDoc;
      if (doc == null) {
        _pageSnippetCache[page] = "…";
        return;
      }

      final total = doc.pages.count;
      final idx = (page - 1).clamp(0, total - 1);

      final extractor = spdf.PdfTextExtractor(doc);
      final pageText = extractor.extractText(
        startPageIndex: idx,
        endPageIndex: idx,
      );

      final snippet = _buildFirstLast3(pageText);

      if (!mounted) return;
      setState(() {
        _pageSnippetCache[page] = snippet.isEmpty ? "…" : snippet;
      });

      await _persistBookmarks();
    } catch (_) {
      if (!mounted) return;
      setState(() => _pageSnippetCache[page] = "…");
      await _persistBookmarks();
    } finally {
      _snippetLoading.remove(page);
    }
  }

  Future<void> _toggleBookmarkForCurrentPage() async {
    final p = (_currentCtrl.pageNumber < 1) ? 1 : _currentCtrl.pageNumber;

    setState(() {
      _currentPage = p;
      _isLastPage = (_totalPages > 0 && _currentPage == _totalPages);

      if (!_isDraggingSlider) _pageSliderValue = p.toDouble();

      if (_bookmarkedPages.contains(p)) {
        _bookmarkedPages.remove(p);
        _pageSnippetCache.remove(p);
      } else {
        _bookmarkedPages.add(p);
      }
    });

    await _persistBookmarks();
    if (_bookmarkedPages.contains(p)) _ensureSnippetForPage(p);
  }

  Future<void> _toggleBookmarkForPage(int page) async {
    final total = (_totalPages > 0) ? _totalPages : 173;
    final p = page.clamp(1, total);

    setState(() {
      if (_bookmarkedPages.contains(p)) {
        _bookmarkedPages.remove(p);
        _pageSnippetCache.remove(p);
      } else {
        _bookmarkedPages.add(p);
      }
    });

    await _persistBookmarks();
    if (_bookmarkedPages.contains(p)) _ensureSnippetForPage(p);
  }

  void _removeSelectionMenu() {
    try {
      _selectionMenu?.remove();
    } catch (_) {}
    _selectionMenu = null;
  }

  void _clearPdfSelection() {
    try {
      _currentCtrl.clearSelection();
    } catch (_) {}
  }

  Future<void> _translateSelection() async {
    final t = _selectedText.trim();
    if (t.isEmpty) return;

    final uri = Uri(
      scheme: "https",
      host: "translate.google.com",
      path: "/",
      queryParameters: {
        "sl": "auto",
        "tl": "ur",
        "text": t,
        "op": "translate",
      },
    );

    bool ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }

    if (!ok) {
      try {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      } catch (_) {}
    }

    _removeSelectionMenu();
    _clearPdfSelection();
  }

  Future<void> _openDefaultLikeMenu() async {
    final selected = await showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(1000, 0, 16, 0),
      color: const Color(0xFF0D47A1),
      items: const [
        PopupMenuItem(
          value: "copy",
          child: Text("Copy", style: TextStyle(color: Colors.white)),
        ),
        PopupMenuItem(
          value: "highlight",
          child: Text("Highlight", style: TextStyle(color: Colors.white)),
        ),
        PopupMenuItem(
          value: "underline",
          child: Text("Underline", style: TextStyle(color: Colors.white)),
        ),
        PopupMenuItem(
          value: "strike",
          child: Text("Strikethrough", style: TextStyle(color: Colors.white)),
        ),
      ],
    );

    if (selected == null) return;

    if (selected == "copy") {
      final t = _selectedText.trim();
      if (t.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: t));
        _showSnack("Copied");
      }
      _removeSelectionMenu();
      _clearPdfSelection();
      return;
    }

    if (selected == "highlight") _showSnack("Highlight (Coming soon)");
    if (selected == "underline") _showSnack("Underline (Coming soon)");
    if (selected == "strike") _showSnack("Strikethrough (Coming soon)");
  }

  void _showSelectionMenu(BuildContext context) {
    _removeSelectionMenu();

    final overlay = Overlay.of(context);
    if (overlay == null) return;

    final rect = _selectedRect;
    final media = MediaQuery.of(context);
    final safeTop = media.padding.top + 8;
    final safeLeft = 12.0;

    double top = safeTop + 60;
    double left = safeLeft;

    if (rect != null) {
      top = (rect.top - 52).clamp(safeTop, media.size.height - 120);
      left = (rect.left).clamp(10.0, media.size.width - 260);
    }

    Widget pillButton(String label, VoidCallback onTap) {
      return InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.black,
              fontWeight: FontWeight.w900,
              fontSize: 13,
            ),
          ),
        ),
      );
    }

    _selectionMenu = OverlayEntry(
      builder: (_) => Positioned(
        top: top,
        left: left,
        child: Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.98),
              borderRadius: BorderRadius.circular(14),
              boxShadow: const [
                BoxShadow(
                  blurRadius: 14,
                  offset: Offset(0, 8),
                  color: Color(0x33000000),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                pillButton("Copy", () async {
                  final t = _selectedText.trim();
                  if (t.isNotEmpty) {
                    await Clipboard.setData(ClipboardData(text: t));
                    _showSnack("Copied");
                  }
                  _removeSelectionMenu();
                  _clearPdfSelection();
                }),
                Container(width: 1, height: 26, color: Colors.black12),
                pillButton("Translate", _translateSelection),
                Container(width: 1, height: 26, color: Colors.black12),
                InkWell(
                  onTap: _openDefaultLikeMenu,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    child: Icon(Icons.more_vert, color: Colors.black87),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    overlay.insert(_selectionMenu!);
  }

  void _onTextSelectionChanged(PdfTextSelectionChangedDetails details) {
    final txt = (details.selectedText ?? "").trim();
    if (txt.isEmpty) {
      _selectedText = "";
      _selectedRect = null;
      _removeSelectionMenu();
      return;
    }

    _selectedText = txt;

    Rect? r;
    try {
      final dyn = details as dynamic;
      r = dyn.globalSelectedRegion as Rect?;
    } catch (_) {
      r = null;
    }
    _selectedRect = r;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showSelectionMenu(context);
    });
  }

  Future<void> _openSearchScreen() async {
    if (_pdfBytes == null) return;

    final int page =
    (_currentCtrl.pageNumber < 1) ? _currentPage : _currentCtrl.pageNumber;
    final double zoom = _currentCtrl.zoomLevel;

    final ret = await Navigator.of(context).push<SearchReturn>(
      MaterialPageRoute(
        builder: (_) => SearchScreen(
          pdfBytes: _pdfBytes!,
          isDark: _isDark,
          initialPage: page,
          initialZoom: zoom,
          cropScale: _cropScale,
          cropDx: _cropDx,
          cropDy: _cropDy,
          lastPageScale: _lastPageScale,
          lastPageDy: _lastPageDy,
          displayPageOffset: _pageOffset,
          toc: _toc,
        ),
      ),
    );

    if (!mounted || ret == null) return;

    setState(() {
      _currentPage = ret.page;
      _pageSliderValue = ret.page.toDouble();
      _isLastPage = (_totalPages > 0 && _currentPage == _totalPages);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _currentCtrl.jumpToPage(ret.page);
      _currentCtrl.zoomLevel = ret.zoom.clamp(1.0, 4.0);
    });
  }

  void _scheduleJumpToPage(int page) {
    final total = (_totalPages > 0) ? _totalPages : 173;
    final p = page.clamp(1, total);

    _sliderDebounce?.cancel();
    _sliderDebounce = Timer(const Duration(milliseconds: 70), () {
      if (!mounted) return;
      _currentCtrl.jumpToPage(p);
    });
  }

  Future<void> _openDrawerScreen() async {
    final ret = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DrawerScreen(
          isDark: _isDark,
          toc: _toc,
          pageOffset: _pageOffset,
          bookmarkedPages: _bookmarkedPages,
          pageSnippetCache: _pageSnippetCache,
          snippetLoading: _snippetLoading,
          contentTitleForPdfPage: _contentTitleForPdfPage,
          displayContentPage: _displayContentPage,
          looksArabic: _looksArabic,
          ensureSnippetForPage: _ensureSnippetForPage,
          toggleBookmarkForPage: _toggleBookmarkForPage,
          showSnack: _showSnack,
        ),
      ),
    );

    if (!mounted) return;

    if (ret is DrawerResult && ret.jumpToPdfPage != null) {
      final p = ret.jumpToPdfPage!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _currentCtrl.jumpToPage(p);
      });
    }
  }

  Widget _buildPdfViewer(
      Uint8List bytes,
      PdfViewerController ctrl, {
        required bool invertForDark,
      }) {
    final double scale = _isLastPage ? _lastPageScale : _cropScale;
    final double dy = _isLastPage ? _lastPageDy : _cropDy;

    final baseTheme = Theme.of(context);

    final themed = Theme(
      data: baseTheme.copyWith(
        textSelectionTheme: const TextSelectionThemeData(
          selectionColor: Color(0x552196F3),
          selectionHandleColor: Color(0xFF2196F3),
        ),
      ),
      child: CupertinoTheme(
        data: const CupertinoThemeData(primaryColor: Color(0xFF2196F3)),
        child: SfPdfViewerTheme(
          data: const SfPdfViewerThemeData(backgroundColor: Colors.black),
          child: SfPdfViewer.memory(
            bytes,
            controller: ctrl,
            scrollDirection: PdfScrollDirection.vertical,
            pageLayoutMode: PdfPageLayoutMode.continuous,
            canShowScrollHead: false,
            canShowScrollStatus: false,
            enableDoubleTapZooming: true,
            canShowPageLoadingIndicator: false,
            canShowTextSelectionMenu: false,
            onTextSelectionChanged: _onTextSelectionChanged,
            onDocumentLoaded: (details) {
              if (!mounted) return;

              // ✅ THIS is the real "ready" moment
              setState(() => _viewerLoaded = true);

              final total = details.document.pages.count;
              final cp = (ctrl.pageNumber < 1) ? 1 : ctrl.pageNumber;

              setState(() {
                _totalPages = total;
                _currentPage = cp;
                _isLastPage = (_totalPages > 0 && _currentPage == _totalPages);
                if (!_isDraggingSlider) _pageSliderValue = cp.toDouble();
              });
            },
            onPageChanged: (details) {
              if (!mounted) return;
              _removeSelectionMenu();
              setState(() {
                _currentPage = details.newPageNumber;
                _isLastPage = (_totalPages > 0 && _currentPage == _totalPages);
                if (!_isDraggingSlider) {
                  _pageSliderValue = _currentPage.toDouble();
                }
              });
            },
          ),
        ),
      ),
    );

    final cropped = RepaintBoundary(
      child: ClipRect(
        child: Transform.translate(
          offset: const Offset(_cropDx, 0),
          child: Transform.translate(
            offset: Offset(0, dy),
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topCenter,
              filterQuality: FilterQuality.low,
              child: themed,
            ),
          ),
        ),
      ),
    );

    if (!invertForDark) return cropped;

    return RepaintBoundary(
      child: ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          -1, 0, 0, 0, 255,
          0, -1, 0, 0, 255,
          0, 0, -1, 0, 255,
          0, 0, 0, 1, 0,
        ]),
        child: cropped,
      ),
    );
  }

  Widget _bottomNavSliderBar({required double bottomInset}) {
    final total = (_totalPages > 0) ? _totalPages : 173;

    final shownPage = (_isDraggingSlider
        ? _pageSliderValue.round()
        : (_currentPage < 1 ? 1 : _currentPage))
        .clamp(1, total);

    final sliderMin = 1.0;
    final sliderMax = total.toDouble();
    final safeValue = _pageSliderValue.clamp(sliderMin, sliderMax);

    return Container(
      height: 52 + bottomInset,
      color: barColor,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Center(
        child: SizedBox(
          width: MediaQuery.of(context).size.width * 0.86,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 6),
              Text(
                "$shownPage / $total",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                ),
              ),
              const SizedBox(height: 6),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2.0,
                  showValueIndicator: ShowValueIndicator.never,
                  overlayShape: SliderComponentShape.noOverlay,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
                  allowedInteraction: SliderInteraction.tapAndSlide,
                ),
                child: Slider(
                  value: safeValue,
                  min: sliderMin,
                  max: sliderMax,
                  divisions: (total - 1).clamp(1, 5000),
                  activeColor: Colors.white,
                  inactiveColor: Colors.white30,
                  onChangeStart: (_) => setState(() => _isDraggingSlider = true),
                  onChanged: (v) {
                    final p = v.round().clamp(1, total);
                    setState(() => _pageSliderValue = p.toDouble());
                    _scheduleJumpToPage(p);
                  },
                  onChangeEnd: (v) {
                    final p = v.round().clamp(1, total);
                    setState(() {
                      _pageSliderValue = p.toDouble();
                      _isDraggingSlider = false;
                    });
                    _currentCtrl.jumpToPage(p);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bookmarkCornerButton() {
    final p = _currentPage < 1 ? 1 : _currentPage;
    final isBookmarked = _bookmarkedPages.contains(p);

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      top: _barsVisible ? 120 : 76,
      right: 10,
      child: GestureDetector(
        onTap: _toggleBookmarkForCurrentPage,
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.92),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isBookmarked ? const Color(0xFF2196F3) : Colors.black12,
              width: 1.2,
            ),
            boxShadow: const [
              BoxShadow(
                blurRadius: 10,
                offset: Offset(0, 6),
                color: Color(0x22000000),
              ),
            ],
          ),
          child: Icon(
            isBookmarked ? Icons.bookmark : Icons.bookmark_border,
            color: isBookmarked ? const Color(0xFF1976D2) : Colors.black54,
            size: 24,
          ),
        ),
      ),
    );
  }

  Widget _normalTopBar({
    required double topInset,
    required double appRowH,
    required double brightRowH,
  }) {
    const double iconSize = 24;

    return SizedBox(
      height: topInset + appRowH + brightRowH,
      child: Column(
        children: [
          Container(height: topInset, color: barColor),
          Container(
            height: appRowH,
            color: barColor,
            child: Row(
              children: [
                const SizedBox(width: 6),
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    _openDrawerScreen();
                  },
                  child: const SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
                      child: Icon(Icons.menu,
                          color: Colors.white, size: iconSize),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Center(
                    child: Text(
                      "SAIFIA TEACHINGS",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: _openSearchScreen,
                  child: const SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
                      child: Icon(Icons.search,
                          color: Colors.white, size: iconSize),
                    ),
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: _toggleThemeWithResume,
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
                      child: Icon(
                        _isDark ? Icons.dark_mode : Icons.wb_sunny,
                        color: Colors.white,
                        size: iconSize,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
          Container(
            height: brightRowH,
            color: const Color(0xFFFDEDD8),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: _toggleAuto,
                  child: SizedBox(
                    width: 30,
                    height: 28,
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        child: _auto
                            ? Container(
                          key: const ValueKey("A_circle"),
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                            border: Border.all(
                                color: Colors.white, width: 2),
                          ),
                          child: const Center(
                            child: Text(
                              "A",
                              style: TextStyle(
                                color: barColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                height: 1.0,
                              ),
                            ),
                          ),
                        )
                            : const Icon(
                          Icons.brightness_6,
                          key: ValueKey("icon"),
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 1.6,
                      showValueIndicator: ShowValueIndicator.never,
                      overlayShape: SliderComponentShape.noOverlay,
                      thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                    ),
                    child: ValueListenableBuilder<double>(
                      valueListenable: _dimN,
                      builder: (_, dim, __) => Slider(
                        value: (0.85 - dim).clamp(0.0, 0.85),
                        min: 0.0,
                        max: 0.85,
                        onChanged: (v) {
                          final newDim = (0.85 - v).clamp(0.0, 0.85);
                          _onDimChanged(newDim);
                        },
                        activeColor: Colors.white,
                        inactiveColor: Colors.white30,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _removeSelectionMenu();
    _sliderDebounce?.cancel();
    _gifMinTimer?.cancel();
    _dimN.dispose();
    _pdfDoc?.dispose();
    _lightCtrl.dispose();
    _darkCtrl.dispose();
    super.dispose();
  }

  // tap/drag
  Offset? _pointerDownPos;
  bool _pointerMoved = false;

  void _onPointerDown(PointerDownEvent e) {
    _pointerDownPos = e.position;
    _pointerMoved = false;
  }

  void _onPointerMove(PointerMoveEvent e) {
    final down = _pointerDownPos;
    if (down == null) return;

    final dx = (e.position.dx - down.dx).abs();
    final dy = (e.position.dy - down.dy).abs();
    if (dx > _tapSlop || dy > _tapSlop) _pointerMoved = true;
  }

  void _onPointerUp(PointerUpEvent e) {
    if (_pointerMoved) return;
    _toggleBars();
  }

  @override
  Widget build(BuildContext context) {
    final double topInset = MediaQuery.of(context).padding.top;
    final double bottomInset = MediaQuery.of(context).padding.bottom;

    final double appRowH = 48;
    final double brightRowH = 32;

    final double topBarsTotalFull = topInset + appRowH + brightRowH;
    final double pdfTopPad =
    (topBarsTotalFull - 60).clamp(0.0, topBarsTotalFull);

    final double bottomBarH = 52 + bottomInset;

    // ✅ Always mount viewers in background once bytes are available,
    // so when GIF ends, PDF is already loaded (instant view).
    Widget viewersIndexed() => IndexedStack(
      index: _isDark ? 1 : 0,
      children: [
        _buildPdfViewer(_pdfBytes!, _lightCtrl, invertForDark: false),
        _buildPdfViewer(_pdfBytes!, _darkCtrl, invertForDark: true),
      ],
    );

    final middleArea = Positioned.fill(
      child: Padding(
        padding: EdgeInsets.only(
          top: pdfTopPad,
          bottom: (_barsVisible) ? bottomBarH : 0,
        ),
        child: Stack(
          children: [
            // ✅ PDF viewer is mounted early (opacity 0 while GIF)
            if (_pdfReady && _pdfBytes != null)
              IgnorePointer(
                ignoring: _shouldShowGifInMiddle,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 120),
                  opacity: _shouldShowGifInMiddle ? 0.0 : 1.0,
                  child: viewersIndexed(),
                ),
              )
            else
            // bytes not ready yet: just keep black behind
              Container(color: Colors.black),

            // ✅ GIF overlay in middle area (white bg)
            if (_shouldShowGifInMiddle)
              Container(
                color: Colors.white,
                alignment: Alignment.center,
                child: const SizedBox(
                  width: 170,
                  height: 170,
                  child: Image(
                    image: AssetImage('assets/images/gif.gif',),
                    fit: BoxFit.contain,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return Stack(
      children: [
        Scaffold(
          body: Stack(
            children: [
              middleArea,
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: _onPointerDown,
                  onPointerMove: _onPointerMove,
                  onPointerUp: _onPointerUp,
                ),
              ),
              _bookmarkCornerButton(),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeInOut,
                top: (_barsVisible) ? 0 : -topBarsTotalFull,
                left: 0,
                right: 0,
                child: _normalTopBar(
                  topInset: topInset,
                  appRowH: appRowH,
                  brightRowH: brightRowH,
                ),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeInOut,
                left: 0,
                right: 0,
                bottom: (_barsVisible) ? 0 : -bottomBarH,
                child: _bottomNavSliderBar(bottomInset: bottomInset),
              ),
            ],
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: true,
            child: ValueListenableBuilder<double>(
              valueListenable: _dimN,
              builder: (_, dim, __) => AnimatedOpacity(
                duration: const Duration(milliseconds: 90),
                opacity: dim.clamp(0.0, 0.85),
                child: Container(color: Colors.black),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
