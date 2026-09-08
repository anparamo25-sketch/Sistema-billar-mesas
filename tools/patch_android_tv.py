from pathlib import Path

root = Path('/tmp/billar_app/android/app/src/main/kotlin/com/example/billar_control_pro')
root.mkdir(parents=True, exist_ok=True)
for old in Path('/tmp/billar_app/android/app/src/main/kotlin').rglob('MainActivity.kt'):
    old.unlink()

java = r'''package com.example.billar_control_pro;

import android.app.Presentation;
import android.content.Context;
import android.hardware.display.DisplayManager;
import android.os.Bundle;
import android.view.Display;
import android.view.View;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.graphics.RectF;
import android.widget.Toast;

import androidx.annotation.NonNull;

import org.json.JSONArray;
import org.json.JSONObject;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
    private static final String CHANNEL = "billar_control/tv";
    private TvPresentation tvPresentation;

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL)
                .setMethodCallHandler((call, result) -> {
                    if ("startTv".equals(call.method)) {
                        boolean ok = showTv();
                        result.success(ok ? "connected" : "not_connected");
                    } else if ("updateTv".equals(call.method)) {
                        String tables = call.argument("tables");
                        if (tvPresentation != null && tables != null) tvPresentation.update(tables);
                        result.success(null);
                    } else {
                        result.notImplemented();
                    }
                });
    }

    private boolean showTv() {
        DisplayManager dm = (DisplayManager) getSystemService(Context.DISPLAY_SERVICE);
        Display[] displays = dm.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION);
        if (displays.length == 0) {
            Toast.makeText(this, "No hay un televisor/pantalla externa conectado", Toast.LENGTH_LONG).show();
            return false;
        }
        if (tvPresentation != null) {
            tvPresentation.dismiss();
        }
        tvPresentation = new TvPresentation(this, displays[0]);
        tvPresentation.show();
        return true;
    }

    @Override
    protected void onStop() {
        super.onStop();
        // La pantalla externa puede permanecer activa mientras la CENTRAL siga conectada.
    }

    private static class TvPresentation extends Presentation {
        private final TvView view;
        TvPresentation(Context context, Display display) {
            super(context, display);
            view = new TvView(context);
        }
        @Override protected void onCreate(Bundle savedInstanceState) {
            super.onCreate(savedInstanceState);
            setContentView(view);
        }
        void update(String json) { view.update(json); }
    }

    private static class TvView extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private JSONArray tables = new JSONArray();
        private String error = "";

        TvView(Context context) {
            super(context);
            paint.setTypeface(Typeface.create(Typeface.DEFAULT, Typeface.NORMAL));
            setBackgroundColor(0xFF0B1020);
        }

        void update(String json) {
            try { tables = new JSONArray(json); error = ""; invalidate(); }
            catch (Exception e) { error = "No se pudo actualizar la pantalla"; invalidate(); }
        }

        @Override protected void onDraw(Canvas c) {
            super.onDraw(c);
            float w = getWidth(), h = getHeight();
            paint.setColor(0xFFFFFFFF);
            paint.setTextSize(Math.max(28, w / 28));
            paint.setTypeface(Typeface.create(Typeface.DEFAULT, Typeface.BOLD));
            c.drawText("BILLARES DON MIGUEL", 40, 55, paint);
            paint.setTypeface(Typeface.DEFAULT);
            paint.setTextSize(Math.max(18, w / 55));
            c.drawText("ESTADO DE MESAS", 40, 88, paint);
            if (!error.isEmpty()) { c.drawText(error, 40, 130, paint); return; }

            int count = Math.max(1, tables.length());
            int cols = count <= 3 ? count : 3;
            int rows = (int)Math.ceil(count / (double)cols);
            float gap = 24;
            float top = 120;
            float cardW = (w - gap * (cols + 1)) / cols;
            float cardH = (h - top - gap * (rows + 1)) / rows;

            for (int i = 0; i < count; i++) {
                try {
                    JSONObject t = tables.getJSONObject(i);
                    int id = t.optInt("tableId", i + 1);
                    boolean active = t.optBoolean("active", false);
                    float x = gap + (i % cols) * (cardW + gap);
                    float y = top + gap + (i / cols) * (cardH + gap);
                    paint.setColor(active ? 0xFF8B1E1E : 0xFF164E3B);
                    c.drawRoundRect(new RectF(x, y, x + cardW, y + cardH), 24, 24, paint);
                    paint.setColor(Color.WHITE);
                    paint.setTypeface(Typeface.create(Typeface.DEFAULT, Typeface.BOLD));
                    paint.setTextSize(Math.max(26, cardW / 10));
                    c.drawText("MESA " + id, x + 22, y + 48, paint);
                    paint.setTypeface(Typeface.DEFAULT);
                    paint.setTextSize(Math.max(20, cardW / 15));
                    c.drawText(active ? "OCUPADA" : "DISPONIBLE", x + 22, y + 82, paint);
                    if (active) {
                        String start = t.optString("startedAt", "");
                        if (start.length() >= 16) start = start.substring(11, 16);
                        double total = t.optDouble("total", 0);
                        c.drawText("Inicio: " + start, x + 22, y + 120, paint);
                        c.drawText(String.format("Total: C$ %.2f", total), x + 22, y + 155, paint);
                    }
                } catch (Exception ignored) {}
            }
        }
    }
}
'''

# Fix missing Color import after keeping source compact.
java = java.replace('import android.graphics.Canvas;\n', 'import android.graphics.Canvas;\nimport android.graphics.Color;\n')
(root / 'MainActivity.java').write_text(java)
print('MainActivity con pantalla externa TV instalada.')
