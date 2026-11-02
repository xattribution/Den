/// RSA and P-256 keys made for these tests only (openssl, 2026-10-30), for the fake Google and
/// Apple the sign-in tests talk to. The private halves are here on purpose; nothing outside the
/// tests trusts them.
library;

import 'fake_idp.dart' show RsaTestKey;

/// The provider's signing key.
const RsaTestKey keyA = RsaTestKey(
  n: 'wSxTdcPqMV4tiSDU44kLRftaNVAABD8nXAaohZzTfPM2EdKCM05_FCYea9lwCggDRMevzKczCnfWWE8apjN0HepPsBjE2Tkfn6DIbiDFPM9tim3JZtH5u1VFnfHDY9T0mtUClDz3lfL8RbiFXWCuSLurhVIxODk3JWUo6f_PhPdiXhU6hJcd3-iw-cBmJ99qcVx2g-sTZxMpt4TpzLMC9iMcaOfVikfwtaCS74VTvK91neg0L53kR6PNKPvym7ItciqsScbMNEryhf-v9AMrO4gJ64-JX4B-C8mB14ALAf_0wd8ordQ8J2aF1PaU0V6czihnIdyFg6NxrwaH1pJx0Q',
  e: 'AQAB',
  d: 'DW8le8BtAlNsI8gAfjV67vpAxwniAmmY9WWyJR6nt54bcchbzTElldNj1LjJuazee1NO1tL-8fitE7Wmow3bgrQXqCXE1N2L5ThTkBMf3G-JjPG_KrMqJLzUq1wTrFb0TutG82O9DTTZlgiz369YV48TqeEyMpiKDQP4wTNM7ZB-2t5k4ld3R1bwJl6pUChcZ76kMIu_8IZRV3O4h4zkNTsKeHm31QZ_e73t_v7MgaKszdHQFPjhC38cmo0k9da2NxT-fLID2rIj9-0zrC4gFrZfHhhIKKllIdRFwMBp6ehYFEaMIuMuLMrAw64Jzt9l99mMB74qxlWPIy9jYvwNxQ',
);

/// The key the provider rotates to.
const RsaTestKey keyB = RsaTestKey(
  n: 'plbK2dn8Dg2LUn2hozlf8S-iHQRNjavIooz27Qio0UR9UsLNIMS1hynDjq8Kb7rlMZNzBUP9c_v-l4hnrFwiIH3HZV5hp9nU58l-jYaCdPm8ieHnCjzNm71V3v97iCH18IkXH08hd5xKGJxqO6_4Put1zbCqq4d7xbyBhYf4WpQdeeOBK2QkMZIZl86QENtskcYqEsPiDWnq72hhnITYHI8gA3B9rF51A8q0Rg6RnwZn4UXbcQxDjydpF8n8Y6uAGq0nr8icZJC275m39bLhARdc7rIyViCFOTZ63xmOjP1xugypGfeTb-lM1klIHBepKwaeIyIfLGrWWvvNi3GB6Q',
  e: 'AQAB',
  d: 'F4N23udX4GOtQW61efWbGKTPYZMxZFi3frT3FehOtvBb1-ZmKV7tO0td085uJv-wNPsfPAwRqMLjSSf04dJPV7D4Dh4Sp2_dTxu2akqsp90CuCoJJzMTrJON7z1FyOdmFQfIDzq4JCihd8uqn7_fE4Pk7fvukFtRVZExbP8czi7dr9Byy-dPRCPBEnPnFIrDCLKNd0Eri4HlaDW_GsvHzsClBWYvsNM5gqXrfgNco_gnRUvY4gCh4muwca_JgUSFF8J0nHfocgobwGFnJKxux6MhzymwAOJFN3RsK2LWrglZV-ZzgsnVxPQMmBuvRQKqtVUSo99szyG-2QKRtmRN5Q',
);

/// An attacker's key: never in the provider's set.
const RsaTestKey keyX = RsaTestKey(
  n: 'nY9TubPMqwdbIZbNEzBjQtuC5pW3awPTPfhybhvImo900zBdifzWVKh_gFlydh8ZK4kLJElXnJWp3UyGvO2MQdWLAyDHenux4h2z1G5cxJjUDJv45w4HcdJ5duzP0rsiv9ZE-bTL8GjLMSipw7uBansnv5NvD3nl3goN2IaMDA9LiZ8yv2jl2OoLfqWcTfl7dv6dKqThZZEtNofqYiSDEAcpNtqfyqTNhhyYg2c9V3xfegkMPMlqlY4H1eIAeOIkBLLB2pFupv0rNOdyTt11QO4jv8P2UGYJJslU2l5mLjVoFF4TMb3L-aqzz9tCxPXX1OfuZ6taw6e-kmI9TZnaqQ',
  e: 'AQAB',
  d: 'C1w_jS7e8vX00YHYsimAVAcVHnXCY9TtcOpuVcIVv2SDPTb03PN-ALH61NDzj9DDioAMbZwG1SN1Zp9ol6FecOC_b9pNMmejdnTtzRioAlotRTt5wYR2xPOIDoBvUPfClFJpZsJtHJ3HCM8Fw-HL0wGjkWHwAA2p-qMpnGhscJy3agfWxYj_qb5ekjmwkCN7c8KPpm2FAdbhyPnHMcVh0R7NcK3HMCbBFUm2RORwJ7PFnZWYBwSd5YhzMbjkAyFWVlwDYInsw5qCzuuKhoFIng7t9i9zSfgJpnLExWQpsXqqIVOd5IniiNseZoV5_RrEMB_qbUAEyTYJ_k9vPYW0gQ',
);

/// The `.p8` Apple gave the fake Apple's owner (PKCS #8, P-256).
const String appleP8 = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgyTIrIeeLiDymddeM
m1m5iBmDJifOaqESovIQX9+iHS+hRANCAASEk+bfiidWD0sJmV2ZnWTkMB+Ee77b
gtrOuDh+tSdPjPmWW47dv3PCe1yQCX4U7Uuca3j6pazvgwGfyhK2AZoE
-----END PRIVATE KEY-----
''';

/// Another P-256 key: a `.p8` that isn't the one Apple knows.
const String otherP8 = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgF8K314tZWUMe8NcH
u4sm7+/ERh1rSOgbztacBRp7nIShRANCAAQpxzr713xBbVFhSGP1XLCMZDdL6kv9
8H6OQG2MuuYBr1p5hVx61YM2AMPOuWnjxh6KCorD36iS51fkZYpXenR2
-----END PRIVATE KEY-----
''';
