// Pluggable credentials source for digest authentication. The proxy holds a
// `CredentialsStore`; production deployments would back this with a database
// or LDAP. We ship an in-memory implementation suitable for tests and small
// PBXes.

import 'digest_auth.dart' show computeHa1;

abstract class CredentialsStore {
  /// Returns the pre-computed HA1 for [username] in [realm], or null if no
  /// such user exists. HA1 = MD5(username:realm:password).
  String? ha1For(String username, String realm);
}

class InMemoryCredentialsStore implements CredentialsStore {
  InMemoryCredentialsStore({required this.realm});

  final String realm;
  final Map<String, String> _ha1 = {};

  /// Adds (or replaces) a credential. Either [password] or [ha1] must be
  /// supplied; [password] is hashed against [realm] immediately so plaintext
  /// is not retained.
  void put(String username, {String? password, String? ha1}) {
    assert(
        password != null || ha1 != null, 'put: provide either password or ha1');
    _ha1[username] = ha1 ?? computeHa1(username, realm, password!);
  }

  void remove(String username) => _ha1.remove(username);

  @override
  String? ha1For(String username, String realmIn) =>
      realmIn == realm ? _ha1[username] : null;
}
