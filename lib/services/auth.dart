// Authentication service (Kamailio-style `auth` + `auth_db`).
//
// Wraps the underlying digest authenticator and credentials store with a
// simple verb-style API used by the registrar / proxy.

import 'package:dart_pbx/proxy/auth_store.dart';
import 'package:dart_pbx/proxy/digest_auth.dart';

export 'package:dart_pbx/proxy/auth_store.dart'
    show CredentialsStore, InMemoryCredentialsStore;
export 'package:dart_pbx/proxy/digest_auth.dart' show DigestAuth, AuthResult;

class AuthService {
  AuthService({required this.digest, required this.credentials});

  final DigestAuth digest;
  final CredentialsStore credentials;

  AuthResult verifyRegister({
    required String? authorizationHeader,
  }) =>
      digest.verify(
        headerValue: authorizationHeader,
        method: 'REGISTER',
        credentials: credentials,
      );

  AuthResult verifyProxy({
    required String method,
    required String? proxyAuthorizationHeader,
  }) =>
      digest.verify(
        headerValue: proxyAuthorizationHeader,
        method: method,
        credentials: credentials,
      );

  String challengeWww({bool stale = false}) =>
      digest.challengeHeaderValue(stale: stale);

  String challengeProxy({bool stale = false}) =>
      digest.proxyChallengeHeaderValue(stale: stale);
}
