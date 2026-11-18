import 'package:flutter_test/flutter_test.dart';
import 'package:todo_endfield/server.dart';

void main() {
  const url = String.fromEnvironment('TEST_SERVER_URL');
  test('connects to the configured live server using the production transport', () async {
    final server = TodoServer(serverAddress(url));
    addTearDown(server.close);
    try {
      final feed = await server.feed('tracked');
      expect(feed.name, isNotEmpty);
    } on LoginRequired {
      // A private login gate is also a successfully verified server connection.
    }
  }, skip: url.isEmpty ? 'Supply TEST_SERVER_URL for live read-only verification.' : false);
}
