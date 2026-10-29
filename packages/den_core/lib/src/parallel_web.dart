/// Browsers run Den on one thread: no worker isolates.
int get workers => 1;

/// Runs [work] here.
Future<T> run<T>(Future<T> Function() work) => work();
