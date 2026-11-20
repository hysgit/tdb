package com.hysgit.tdb

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.view.WindowManager

class MainActivity : FlutterActivity() {
    private var previousKeepScreenOn: Boolean? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tingdubao/transfer")
            .setMethodCallHandler { call, result ->
                if (call.method != "setActive" || call.arguments !is Boolean) {
                    result.notImplemented()
                } else {
                    val flag = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                    if (call.arguments == true) {
                        if (previousKeepScreenOn == null) {
                            previousKeepScreenOn = window.attributes.flags and flag != 0
                        }
                        window.addFlags(flag)
                    } else {
                        if (previousKeepScreenOn == false) window.clearFlags(flag)
                        previousKeepScreenOn = null
                    }
                    result.success(null)
                }
            }
    }
}
