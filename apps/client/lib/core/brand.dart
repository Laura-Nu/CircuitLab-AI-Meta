import 'package:flutter/material.dart';
import 'public_navigation.dart';
import 'site_location.dart';
export 'public_navigation.dart' show openPublicUrl;
export 'site_location.dart' show landingUri;

class CircuitBrand extends StatelessWidget {
  final String language;
  final String tooltip;
  const CircuitBrand({
    super.key,
    required this.language,
    required this.tooltip,
  });
  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      link: true,
      label: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => openPublicUrl(landingUri(language)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 32,
                  height: 32,
                  child: CustomPaint(painter: CircuitMark()),
                ),
                const SizedBox(width: 10),
                const Text(
                  'CircuitLab',
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.8,
                  ),
                ),
                const SizedBox(width: 5),
                const Text(
                  'AI',
                  style: TextStyle(
                    color: Color(0xFF6CE5BC),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Same chip and center square used by the landing and launcher assets.
class CircuitMark extends CustomPainter {
  const CircuitMark();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 32, size.height / 32);
    final paint = Paint()
      ..color = const Color(0xFF6CE5BC)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(9, 9, 14, 14),
        const Radius.circular(2),
      ),
      paint,
    );
    canvas.drawRect(const Rect.fromLTWH(14, 14, 4, 4), paint);
    for (final point in [12.0, 20.0]) {
      canvas.drawLine(Offset(point, 4), Offset(point, 9), paint);
      canvas.drawLine(Offset(point, 23), Offset(point, 28), paint);
      canvas.drawLine(Offset(4, point), Offset(9, point), paint);
      canvas.drawLine(Offset(23, point), Offset(28, point), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CircuitMark oldDelegate) => false;
}
