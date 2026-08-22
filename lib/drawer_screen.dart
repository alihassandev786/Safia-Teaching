import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class DrawerResult {
  final int? jumpToPdfPage;
  const DrawerResult({this.jumpToPdfPage});
}

class DrawerScreen extends StatefulWidget {
  static const Color barColor = Color(0xff1f474e);

  final bool isDark;

  // ✅ same data you already have
  final List<Map<String, dynamic>> toc;
  final int pageOffset;

  final Set<int> bookmarkedPages;
  final Map<int, String> pageSnippetCache;
  final Set<int> snippetLoading;

  final String Function(int pdfPage) contentTitleForPdfPage;
  final int Function(int pdfPage) displayContentPage;
  final bool Function(String s) looksArabic;

  // ✅ callbacks (no logic change, parent Home does the same work)
  final void Function(int page) ensureSnippetForPage;
  final Future<void> Function(int page) toggleBookmarkForPage;
  final void Function(String msg) showSnack;

  const DrawerScreen({
    super.key,
    required this.isDark,
    required this.toc,
    required this.pageOffset,
    required this.bookmarkedPages,
    required this.pageSnippetCache,
    required this.snippetLoading,
    required this.contentTitleForPdfPage,
    required this.displayContentPage,
    required this.looksArabic,
    required this.ensureSnippetForPage,
    required this.toggleBookmarkForPage,
    required this.showSnack,
  });

  @override
  State<DrawerScreen> createState() => _DrawerScreenState();
}

class _DrawerScreenState extends State<DrawerScreen> {
  static const Color barColor = DrawerScreen.barColor;

  Color get _drawerBg => widget.isDark ? Colors.black : Colors.white;
  Color get _drawerText => widget.isDark ? Colors.white : Colors.black;
  Color get _drawerMutedText =>
      widget.isDark ? Colors.white.withOpacity(0.70) : Colors.black.withOpacity(0.65);
  Color get _drawerBorder =>
      widget.isDark ? Colors.white.withOpacity(0.22) : Colors.black.withOpacity(0.26);
  Color get _drawerCardBg => widget.isDark ? Colors.black : Colors.white;

  int _tocToPdfPage(int tocPage) {
    final pdfPage = tocPage + widget.pageOffset; // ✅ offset=8 => printed 1 => PDF 9
    return pdfPage < 1 ? 1 : pdfPage;
  }

  Widget _header(BuildContext context, double topInset) {
    const double appRowH = 48;
    return Container(
      height: topInset + appRowH,
      padding: EdgeInsets.only(top: topInset),
      color: barColor,
      child: Row(
        children: [
          const SizedBox(width: 10),
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => Navigator.of(context).pop(const DrawerResult()),
            child: SizedBox(
              width: 40,
              height: 40,
              child: Center(
                child: CircleAvatar(
                  radius: 15,
                  backgroundColor: Colors.white.withOpacity(0.35),
                  child: const Icon(
                    CupertinoIcons.back,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ),
          ),
          const Expanded(
            child: Center(
              child: Text(
                "SAIFIA TEACHINGS",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(width: 50),
        ],
      ),
    );
  }

  Widget _tocRowTile(BuildContext context, String title, int tocPage) {
    final showTitle = title.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          final pdfPage = _tocToPdfPage(tocPage);
          Navigator.of(context).pop(DrawerResult(jumpToPdfPage: pdfPage));
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            color: _drawerCardBg,
            border: Border.all(color: _drawerBorder, width: 1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  showTitle,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: _drawerText,
                    height: 1.15,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                "$tocPage",
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  color: _drawerText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ✅ BOOKMARK TAB
  Widget _bookmarksTab(BuildContext context) {
    final pages = widget.bookmarkedPages.toList()..sort();
    if (pages.isEmpty) {
      return Center(
        child: Text(
          "No bookmarks yet.\nTap the upper-right bookmark while reading.",
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: _drawerText,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(top: 10, bottom: 12),
      itemCount: pages.length,
      itemBuilder: (context, i) {
        final page = pages[i];
        if (!widget.pageSnippetCache.containsKey(page)) {
          widget.ensureSnippetForPage(page);
        }

        final title = widget.contentTitleForPdfPage(page);
        final String? snippet = widget.pageSnippetCache[page];
        final loading = widget.snippetLoading.contains(page) && snippet == null;

        final shownPage = widget.displayContentPage(page);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              Navigator.of(context).pop(DrawerResult(jumpToPdfPage: page));
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: _drawerCardBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF2196F3), width: 1),
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 10,
                    offset: Offset(0, 6),
                    color: Color(0x11000000),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.bookmark, color: Color(0xFF1976D2)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            color: _drawerText,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          loading ? "Loading…" : (snippet ?? "…"),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: _drawerMutedText,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text(
                              "P$shownPage",
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                color: _drawerMutedText,
                              ),
                            ),
                            const Spacer(),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right,
                      color: widget.isDark ? Colors.white38 : Colors.black38),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _contentsTab(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 10),
      itemCount: widget.toc.length,
      itemBuilder: (context, i) {
        final item = widget.toc[i];
        return _tocRowTile(
          context,
          item["title"] as String,
          item["page"] as int,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: _drawerBg,
      body: Column(
        children: [
          _header(context, topInset),
          DefaultTabController(
            length: 2,
            child: Expanded(
              child: Column(
                children: [
                  Container(
                    color: barColor,
                    child: const TabBar(
                      indicatorColor: Color(0xFFFFD54F),
                      labelColor: Colors.white,
                      unselectedLabelColor: Colors.white70,
                      labelStyle: TextStyle(fontWeight: FontWeight.w900),
                      tabs: [
                        Tab(text: "CONTENTS"),
                        Tab(text: "BOOKMARKS"),
                      ],
                    ),
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        Container(color: _drawerBg, child: _contentsTab(context)),
                        Container(color: _drawerBg, child: _bookmarksTab(context)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
