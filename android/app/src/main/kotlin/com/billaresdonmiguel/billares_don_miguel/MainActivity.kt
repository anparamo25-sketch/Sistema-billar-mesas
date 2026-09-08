package com.billaresdonmiguel.billares_don_miguel

import android.app.Presentation
import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Bundle
import android.view.Display
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "billar_control/tv"
    private var presentation: TvPresentation? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "startTv" -> {
                    val manager = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
                    val display = manager.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION).firstOrNull()
                    if (display == null) {
                        result.success("disconnected")
                    } else {
                        presentation?.dismiss()
                        presentation = TvPresentation(this, display)
                        presentation?.show()
                        result.success("connected")
                    }
                }
                "updateTv" -> {
                    val tables = call.argument<List<Map<String, Any?>>>("tables") ?: emptyList()
                    presentation?.updateTables(tables)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        presentation?.dismiss()
        presentation = null
        super.onDestroy()
    }

    private class TvPresentation(context: Context, display: Display) : Presentation(context, display) {
        private lateinit var container: LinearLayout

        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            container = LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(48, 36, 48, 36)
                setBackgroundColor(0xFF101010.toInt())
            }
            setContentView(container)
            updateTables(emptyList())
        }

        fun updateTables(tables: List<Map<String, Any?>>) {
            if (!::container.isInitialized) return
            container.post {
                container.removeAllViews()
                val title = TextView(context).apply {
                    text = "BILLARES DON MIGUEL"
                    textSize = 30f
                    setTextColor(0xFFFFFFFF.toInt())
                    setPadding(0, 0, 0, 24)
                }
                container.addView(title)
                tables.sortedBy { (it["id"] as? Number)?.toInt() ?: 0 }.forEach { table ->
                    val id = (table["id"] as? Number)?.toInt() ?: 0
                    val active = table["active"] == true
                    val total = (table["total"] as? Number)?.toDouble() ?: 0.0
                    val row = TextView(context).apply {
                        text = "MESA $id   ${if (active) "OCUPADA" else "DISPONIBLE"}   C\$ ${String.format(java.util.Locale.US, "%.2f", total)}"
                        textSize = 22f
                        setTextColor(0xFFFFFFFF.toInt())
                        setPadding(0, 14, 0, 14)
                    }
                    container.addView(row)
                }
            }
        }
    }
}
