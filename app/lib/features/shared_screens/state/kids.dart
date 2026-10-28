import 'package:den_core/den_core.dart';

/// Kids who get the picture-first kids' app instead of the adult shell.
bool isLittleKid(Member? m) => m != null && m.isKid && (m.tier == Tier.preReader || m.tier == Tier.little);
