import '../../../platform/sync/den_network.dart';
import '../../../platform/sync/hub_api.dart';

/// A read-only address for the family's calendar (or one person's) that a phone's calendar app
/// subscribes to: "Show Den in iPhone Calendar". The hub makes it for a parent's own device and
/// shows its address once ([url], [webcal]); after that it is listed by [label] and can be
/// turned off. A [shared] one is for another family: their hub adds it as a calendar by link and
/// gets the family's Everyone events only. See docs/hub-api.md, "Calendar links".
class FeedLink {
  const FeedLink({
    required this.id,
    required this.label,
    required this.feed,
    required this.made,
    this.feedName,
    this.madeBy,
    this.url,
    this.webcal,
  });

  factory FeedLink.fromJson(Map<String, Object?> json) => FeedLink(
        id: json['id'] as String? ?? '',
        label: json['label'] as String? ?? 'A calendar',
        feed: json['feed'] as String? ?? 'family',
        feedName: json['feed_name'] as String?,
        madeBy: json['made_by_name'] as String?,
        made: (json['made_ms'] as num?)?.toInt() ?? 0,
        url: json['url'] as String?,
        webcal: json['webcal'] as String?,
      );

  final String id;
  final String label;

  /// `family`, `shared` (for another family), or the member whose events it holds.
  final String feed;
  final String? feedName;
  final String? madeBy;

  /// When it was made (UTC ms).
  final int made;

  /// Its address, only right after it was made.
  final String? url;
  final String? webcal;

  bool get family => feed == 'family';

  /// For another family: the family's Everyone events only.
  bool get shared => feed == sharedFeed;

  /// The [feed] of a link for another family.
  static const String sharedFeed = 'shared';
}

/// Where calendar links come from: the hub, or a fake in tests.
abstract interface class FeedLinksSource {
  Future<List<FeedLink>> list();

  /// Makes a link for [feed] (`family`, `shared` or a member id), named [label]; the answer
  /// holds its address, this once.
  Future<FeedLink> create({required String feed, required String label});

  Future<void> remove(String id);
}

/// The hub's calendar links (`/api/v1/feeds`), from a parent's own device.
class HubFeedLinks implements FeedLinksSource {
  HubFeedLinks(DenNetwork network) : _api = HubApi(network);

  final HubApi _api;

  static const _old = "The family's hub can't make calendar links yet. Update the hub, then try again.";

  @override
  Future<List<FeedLink>> list() async {
    final json = await _api.send('GET', '/api/v1/feeds', missing: _old);
    return [
      if (json['feeds'] case final List<Object?> feeds)
        for (final f in feeds)
          if (f is Map) FeedLink.fromJson(f.cast<String, Object?>()),
    ];
  }

  @override
  Future<FeedLink> create({required String feed, required String label}) async =>
      FeedLink.fromJson(await _api.send('POST', '/api/v1/feeds', body: {'feed': feed, 'label': label}, missing: _old));

  @override
  Future<void> remove(String id) => _api.send('DELETE', '/api/v1/feeds/$id');
}
