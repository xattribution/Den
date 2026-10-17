import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Largest calendar file the hub reads.
const int maxFeedBytes = 10 * 1024 * 1024;

/// How long one fetch may take.
const Duration feedTimeout = Duration(seconds: 15);

/// What fetching a feed gave.
class FeedFetch {
  const FeedFetch._({this.text, this.etag, this.modified, this.notModified = false, this.problem});

  /// The body, when it changed.
  final String? text;

  /// ETag for the next conditional request.
  final String? etag;

  /// Last-Modified for the next conditional request.
  final String? modified;

  /// The server said nothing changed (304).
  final bool notModified;

  /// Why it failed, in words for people; null on success.
  final String? problem;

  /// Whether the problem is worth retrying later (the server or network, not the link).
  bool get temporary => problem != null && !problem!.startsWith('That link');
}

/// The URL to fetch for a feed address: `webcal://` becomes `https://`.
Uri feedUri(String address) {
  final trimmed = address.trim();
  final uri = Uri.parse(trimmed);
  if (uri.scheme == 'webcal' || uri.scheme == 'webcals') return uri.replace(scheme: 'https');
  return uri;
}

/// Fetches [address] with a conditional GET, a [feedTimeout] and a [maxFeedBytes] cap.
Future<FeedFetch> fetchFeed(http.Client client, String address, {String? etag, String? modified}) async {
  final Uri uri;
  try {
    uri = feedUri(address);
  } on FormatException {
    return const FeedFetch._(problem: 'That link isn\'t a web address.');
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    return const FeedFetch._(problem: 'That link isn\'t a web address Den can fetch.');
  }
  final request = http.Request('GET', uri)
    ..followRedirects = true
    ..maxRedirects = 5
    ..headers['accept'] = 'text/calendar, */*;q=0.5'
    ..headers['user-agent'] = 'den_hub (calendar feed)';
  if (etag != null) request.headers['if-none-match'] = etag;
  if (modified != null) request.headers['if-modified-since'] = modified;
  try {
    final response = await client.send(request).timeout(feedTimeout);
    if (response.statusCode == 304) {
      await response.stream.drain<void>();
      return FeedFetch._(notModified: true, etag: etag, modified: modified);
    }
    if (response.statusCode == 404 || response.statusCode == 410 || response.statusCode == 401 || response.statusCode == 403) {
      await response.stream.drain<void>();
      return FeedFetch._(problem: 'That link doesn\'t work anymore: the server answered ${response.statusCode}');
    }
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      return FeedFetch._(problem: 'The calendar\'s server answered ${response.statusCode}. Den will try again.');
    }
    final declared = response.contentLength;
    if (declared != null && declared > maxFeedBytes) {
      return const FeedFetch._(problem: 'That calendar is bigger than 10 MB, so Den can\'t use it.');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(feedTimeout)) {
      bytes.addAll(chunk);
      if (bytes.length > maxFeedBytes) {
        return const FeedFetch._(problem: 'That calendar is bigger than 10 MB, so Den can\'t use it.');
      }
    }
    return FeedFetch._(
      text: utf8.decode(bytes, allowMalformed: true),
      etag: response.headers['etag'],
      modified: response.headers['last-modified'],
    );
  } on TimeoutException {
    return const FeedFetch._(problem: 'The calendar\'s server didn\'t answer in time. Den will try again.');
  } on Object {
    return const FeedFetch._(problem: 'Den couldn\'t reach that calendar. Den will try again.');
  }
}
