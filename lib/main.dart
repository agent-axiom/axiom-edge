import 'package:flutter/material.dart';
import 'core/lab_state.dart';
import 'ui/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(AxiomEdgeApp(state: LabState()..init()));
}
