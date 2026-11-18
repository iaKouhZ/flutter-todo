#define CERT_CHAIN_ENGINE_CONFIG_HAS_EXTRA_FIELDS
#define CERT_CHAIN_PARA_HAS_EXTRA_FIELDS
#include <windows.h>
#include <wincrypt.h>
#include <shellapi.h>

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace {
#ifdef LEDGER_TLS_POLICY_TEST
struct TestChainEngine {
  HCERTSTORE roots = nullptr;
  HCERTCHAINENGINE engine = nullptr;
  ~TestChainEngine() {
    if (engine) CertFreeCertificateChainEngine(engine);
    if (roots) CertCloseStore(roots, 0);
  }
};
#endif

int Fail(DWORD error) {
  char text[96]{};
  const int size = sprintf_s(text, "Windows SSL chain policy failed: 0x%08lX", error);
  DWORD written = 0;
  if (size > 0) WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text,
                          static_cast<DWORD>(size), &written, nullptr);
  return 1;
}
}  // namespace

// A separate, non-console process keeps Windows AIA/root/OCSP network retrieval
// off Flutter's UI thread. Public DER certificate bytes arrive over stdin.
int APIENTRY wWinMain(HINSTANCE, HINSTANCE, wchar_t*, int) {
  int count = 0;
  auto arguments = CommandLineToArgvW(GetCommandLineW(), &count);
  #ifdef LEDGER_TLS_POLICY_TEST
  const int expected_arguments = 3;
#else
  const int expected_arguments = 2;
#endif
  if (!arguments || count != expected_arguments || arguments[1][0] == L'\0') {
    if (arguments) LocalFree(arguments);
    return Fail(ERROR_INVALID_PARAMETER);
  }
  std::wstring hostname(arguments[1]);
#ifdef LEDGER_TLS_POLICY_TEST
  const std::wstring test_root(arguments[2]);
#endif
  LocalFree(arguments);

  HCERTCHAINENGINE engine = nullptr;
#ifdef LEDGER_TLS_POLICY_TEST
  // Only the excluded CI test binary accepts a temporary root, in memory.
  // The production helper has no custom-root mode or certificate-store writes.
  TestChainEngine test;
  DWORD size = 0;
  if (!CryptStringToBinaryW(test_root.c_str(), 0, CRYPT_STRING_BASE64,
                            nullptr, &size, nullptr, nullptr)) return Fail(GetLastError());
  std::vector<BYTE> root_bytes(size);
  if (!CryptStringToBinaryW(test_root.c_str(), 0, CRYPT_STRING_BASE64,
                            root_bytes.data(), &size, nullptr, nullptr)) return Fail(GetLastError());
  test.roots = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, CERT_STORE_CREATE_NEW_FLAG, nullptr);
  if (!test.roots) return Fail(GetLastError());
  if (!CertAddEncodedCertificateToStore(test.roots, X509_ASN_ENCODING,
      root_bytes.data(), size, CERT_STORE_ADD_ALWAYS, nullptr)) return Fail(GetLastError());
  CERT_CHAIN_ENGINE_CONFIG config{};
  config.cbSize = sizeof(config);
  config.hExclusiveRoot = test.roots;
  config.dwFlags = CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL |
      CERT_CHAIN_DISABLE_AIA | CERT_CHAIN_DISABLE_AUTH_ROOT_AUTO_UPDATE;
  config.dwUrlRetrievalTimeout = 2000;
  if (!CertCreateCertificateChainEngine(&config, &test.engine)) return Fail(GetLastError());
  engine = test.engine;
#endif

  std::vector<BYTE> der;
  BYTE buffer[4096];
  DWORD received = 0;
  const HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
  while (ReadFile(input, buffer, sizeof(buffer), &received, nullptr) && received) {
    if (der.size() + received > 1024 * 1024) return Fail(ERROR_INVALID_DATA);
    der.insert(der.end(), buffer, buffer + received);
  }
  if (der.empty()) return Fail(ERROR_INVALID_DATA);
  auto certificate = CertCreateCertificateContext(X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
      der.data(), static_cast<DWORD>(der.size()));
  if (!certificate) return Fail(GetLastError());

  LPSTR usage[] = {const_cast<LPSTR>(szOID_PKIX_KP_SERVER_AUTH)};
  CERT_CHAIN_PARA chain_parameters{};
  chain_parameters.cbSize = sizeof(chain_parameters);
  chain_parameters.RequestedUsage.dwType = USAGE_MATCH_TYPE_AND;
  chain_parameters.RequestedUsage.Usage.cUsageIdentifier = 1;
  chain_parameters.RequestedUsage.Usage.rgpszUsageIdentifier = usage;
  chain_parameters.dwUrlRetrievalTimeout = 8000;
  PCCERT_CHAIN_CONTEXT chain = nullptr;
  // Use the user's Windows trust policy and permit normal issuer/root retrieval.
  DWORD flags = CERT_CHAIN_CACHE_END_CERT |
      CERT_CHAIN_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT |
      CERT_CHAIN_REVOCATION_ACCUMULATIVE_TIMEOUT;
#ifdef LEDGER_TLS_POLICY_TEST
  flags |= CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL |
      CERT_CHAIN_DISABLE_AIA | CERT_CHAIN_DISABLE_AUTH_ROOT_AUTO_UPDATE;
#endif
  const BOOL built = CertGetCertificateChain(engine, certificate, nullptr,
      certificate->hCertStore, &chain_parameters, flags, nullptr, &chain);
  const DWORD build_error = built ? ERROR_SUCCESS : GetLastError();
  CertFreeCertificateContext(certificate);
  if (!built) return Fail(build_error);

  SSL_EXTRA_CERT_CHAIN_POLICY_PARA ssl{};
  ssl.cbSize = sizeof(ssl);
  ssl.dwAuthType = AUTHTYPE_SERVER;
  ssl.fdwChecks = 0;  // Never ignore hostname, expiration, usage or trust errors.
  ssl.pwszServerName = hostname.data();
  CERT_CHAIN_POLICY_PARA policy{};
  policy.cbSize = sizeof(policy);
  // Microsoft's TLS guidance: attempt revocation retrieval, tolerate offline
  // status only. A known revoked certificate is still rejected.
  policy.dwFlags = CERT_CHAIN_POLICY_IGNORE_ALL_REV_UNKNOWN_FLAGS;
  policy.pvExtraPolicyPara = &ssl;
  CERT_CHAIN_POLICY_STATUS status{};
  status.cbSize = sizeof(status);
  const BOOL checked = CertVerifyCertificateChainPolicy(
      CERT_CHAIN_POLICY_SSL, chain, &policy, &status);
  const DWORD error = checked ? status.dwError : GetLastError();
  CertFreeCertificateChain(chain);
  if (!checked) return Fail(error);
  return error == ERROR_SUCCESS ? 0 : Fail(error);
}
