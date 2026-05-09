// Home Subscriber Server (HSS) — 3GPP TS 23.228 §4.6 / TS 29.228 (Cx).
//
// Stores the IMS subscription database used by the I-CSCF and S-CSCF. In a
// real network the CSCFs talk to the HSS over Diameter (Cx interface,
// commands UAR/UAA, MAR/MAA, SAR/SAA, LIR/LIA, PPR/PPA). Here the HSS is
// in-process and the CSCFs invoke its methods directly — this is exactly
// the "all-in-one" topology used by the OpenIMSCore / Kamailio IMS
// reference deployments for development.
//
// Identity model:
//
//   IMPI  — IP Multimedia Private Identity. NAI form (`user@domain`).
//           Used for authentication. One per subscription.
//   IMPU  — IP Multimedia Public Identity. SIP/Tel URI used as AOR.
//           Multiple IMPUs may be associated with one IMPI; an IMPU may
//           also be shared between IMPIs (for shared lines), though we
//           currently model only the simple 1-IMPI : N-IMPU case.
//
// Each IMPU carries a Service Profile (currently just an iFC list and a
// flag controlling whether the user is barred). The HSS also tracks which
// S-CSCF (by name) is currently serving each IMPI; the I-CSCF uses this
// to forward subsequent registrations and incoming calls.

import 'dart:math';
import 'dart:typed_data';

import 'package:dart_pbx/proxy/auth_store.dart';

import 'aka.dart';
import 'milenage.dart';

/// Initial Filter Criterion (3GPP TS 29.228 §6.3.5). Heavily simplified:
/// we evaluate only the SIP method and (optionally) a regex against the
/// Request-URI. A real HSS stores a full XML <ServicePointTrigger> tree.
class InitialFilterCriteria {
  InitialFilterCriteria({
    required this.priority,
    required this.applicationServer,
    this.method,
    this.requestUriRegex,
    this.sessionCase = SessionCase.originating,
    this.defaultHandling = DefaultHandling.continueSession,
  });

  /// Lower numeric value = higher priority (evaluated first).
  final int priority;

  /// SIP URI of the Application Server to forward to when this iFC matches.
  /// Per TS 24.229 §5.4.3.2 the S-CSCF Route's it through with `;lr` and
  /// the `orig` parameter when applying originating services.
  final String applicationServer;

  /// SIP method this iFC applies to (case-insensitive). Null = any method.
  final String? method;

  /// Optional regex applied to the Request-URI string. Null = match all.
  final RegExp? requestUriRegex;

  /// Originating-side or terminating-side service?
  final SessionCase sessionCase;

  /// What the S-CSCF should do when the AS is unreachable.
  final DefaultHandling defaultHandling;
}

enum SessionCase {
  /// Apply when this user is the calling party (originating-registered).
  originating,

  /// Apply when this user is the called party (terminating-registered).
  terminating,
}

enum DefaultHandling {
  /// On AS error, continue the session (skip the AS). TS 29.228 default.
  continueSession,

  /// On AS error, terminate with 503.
  sessionTerminated,
}

/// Service Profile for one IMPU (TS 29.228 §6.3.4).
class ServiceProfile {
  ServiceProfile({
    this.barred = false,
    List<InitialFilterCriteria>? ifcs,
  }) : ifcs = (ifcs ?? const <InitialFilterCriteria>[]).toList(growable: true)
          ..sort((a, b) => a.priority.compareTo(b.priority));

  /// "Barred public user identity" (TS 23.003 §13.4.4). Barred IMPUs are
  /// stored in the HSS but cannot be used as the From of an originating
  /// call or as the To of a terminating call.
  final bool barred;

  /// Initial Filter Criteria, sorted by priority (lowest first).
  final List<InitialFilterCriteria> ifcs;
}

/// One subscription record (one IMPI + the IMPUs that share it).
class ImsSubscription {
  ImsSubscription({
    required this.impi,
    required this.impus,
    required this.profiles,
  });

  /// e.g. `alice@home.example.org`
  final String impi;

  /// All IMPUs (SIP and Tel URIs) associated with this IMPI. The first one
  /// is the *default* / *implicitly registered set* used in Service-Route
  /// when REGISTER does not specify an explicit Public ID.
  final List<String> impus;

  /// Service Profile per IMPU.
  final Map<String, ServiceProfile> profiles;

  /// Currently assigned S-CSCF name (Cx UAR/SAR). null = unregistered.
  String? assignedScscfName;
}

/// Result of a Cx-UAR (User Authorization Request) — TS 29.228 §6.1.1.
class UserAuthorizationAnswer {
  UserAuthorizationAnswer.assigned(this.scscfName)
      : capabilities = null,
        result = UarResult.subsequentRegistration;
  UserAuthorizationAnswer.firstRegistration(this.capabilities)
      : scscfName = null,
        result = UarResult.firstRegistration;
  UserAuthorizationAnswer.notFound()
      : scscfName = null,
        capabilities = null,
        result = UarResult.userUnknown;

  final UarResult result;

  /// On subsequent registration: the S-CSCF currently serving this IMPI.
  final String? scscfName;

  /// On first registration: the I-CSCF picks any S-CSCF matching these
  /// capability requirements. Our minimal HSS just exposes the list of
  /// known S-CSCF names; the I-CSCF picks the first.
  final List<String>? capabilities;
}

enum UarResult {
  firstRegistration,
  subsequentRegistration,
  userUnknown,
}

/// Result of a Cx-LIR (Location Information Request) — TS 29.228 §6.1.4.
/// Used by the I-CSCF on terminating routing to find which S-CSCF serves
/// a given IMPU.
class LocationInfoAnswer {
  LocationInfoAnswer.served(this.scscfName)
      : result = LirResult.served,
        unregisteredService = false;
  LocationInfoAnswer.unregisteredServices(this.scscfName)
      : result = LirResult.served,
        unregisteredService = true;
  LocationInfoAnswer.notRegistered()
      : scscfName = null,
        result = LirResult.notRegistered,
        unregisteredService = false;
  LocationInfoAnswer.notFound()
      : scscfName = null,
        result = LirResult.userUnknown,
        unregisteredService = false;

  final LirResult result;
  final String? scscfName;
  final bool unregisteredService;
}

enum LirResult { served, notRegistered, userUnknown }

class HomeSubscriberServer {
  HomeSubscriberServer({required this.realm, List<String>? scscfPool})
      : _credentials = InMemoryCredentialsStore(realm: realm),
        _scscfPool = (scscfPool ?? const ['scscf.local']).toList();

  /// Authentication realm advertised on Digest challenges.
  final String realm;

  /// Local in-memory credentials backing the digest authenticator. Exposed
  /// so the S-CSCF can verify Authorization headers against it.
  final InMemoryCredentialsStore _credentials;
  CredentialsStore get credentials => _credentials;

  /// All S-CSCFs the I-CSCF may pick from on first registration. In a
  /// single-instance deployment this list has one entry.
  final List<String> _scscfPool;

  /// Read-only view of the S-CSCF pool, used by the I-CSCF to forward
  /// emergency requests directly without consulting Cx.
  List<String> get scscfPool => List.unmodifiable(_scscfPool);

  final Map<String, ImsSubscription> _byImpi = {};
  final Map<String, ImsSubscription> _byImpu = {};

  /// AKA-provisioned subscribers: IMPI → ISIM key material + per-IMPI SQN.
  /// IMPIs in this map use AKAv1-MD5 (RFC 3310). IMPIs that only appear in
  /// [_credentials] use plain MD5 digest.
  final Map<String, _AkaCredential> _aka = {};

  // ---------------------------------------------------------------------------
  // Provisioning
  // ---------------------------------------------------------------------------

  /// Provisions a new subscription. The first IMPU is the default identity.
  ImsSubscription provision({
    required String impi,
    required List<String> impus,
    required String password,
    Map<String, ServiceProfile>? profiles,
  }) {
    assert(impus.isNotEmpty, 'at least one IMPU is required');
    final sub = ImsSubscription(
      impi: impi,
      impus: List.unmodifiable(impus),
      profiles: {
        for (final impu in impus) impu: profiles?[impu] ?? ServiceProfile(),
      },
    );
    _byImpi[impi] = sub;
    for (final impu in impus) {
      _byImpu[impu] = sub;
    }
    // Username for digest is the IMPI per TS 33.203 §6.1.1.
    _credentials.put(impi, password: password);
    return sub;
  }

  /// Provisions a subscription that authenticates with IMS-AKA (the only
  /// scheme allowed for true 3GPP IMS access — TS 33.203 §6.1). Either
  /// [opc] or [op] must be supplied. [sqn] is the initial 48-bit sequence
  /// number; defaults to all-zero (TS 33.102 §6.3.7 lets the SIM accept any
  /// initial value provided the management range is wide enough).
  ImsSubscription provisionAka({
    required String impi,
    required List<String> impus,
    required Uint8List k,
    Uint8List? opc,
    Uint8List? op,
    Uint8List? sqn,
    Map<String, ServiceProfile>? profiles,
  }) {
    assert(impus.isNotEmpty, 'at least one IMPU is required');
    assert(k.length == 16, 'K must be 128 bits');
    assert(opc != null || op != null, 'provide either opc or op');
    final effOpc = opc ?? Milenage.deriveOpc(k, op!);
    assert(effOpc.length == 16, 'OPc must be 128 bits');
    final sub = ImsSubscription(
      impi: impi,
      impus: List.unmodifiable(impus),
      profiles: {
        for (final impu in impus) impu: profiles?[impu] ?? ServiceProfile(),
      },
    );
    _byImpi[impi] = sub;
    for (final impu in impus) {
      _byImpu[impu] = sub;
    }
    _aka[impi] = _AkaCredential(
      k: Uint8List.fromList(k),
      opc: Uint8List.fromList(effOpc),
      sqn: sqn != null ? Uint8List.fromList(sqn) : Uint8List(6),
    );
    return sub;
  }

  /// True if [impi] authenticates with IMS-AKA rather than plain digest.
  bool isAka(String impi) => _aka.containsKey(impi);

  /// Cx MAR (Multimedia-Auth-Request) — TS 29.228 §6.1.2.
  ///
  /// Returns [n] freshly generated authentication vectors for [impi]. The
  /// HSS advances SQN by one for each AV (TS 33.102 §6.3.2 / Annex C
  /// allows any monotonically increasing SQN management scheme).
  ///
  /// Returns null if the IMPI is unknown or not AKA-provisioned.
  List<AuthVector>? multimediaAuth({
    required String impi,
    int n = 1,
    Uint8List? amf,
  }) {
    final cred = _aka[impi];
    if (cred == null) return null;
    final out = <AuthVector>[];
    for (var i = 0; i < n; i++) {
      _incrementSqn(cred.sqn);
      final rand = _randomRand();
      out.add(AuthVector.generate(
        k: cred.k,
        opc: cred.opc,
        rand: rand,
        sqn: cred.sqn,
        amf: amf,
      ));
    }
    return out;
  }

  /// Recovers SQN_MS from an AUTS the UE sent in a re-synchronisation
  /// challenge and overwrites the HSS-side SQN with `SQN_MS + 1` (TS
  /// 33.102 §6.3.5). The caller (S-CSCF) should then call
  /// [multimediaAuth] again with `n=1` to get a fresh AV.
  ///
  /// Returns true on success, false on MAC-S mismatch or unknown IMPI.
  bool resync({
    required String impi,
    required Uint8List rand,
    required Uint8List auts,
  }) {
    final cred = _aka[impi];
    if (cred == null || auts.length != 14) return false;

    // AUTS = (SQN_MS XOR AK*) || MAC-S      where AK* = f5*(K, RAND).
    // We need AK* to recover SQN_MS, then verify MAC-S = f1*(K, SQN_MS,
    // RAND, AMF*) with AMF* = 0x0000 (TS 33.102 §6.3.3).
    final amfStar = Uint8List(2);
    // First, run Milenage to get AK* (which depends only on K, OPc, RAND).
    // We don't yet know SQN_MS so any SQN works for that f5* output.
    final tmp = Milenage(cred.opc).run(
      k: cred.k,
      rand: rand,
      sqn: Uint8List(6),
      amf: amfStar,
    );
    final sqnMs = Uint8List(6);
    for (var i = 0; i < 6; i++) {
      sqnMs[i] = auts[i] ^ tmp.akStar[i];
    }
    // Re-run Milenage with the recovered SQN_MS to compute the expected
    // MAC-S and verify it equals AUTS[6..14].
    final check =
        Milenage(cred.opc).run(k: cred.k, rand: rand, sqn: sqnMs, amf: amfStar);
    for (var i = 0; i < 8; i++) {
      if (check.macS[i] != auts[6 + i]) return false;
    }
    // Accept and advance.
    cred.sqn.setRange(0, 6, sqnMs);
    _incrementSqn(cred.sqn);
    return true;
  }

  static void _incrementSqn(Uint8List sqn) {
    for (var i = 5; i >= 0; i--) {
      sqn[i] = (sqn[i] + 1) & 0xff;
      if (sqn[i] != 0) return;
    }
  }

  Uint8List _randomRand() {
    final r = _rand;
    final b = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      b[i] = r.nextInt(256);
    }
    return b;
  }

  // Lazily allocated; tests can be deterministic by seeding via
  // [debugSetRandom].
  late final _rand = _DefaultRandom();

  // ---------------------------------------------------------------------------
  // Cx — invoked by the I-CSCF / S-CSCF
  // ---------------------------------------------------------------------------

  /// Cx UAR (User-Authorization-Request). Called by the I-CSCF on REGISTER
  /// to find the S-CSCF (or a capability set for picking one).
  UserAuthorizationAnswer userAuthorization({
    required String impi,
    required String impu,
    bool registration = true,
  }) {
    final sub = _byImpi[impi];
    if (sub == null || !sub.impus.contains(impu)) {
      return UserAuthorizationAnswer.notFound();
    }
    final assigned = sub.assignedScscfName;
    if (assigned != null) {
      return UserAuthorizationAnswer.assigned(assigned);
    }
    return UserAuthorizationAnswer.firstRegistration(_scscfPool);
  }

  /// Cx SAR (Server-Assignment-Request). The S-CSCF informs the HSS that
  /// it has accepted the assignment. Returns the user's full Service
  /// Profile (per IMPU). TS 29.228 §6.1.3.
  Map<String, ServiceProfile>? serverAssignment({
    required String impi,
    required String scscfName,
    bool deregister = false,
  }) {
    final sub = _byImpi[impi];
    if (sub == null) return null;
    if (deregister) {
      sub.assignedScscfName = null;
    } else {
      sub.assignedScscfName = scscfName;
    }
    return sub.profiles;
  }

  /// Cx LIR (Location-Information-Request). TS 29.228 §6.1.4.
  LocationInfoAnswer locationInformation({required String impu}) {
    final sub = _byImpu[impu];
    if (sub == null) return LocationInfoAnswer.notFound();
    final scscf = sub.assignedScscfName;
    if (scscf == null) return LocationInfoAnswer.notRegistered();
    return LocationInfoAnswer.served(scscf);
  }

  // ---------------------------------------------------------------------------
  // Convenience
  // ---------------------------------------------------------------------------

  /// Returns the IMPI for an IMPU (1:1 with our simplified model).
  String? impiFor(String impu) => _byImpu[impu]?.impi;

  /// Returns the subscription record for an IMPU.
  ImsSubscription? subscriptionByImpu(String impu) => _byImpu[impu];

  /// Returns the subscription record for an IMPI.
  ImsSubscription? subscriptionByImpi(String impi) => _byImpi[impi];

  /// All IMPUs currently registered (have an assigned S-CSCF).
  Iterable<String> get registeredImpus =>
      _byImpu.entries.where((e) => e.value.assignedScscfName != null).map(
            (e) => e.key,
          );
}

class _AkaCredential {
  _AkaCredential({required this.k, required this.opc, required this.sqn});
  final Uint8List k; // 16 bytes
  final Uint8List opc; // 16 bytes
  final Uint8List sqn; // 6 bytes; mutated in place
}

class _DefaultRandom {
  final _r = Random.secure();
  int nextInt(int max) => _r.nextInt(max);
}
