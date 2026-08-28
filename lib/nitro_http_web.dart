/// The web plugin registrant.
///
/// Flutter requires a `pluginClass` for any declared `web` platform and emits a
/// call to it in the generated registrant, so this has to exist — but there is
/// nothing to register. Web is served by `executor_fetch.dart`, chosen by a
/// conditional import in `executor_default.dart`, which needs no platform
/// channel and no registration.
///
/// Declaring the platform is still worth the eight lines: without it the
/// package reads as native-only on pub.dev and `flutter build web` refuses a
/// plugin it thinks has no web support.
library;

import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// Registrant for the `web` platform. Intentionally does nothing.
class NitroHttpWeb {
  /// Called by Flutter's generated web plugin registrant.
  static void registerWith(Registrar registrar) {}
}
