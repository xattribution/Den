import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// Leaves a pushed page with [result], or goes to [fallback] when there is nothing to go back to
/// (the page was opened straight from a link or a notification).
void closePage(BuildContext context, {Object? result, String fallback = '/calendar'}) {
  if (context.canPop()) {
    context.pop(result);
  } else {
    context.go(fallback);
  }
}
