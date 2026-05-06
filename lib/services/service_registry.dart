// Service registry (Kamailio-style module loader).
//
// Provides a single root object holding handles to every configured service.
// `bin/dart_pbx.dart` builds one of these at startup and hands it to the
// transports / request handler. Modules can be omitted (left null) at config
// time — analogous to not loading a Kamailio module.

import 'auth.dart';
import 'callcenter.dart';
import 'dialog.dart';
import 'dispatcher.dart';
import 'registrar.dart';
import 'rr.dart';
import 'tm.dart';
import 'usrloc.dart';

class ServiceRegistry {
  ServiceRegistry({
    UsrLocService? usrloc,
    this.auth,
    RegistrarPolicy? registrarPolicy,
    DispatcherService? dispatcher,
    RrService? rr,
    CallCenterService? callcenter,
    this.tm,
    this.dialog,
  })  : usrloc = usrloc ?? UsrLocService(),
        registrar = registrarPolicy ?? RegistrarPolicy(),
        rr = rr ?? RrService(),
        dispatcher = dispatcher ?? DispatcherService(),
        callcenter = callcenter ?? CallCenterService();

  /// Location service (mandatory, has a default empty store).
  final UsrLocService usrloc;

  /// REGISTER expiry policy (mandatory, has defaults).
  final RegistrarPolicy registrar;

  /// Record-Route helpers.
  final RrService rr;

  /// Upstream gateway dispatcher.
  final DispatcherService dispatcher;

  /// Inbound call-center (queues + agents). Empty by default; populate at
  /// startup if the deployment uses queue-based routing.
  final CallCenterService callcenter;

  /// Optional digest authentication. When null, REGISTER and INVITE pass
  /// through without challenge.
  final AuthService? auth;

  /// Transaction-manager facade. Wired in by [RequestsHandler] once the
  /// [StatefulProxy] is constructed.
  TmService? tm;

  /// Dialog service facade. Wired in by [RequestsHandler] once the
  /// [StatefulProxy] is constructed.
  DialogService? dialog;
}
