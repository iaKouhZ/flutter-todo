import 'dart:async';
import 'dart:convert';
import 'dart:io';

class WindowsCertificateResult {
  const WindowsCertificateResult(this.accepted, this.reason);
  final bool accepted;
  final String reason;
}

/// Validate with Windows' SSL chain policy, including hostname, validity,
/// server-auth usage and trusted roots. No certificate is installed by this app.
Future<WindowsCertificateResult> verifyWindowsCertificate(
    List<int> der, String host) async {
  if (!Platform.isWindows) {
    return const WindowsCertificateResult(false, 'Windows 验证仅适用于 Windows。');
  }
  Process? process;
  try {
    final helper = File(Platform.resolvedExecutable).parent.uri
        .resolve('ledger_tls.exe').toFilePath();
    process = await Process.start(helper, [host]);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    process.stdin.add(der);
    await process.stdin.close();
    final code = await process.exitCode.timeout(const Duration(seconds: 25));
    final message = (await output).trim();
    await errors;
    return WindowsCertificateResult(code == 0,
      message.isEmpty ? (code == 0 ? 'Windows 证书链验证通过。' : 'Windows 无法验证此证书（代码 $code）。') : message);
  } on TimeoutException {
    process?.kill();
    return const WindowsCertificateResult(false, 'Windows 证书链验证超时，请检查网络和系统证书更新。');
  } on Object catch (error) {
    process?.kill();
    return WindowsCertificateResult(false, '无法运行 Windows 证书验证：$error');
  }
}

/// A successful platform check authorizes only the exact certificate and
/// endpoint from that check, for this retry. TLS still proves key ownership.
bool matchesVerifiedCertificate(X509Certificate presented, List<int> expected,
    String host, int port, Uri target) {
  final now = DateTime.now();
  if (host != target.host || port != target.port ||
      now.isBefore(presented.startValidity) || !now.isBefore(presented.endValidity)) {
    return false;
  }
  final bytes = presented.der;
  if (bytes.length != expected.length) return false;
  for (var index = 0; index < bytes.length; index++) {
    if (bytes[index] != expected[index]) return false;
  }
  return true;
}
