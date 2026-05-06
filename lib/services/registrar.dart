// Registrar service (Kamailio-style `registrar`).
//
// The actual REGISTER policy/maintainer lives in lib/proxy/registrar.dart;
// this is the public service-API re-export so callers depend on
// `lib/services/` instead of reaching into the engine.

export 'package:dart_pbx/proxy/registrar.dart'
    show RegistrarPolicy, RegistrarMaintainer;
