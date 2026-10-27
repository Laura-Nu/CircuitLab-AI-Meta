import 'dart:async';
import 'package:flutter/material.dart';
import 'networking/api.dart';

/// Only human input marks activity. Background polling never renews the idle window.
class SessionActivity extends StatefulWidget {
  final CircuitApi api;
  final Widget child;
  const SessionActivity({super.key, required this.api, required this.child});
  @override
  State<SessionActivity> createState() => _SessionActivityState();
}

class _SessionActivityState extends State<SessionActivity>
    with WidgetsBindingObserver {
  Timer? timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => widget.api.tickSession(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.api.expireIfIdle();
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => widget.api.recordActivity(),
    onPointerMove: (_) => widget.api.recordActivity(),
    onPointerSignal: (_) => widget.api.recordActivity(),
    child: Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        widget.api.recordActivity();
        return KeyEventResult.ignored;
      },
      child: widget.child,
    ),
  );
}
