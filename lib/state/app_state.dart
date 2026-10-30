import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async' show unawaited;

import '../data/coffee_repository.dart';
import '../data/sample_data.dart';
import '../models/coffee_bean.dart';
import '../models/coffee_shop.dart';
import '../models/tried_coffee.dart';
import '../services/notification_service.dart';
import '../services/user_data_sync.dart';

/// App-wide state: catalogue, wishlist, tasting log, ratings, and
/// recommendation tuning. Provided above [MaterialApp] via [AppStateScope].
///
/// Personal data (tastings, wishlist) can optionally sync to Firestore for
/// a signed-in user via [attachRemote]; all sync is best-effort and the
/// in-memory state is always the source of truth for the UI.
class AppState extends ChangeNotifier {
  List<CoffeeBean> _beans = SampleData.beans;
  List<CoffeeShop> _shops = SampleData.shops;

  final Set<String> _wishlistBeanIds = {};
  final Map<String, double> _ratings = {};
  final List<TriedCoffee> _tried = [];

  /// Barcode -> beanId links the user created by scanning bags.
  /// Catalogue beans can also carry a roaster-provided [CoffeeBean.barcode].
  final Map<String, String> _barcodeLinks = {};

  String roastPreference = 'Medium';
  double surpriseMe = 0.5;
  bool decafOnly = false;

  /// Appearance: follows the system by default; the user can pin
  /// Light or Dark from Profile → Information.
  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  void setThemeMode(ThemeMode mode) {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
  }

  // ——— Navigation ———

  /// Active bottom-tab index. Owned here (not in AppShell) so any
  /// screen — e.g. the bean detail sheet — can jump tabs.
  /// Tab order: 0 Home, 1 Catalogue, 2 Map, 3 Stats, 4 Profile.
  int _tabIndex = 0;
  int get tabIndex => _tabIndex;

  void setTabIndex(int index) {
    if (_tabIndex == index) return;
    _tabIndex = index;
    notifyListeners();
  }

  /// Shop the Map tab should focus next (bean detail "where to buy"
  /// link). Consumed once by ShopsScreen, then cleared.
  String? _mapFocusShopId;
  String? get mapFocusShopId => _mapFocusShopId;

  void focusShopOnMap(String shopId) {
    _mapFocusShopId = shopId;
    _tabIndex = 2; // Map tab.
    notifyListeners();
  }

  void clearMapFocus() {
    _mapFocusShopId = null;
  }

  /// The user's display name, editable from Profile → Information.
  /// Blank by default so testers never see someone else's name.
  static const _userNameKey = 'roasted_user_name';
  String _userName = '';
  String get userName => _userName;

  /// Loads locally persisted preferences. Called once at startup.
  Future<void> loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _userName = prefs.getString(_userNameKey) ?? '';
    notifyListeners();
  }

  Future<void> setUserName(String name) async {
    final trimmed = name.trim();
    if (trimmed == _userName) return;
    _userName = trimmed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userNameKey, _userName);
    notifyListeners();
    // The leaderboard stores a snapshot of the name; push the new one
    // there too, otherwise the board keeps showing the old snapshot.
    unawaited(_syncLeaderboardName());
  }

  /// Pushes the local display name into the leaderboard doc, so the board
  /// never keeps showing a stale snapshot (e.g. 'Coffee lover' recorded
  /// before the name was ever set). Best-effort: never blocks the UI.
  Future<void> _syncLeaderboardName() async {
    final uid = _uid;
    if (uid == null || _userName.isEmpty) return;
    try {
      await FirebaseFirestore.instance
          .collection('leaderboard')
          .doc(uid)
          .set({'userName': _userName}, SetOptions(merge: true));
    } catch (_) {}
  }

  String? _uid;
  UserDataSync? _sync;

  /// Firebase uid of the signed-in user, null when signed out.
  String? get uid => _uid;

  // ——— Catalogue ———

  /// Beans served in the launch regions only, parallel to [shops]:
  /// a bean is hidden when its "where to buy" shop sits in a region
  /// outside [launchShopRegions] (Ottawa/Gatineau for launch step 1).
  /// Beans with no matching shop stay visible. The data stays in the
  /// catalogue, so step 2 re-enables them by extending the allowlist.
  /// Note: [beanFor] still resolves from the full list, so existing
  /// tastings, wishlist entries, and barcode scans keep working.
  List<CoffeeBean> get beans => List.unmodifiable(
        _beans.where((bean) {
          final whereToBuy = bean.whereToBuy?.toLowerCase();
          if (whereToBuy == null || whereToBuy.isEmpty) return true;
          final shop = _shops
              .where((s) => s.name.toLowerCase() == whereToBuy)
              .firstOrNull;
          if (shop == null) return true;
          return launchShopRegions.contains(shop.region);
        }),
      );
  /// Shops in the launch regions only (see [launchShopRegions]):
  /// step 1 is Toronto only, so Ottawa/Gatineau shops are hidden
  /// everywhere until step 2 re-enables them.
  List<CoffeeShop> get shops => List.unmodifiable(
        _shops.where((s) => launchShopRegions.contains(s.region)),
      );

  CoffeeBean? beanFor(String id) {
    for (final bean in _beans) {
      if (bean.id == id) return bean;
    }
    return null;
  }

  /// Loads the catalogue from Firestore when available, otherwise keeps
  /// the bundled seed data.
  Future<void> refreshCatalogue({required bool firebaseEnabled}) async {
    final catalogue = await loadCatalogue(firebaseEnabled: firebaseEnabled);
    _beans = catalogue.beans;
    _shops = catalogue.shops;
    notifyListeners();
  }

  // ——— Remote sync ———

  /// Attaches Firestore sync for a signed-in user and pulls their
  /// remote tastings + wishlist + barcode links into local state.
  Future<void> attachRemote({
    required String uid,
    required UserDataSync sync,
  }) async {
    _uid = uid;
    _sync = sync;
    unawaited(NotificationService.instance.setUser(uid));
    // Heal a stale leaderboard name snapshot from before the name was set.
    unawaited(_syncLeaderboardName());
    final remote = await sync.pull(uid);
    if (remote.tastings.isNotEmpty) {
      _tried
        ..clear()
        ..addAll(remote.tastings);
      for (final t in remote.tastings) {
        _ratings[t.beanId] = t.rating;
      }
    }
    if (remote.wishlist.isNotEmpty) {
      _wishlistBeanIds
        ..clear()
        ..addAll(remote.wishlist);
    }
    if (remote.barcodeLinks.isNotEmpty) {
      _barcodeLinks
        ..clear()
        ..addAll(remote.barcodeLinks);
    }
    notifyListeners();
  }

  void detachRemote() {
    _uid = null;
    _sync = null;
    unawaited(NotificationService.instance.setUser(null));
  }

  // ——— Wishlist ———

  Set<String> get wishlistBeanIds => Set.unmodifiable(_wishlistBeanIds);

  bool isWishlisted(String beanId) => _wishlistBeanIds.contains(beanId);

  List<CoffeeBean> get wishlistedBeans => [
        for (final bean in _beans)
          if (_wishlistBeanIds.contains(bean.id)) bean,
      ];

  void toggleWishlist(String beanId) {
    if (_wishlistBeanIds.contains(beanId)) {
      _wishlistBeanIds.remove(beanId);
    } else {
      _wishlistBeanIds.add(beanId);
    }
    notifyListeners();
    final uid = _uid;
    if (uid != null) {
      _sync?.pushWishlist(uid, _wishlistBeanIds);
    }
  }

  // ——— Barcode links ———

  /// Resolves a scanned barcode to a catalogue bean: first the
  /// roaster-provided [CoffeeBean.barcode], then the user's own links.
  CoffeeBean? beanForBarcode(String barcode) {
    for (final bean in _beans) {
      if (bean.barcode == barcode) return bean;
    }
    final beanId = _barcodeLinks[barcode];
    if (beanId != null) return beanFor(beanId);
    return null;
  }

  /// Links a scanned barcode to a catalogue bean. Remembered for the
  /// user (and synced when signed in) so the next scan resolves instantly.
  void linkBarcode(String barcode, String beanId) {
    _barcodeLinks[barcode] = beanId;
    notifyListeners();
    final uid = _uid;
    if (uid != null) {
      _sync?.pushBarcodeLinks(uid, Map.unmodifiable(_barcodeLinks));
    }
  }

  // ——— Ratings ———

  double? ratingFor(String beanId) => _ratings[beanId];

  void setRating(String beanId, double rating) {
    _ratings[beanId] = rating;
    notifyListeners();
  }

  // ——— Tasting log ———

  /// Coffees the user has logged as tried, newest last.
  List<TriedCoffee> get triedCoffees => List.unmodifiable(_tried);

  bool hasTried(String beanId) => _tried.any((t) => t.beanId == beanId);

  /// Tastings grouped by bean: one entry per bean with its tastings
  /// newest first. Beans ordered by most recent tasting.
  List<(CoffeeBean, List<TriedCoffee>)> get tastingsByBean {
    final byBean = <String, List<TriedCoffee>>{};
    for (final t in _tried) {
      byBean.putIfAbsent(t.beanId, () => []).add(t);
    }
    final entries = <(CoffeeBean, List<TriedCoffee>)>[];
    for (final entry in byBean.entries) {
      final bean = beanFor(entry.key);
      if (bean == null) continue;
      final tastings = entry.value
        ..sort((a, b) => b.date.compareTo(a.date));
      entries.add((bean, tastings));
    }
    entries.sort((a, b) => b.$2.first.date.compareTo(a.$2.first.date));
    return entries;
  }

  void logTasting(TriedCoffee tried) {
    _tried.add(tried);
    // Keep the per-bean rating in sync with the latest tasting.
    _ratings[tried.beanId] = tried.rating;
    notifyListeners();
    final uid = _uid;
    if (uid != null) {
      _sync?.pushTasting(uid, tried);
    }
  }

  void removeTasting(TriedCoffee tried) {
    _tried.remove(tried);
    notifyListeners();
    final uid = _uid;
    if (uid != null) {
      _sync?.removeTasting(uid, tried.id);
    }
  }

  // ——— Café Perks ———

  /// Check-ins needed at one shop to earn a free coffee.
  static const int perkThreshold = 10;

  final Map<String, int> _perkCheckIns = {};

  /// Check-in counts per shop id. Local-only state.
  Map<String, int> get perkCheckIns => Map.unmodifiable(_perkCheckIns);

  int perkVisitsFor(String shopId) => _perkCheckIns[shopId] ?? 0;

  bool perkRewardReady(String shopId) =>
      perkVisitsFor(shopId) >= perkThreshold;

  void checkInAtShop(String shopId) {
    _perkCheckIns.update(shopId, (v) => v + 1, ifAbsent: () => 1);
    notifyListeners();
  }

  void redeemPerk(String shopId) {
    _perkCheckIns.remove(shopId);
    notifyListeners();
  }

  // ——— Tuning ———

  void updateTuning({String? roast, double? surprise, bool? decaf}) {
    if (roast != null) roastPreference = roast;
    if (surprise != null) surpriseMe = surprise;
    if (decaf != null) decafOnly = decaf;
    notifyListeners();
  }

  /// Convenience accessor for [AppStateScope.of].
  static AppState of(BuildContext context) => AppStateScope.of(context);
}

/// Exposes [AppState] to the widget tree.
class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({
    super.key,
    required AppState state,
    required super.child,
  }) : super(notifier: state);

  static AppState of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'AppStateScope not found in widget tree.');
    return scope!.notifier!;
  }
}
