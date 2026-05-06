// Public service barrel — Kamailio-style "module" surface.
//
// Importing this file exposes every service the SIP router knows about so
// application code only ever depends on `package:dart_pbx/services/...`,
// never on the lower-level engine in `lib/proxy/`.

export 'auth.dart';
export 'callcenter.dart';
export 'dialog.dart';
export 'dispatcher.dart';
export 'registrar.dart';
export 'rr.dart';
export 'service_registry.dart';
export 'tm.dart';
export 'usrloc.dart';
