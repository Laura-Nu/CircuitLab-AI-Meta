import 'package:url_launcher/url_launcher.dart';

Future<bool> openPublicUrl(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);
