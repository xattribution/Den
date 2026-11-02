/// A certificate authority made for these tests only (openssl, EC P-256, valid until 2076), and
/// certificates it signed: one for `den-a.test` and `den-b.test`, one for `other.test`. The keys
/// are here on purpose; nothing outside the tests trusts this authority.
library;

import 'dart:convert';
import 'dart:io';

const String testCa = '''
-----BEGIN CERTIFICATE-----
MIIBkzCCATmgAwIBAgIUFnmivMCSKBklRlmLx56N502wWAgwCgYIKoZIzj0EAwIw
FjEUMBIGA1UEAwwLRGVuIHRlc3QgQ0EwIBcNMjYxMDI5MTIzMTU5WhgPMjA3NjEw
MTYxMjMxNTlaMBYxFDASBgNVBAMMC0RlbiB0ZXN0IENBMFkwEwYHKoZIzj0CAQYI
KoZIzj0DAQcDQgAEA+Btts/kRb8bczXiinYQhJ6SuatzdiHmzDa0VEfFuugaxXwd
/2xIet7RGR6wyCkQBiPpYPiQpjGpoDxkXys25qNjMGEwHQYDVR0OBBYEFOv4Oo8E
RMVFi0Er+D6jFCoirdAxMB8GA1UdIwQYMBaAFOv4Oo8ERMVFi0Er+D6jFCoirdAx
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMCA0gA
MEUCIQDQ3li3dIdZsHMzSueINBH2UIsaEWkIY00q4FSM7uZLTAIgJDNrQKxtwiw0
gZLb5j/iXbt7yDaRXKvU5RdHBBeQnWc=
-----END CERTIFICATE-----
''';

const String hubsCert = '''
-----BEGIN CERTIFICATE-----
MIIBxTCCAWygAwIBAgIUErbQlwWQ9HRqPCGM0SWeuLtoQKQwCgYIKoZIzj0EAwIw
FjEUMBIGA1UEAwwLRGVuIHRlc3QgQ0EwIBcNMjYxMDI5MTIzMTU5WhgPMjA3NjAy
MDkxMjMxNTlaMBUxEzARBgNVBAMMCmRlbi1hLnRlc3QwWTATBgcqhkjOPQIBBggq
hkjOPQMBBwNCAAQ9pyjhxkeXjtAAO/bYyjoV3oB9iLi50WNaUjn/bBQ242mpYK9v
hfZyhbt6T5fnVrlCfA8z/v6p94cHY5UEDLx0o4GWMIGTMAkGA1UdEwQCMAAwDgYD
VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMBMCEGA1UdEQQaMBiCCmRl
bi1hLnRlc3SCCmRlbi1iLnRlc3QwHQYDVR0OBBYEFONMwrX9trLYfvjI73kx61ks
cr2KMB8GA1UdIwQYMBaAFOv4Oo8ERMVFi0Er+D6jFCoirdAxMAoGCCqGSM49BAMC
A0cAMEQCIHcNoEwJRHrDSSEXVFwM8rVfxbhO4AXEySMsk6XYghNpAiBgbbuJTTS2
gEzGqR9L7MbCFG/pCbdTTUoa0QBgHDfp8A==
-----END CERTIFICATE-----
''';

const String hubsKey = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgcYJgYZ4jUFSYDfrB
kh9D/Yqm2biqvm8XUo02TXhRp+WhRANCAAQ9pyjhxkeXjtAAO/bYyjoV3oB9iLi5
0WNaUjn/bBQ242mpYK9vhfZyhbt6T5fnVrlCfA8z/v6p94cHY5UEDLx0
-----END PRIVATE KEY-----
''';

const String otherCert = '''
-----BEGIN CERTIFICATE-----
MIIBuzCCAWCgAwIBAgIUErbQlwWQ9HRqPCGM0SWeuLtoQKUwCgYIKoZIzj0EAwIw
FjEUMBIGA1UEAwwLRGVuIHRlc3QgQ0EwIBcNMjYxMDI5MTIzMTU5WhgPMjA3NjAy
MDkxMjMxNTlaMBUxEzARBgNVBAMMCm90aGVyLnRlc3QwWTATBgcqhkjOPQIBBggq
hkjOPQMBBwNCAATbs/bgPyqEgBTe2ltYvvGV6r3zt2HGUioADfxhCFVdZqT445cI
fi1DYuJeEomHp99vwaN8g2Llsi767rgwbSHto4GKMIGHMAkGA1UdEwQCMAAwDgYD
VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMBMBUGA1UdEQQOMAyCCm90
aGVyLnRlc3QwHQYDVR0OBBYEFNApCTkNbBwQyb4h3V2fTV0zko9cMB8GA1UdIwQY
MBaAFOv4Oo8ERMVFi0Er+D6jFCoirdAxMAoGCCqGSM49BAMCA0kAMEYCIQCoSZOL
RngO3PtmdxiaXR3marPQjHJFFtihldkxQKNCoQIhAK5qok80vdZ1eV9rS0r+MnT5
Z818/OgcHwmS39horsPx
-----END CERTIFICATE-----
''';

const String otherKey = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgvqw1vUe38JUFnPuQ
1CcD0kXX8ac4XNk6cqj4W2vnVTehRANCAATbs/bgPyqEgBTe2ltYvvGV6r3zt2HG
UioADfxhCFVdZqT445cIfi1DYuJeEomHp99vwaN8g2Llsi767rgwbSHt
-----END PRIVATE KEY-----
''';

/// Trusts [testCa] and nothing else.
SecurityContext trustingTestCa() => SecurityContext(withTrustedRoots: false)..setTrustedCertificatesBytes(utf8.encode(testCa));

/// A server's context with [cert] and [key].
SecurityContext serving(String cert, String key) => SecurityContext()
  ..useCertificateChainBytes(utf8.encode(cert))
  ..usePrivateKeyBytes(utf8.encode(key));
