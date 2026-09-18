package com.presencia.app_profesor

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var altBeaconPlugin: AltBeaconPlugin? = null
    private var studentAttendanceBlePlugin: StudentAttendanceBlePlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        altBeaconPlugin = AltBeaconPlugin(this).also {
            it.register(flutterEngine.dartExecutor.binaryMessenger)
        }
        studentAttendanceBlePlugin = StudentAttendanceBlePlugin(this).also {
            it.register(flutterEngine.dartExecutor.binaryMessenger)
        }
    }

    override fun onResume() {
        super.onResume()
        altBeaconPlugin?.onActivityResumed()
        studentAttendanceBlePlugin?.onActivityResumed()
    }

    override fun onPause() {
        altBeaconPlugin?.onActivityPaused()
        studentAttendanceBlePlugin?.onActivityPaused()
        super.onPause()
    }
}
