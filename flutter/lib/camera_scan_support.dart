import 'package:flutter/foundation.dart';

/// Camera scanning is intentionally limited to phones and tablets.
bool get isCameraScanningSupported =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;
