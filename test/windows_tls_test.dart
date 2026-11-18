import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:todo_endfield/windows_tls.dart';

class TestCertificate implements X509Certificate {
  TestCertificate(this.der, {bool expired = false}) {
    startValidity = DateTime.now().subtract(const Duration(days: 2));
    endValidity = DateTime.now().add(Duration(days: expired ? -1 : 1));
  }
  @override
  final Uint8List der;
  @override
  late final DateTime startValidity, endValidity;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('Windows TLS retry binds the validated leaf, endpoint and validity', () {
    final target = Uri.parse('https://todo.example/');
    final valid = TestCertificate(Uint8List.fromList([1, 2, 3]));
    bool accepts(X509Certificate cert, String host, int port, List<int> expected) =>
      matchesVerifiedCertificate(cert, expected, host, port, target);
    expect(accepts(valid, 'todo.example', 443, [1, 2, 3]), isTrue);
    expect(accepts(valid, 'other.example', 443, [1, 2, 3]), isFalse);
    expect(accepts(valid, 'todo.example', 8443, [1, 2, 3]), isFalse);
    expect(accepts(valid, 'todo.example', 443, [1, 2, 4]), isFalse);
    expect(accepts(valid, 'todo.example', 443, [1, 2]), isFalse);
    final expired = TestCertificate(Uint8List.fromList([1, 2, 3]), expired: true);
    expect(accepts(expired, 'todo.example', 443, [1, 2, 3]), isFalse);
  });
}
