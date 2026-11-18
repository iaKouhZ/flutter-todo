param([Parameter(Mandatory = $true)][string]$Verifier)
$ErrorActionPreference = 'Stop'
$verifierPath = (Resolve-Path $Verifier).Path

# Test-only temporary CA in the ephemeral Actions runner's CurrentUser store.
# The application and verifier never install certificates.
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

public static class LedgerTlsPolicyTests {
    static CertificateRequest Request(RSA key, string name, string usage) {
        var request = new CertificateRequest("CN=" + name, key,
            HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        var names = new SubjectAlternativeNameBuilder();
        names.AddDnsName(name);
        request.CertificateExtensions.Add(names.Build());
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        var usages = new OidCollection();
        usages.Add(new Oid(usage));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(usages, true));
        return request;
    }

    static void Check(string verifier, byte[] certificate, string host,
                      bool expected, string label, string errorCode = null) {
        var info = new ProcessStartInfo(verifier, host) {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        using (var process = Process.Start(info)) {
            var output = process.StandardOutput.ReadToEndAsync();
            var errors = process.StandardError.ReadToEndAsync();
            process.StandardInput.BaseStream.Write(certificate, 0, certificate.Length);
            process.StandardInput.Close();
            if (!process.WaitForExit(30000)) {
                process.Kill();
                throw new Exception(label + ": verifier timed out");
            }
            var text = output.GetAwaiter().GetResult();
            errors.GetAwaiter().GetResult();
            if ((process.ExitCode == 0) != expected ||
                (errorCode != null && !text.Contains(errorCode))) {
                throw new Exception(label + ": unexpected result " + process.ExitCode + " " + text);
            }
            Console.WriteLine("Windows TLS policy: " + label + " passed");
        }
    }

    public static void Run(string verifier) {
        var now = DateTimeOffset.UtcNow;
        using (var rootKey = RSA.Create(2048))
        using (var leafKey = RSA.Create(2048)) {
            var rootRequest = new CertificateRequest("CN=Todo TLS CI " + Guid.NewGuid(),
                rootKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            rootRequest.CertificateExtensions.Add(
                new X509BasicConstraintsExtension(true, false, 0, true));
            rootRequest.CertificateExtensions.Add(new X509KeyUsageExtension(
                X509KeyUsageFlags.KeyCertSign | X509KeyUsageFlags.CrlSign, true));
            using (var root = rootRequest.CreateSelfSigned(now.AddDays(-3), now.AddDays(3)))
            using (var publicRoot = X509CertificateLoader.LoadCertificate(root.Export(X509ContentType.Cert)))
            using (var store = new X509Store(StoreName.Root, StoreLocation.CurrentUser)) {
                store.Open(OpenFlags.ReadWrite);
                var installed = false;
                try {
                    store.Add(publicRoot);
                    installed = true;
                    var request = Request(leafKey, "ledger-ci.example", "1.3.6.1.5.5.7.3.1");
                    using (var valid = request.Create(root, now.AddHours(-1), now.AddDays(1),
                                                       RandomNumberGenerator.GetBytes(16))) {
                        var der = valid.Export(X509ContentType.Cert);
                        Check(verifier, der, "ledger-ci.example", true, "trusted certificate");
                        Check(verifier, der, "wrong.example", false,
                              "hostname mismatch", "0x800B010F");
                        der[der.Length - 1] ^= 1;
                        Check(verifier, der, "ledger-ci.example", false, "invalid signature");
                    }
                    using (var expired = request.Create(root, now.AddDays(-2), now.AddDays(-1),
                                                         RandomNumberGenerator.GetBytes(16))) {
                        Check(verifier, expired.Export(X509ContentType.Cert), "ledger-ci.example",
                              false, "expired certificate", "0x800B0101");
                    }
                    var wrongUsage = Request(leafKey, "ledger-ci.example", "1.3.6.1.5.5.7.3.2");
                    using (var client = wrongUsage.Create(root, now.AddHours(-1), now.AddDays(1),
                                                           RandomNumberGenerator.GetBytes(16))) {
                        Check(verifier, client.Export(X509ContentType.Cert), "ledger-ci.example",
                              false, "wrong certificate usage");
                    }
                    using (var unknown = request.CreateSelfSigned(now.AddHours(-1), now.AddDays(1))) {
                        Check(verifier, unknown.Export(X509ContentType.Cert), "ledger-ci.example",
                              false, "untrusted self-signed certificate");
                    }
                    Check(verifier, new byte[] { 1, 2, 3 }, "ledger-ci.example",
                          false, "malformed certificate");
                } finally {
                    if (installed) store.Remove(publicRoot);
                    foreach (var remaining in store.Certificates.Find(
                        X509FindType.FindByThumbprint, publicRoot.Thumbprint, false)) {
                        remaining.Dispose();
                        throw new Exception("Temporary test CA was not removed");
                    }
                }
            }
        }
    }
}
'@
[LedgerTlsPolicyTests]::Run($verifierPath)
