package com.example.kiosk

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var faces: FaceEngine? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        faces = FaceEngine(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        FileShare(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onDestroy() {
        faces?.close()
        super.onDestroy()
    }
}
