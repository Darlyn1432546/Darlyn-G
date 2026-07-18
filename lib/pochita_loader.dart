import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class PochitaReproductor extends StatefulWidget {
  final double size; // Nuevo parámetro
  const PochitaReproductor({super.key, this.size = 300});

  @override
  State<PochitaReproductor> createState() => _PochitaReproductorState();
}

class _PochitaReproductorState extends State<PochitaReproductor> {
  int _currentFrame = 1;
  final int _totalFrames = 8;
  Timer? _timer;

  // 👇 Cambia este valor para ajustar la velocidad (en milisegundos)
  final int _frameDuration =
      700; // 1000 = 1 segundo, 500 = 0.5 segundos, 2000 = 2 segundos

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(Duration(milliseconds: _frameDuration), (timer) {
      setState(() {
        if (_currentFrame < _totalFrames) {
          _currentFrame++;
        } else {
          _currentFrame = 1;
        }
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SvgPicture.asset(
        'assets/animaciones/frame$_currentFrame.svg',
        width: widget.size,
        height: widget.size,
        fit: BoxFit.contain,
      ),
    );
  }
}
