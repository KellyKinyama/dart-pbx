// Dialog service (Kamailio-style `dialog`).
//
// Facade over the proxy's dialog layer. Exposed for application code that
// wants to enumerate active dialogs or react to creation/termination events.

import 'package:dart_pbx/proxy/dialog.dart';

export 'package:dart_pbx/proxy/dialog.dart'
    show Dialog, DialogId, DialogState, DialogLayer;

class DialogService {
  DialogService(this.layer);

  final DialogLayer layer;

  int get activeCount =>
      layer.dialogs.where((d) => d.state != DialogState.terminated).length;

  Iterable<Dialog> get all => layer.dialogs;
}
