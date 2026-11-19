package com.vitanet.staff;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.print.PrintAttributes;
import android.print.PrintJob;
import android.print.PrintManager;
import android.webkit.GeolocationPermissions;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.Toast;

public class MainActivity extends Activity {
    private static final String APP_URL = "https://asofarof20-lab.github.io/vita-staff/";
    private static final String APP_HOST = "asofarof20-lab.github.io";
    private static final int LOCATION_REQUEST = 5102;

    private FrameLayout root;
    private WebView web;
    private GeolocationPermissions.Callback pendingGeoCallback;
    private String pendingGeoOrigin;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        root = new FrameLayout(this);
        web = new WebView(this);

        WebSettings settings = web.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setDatabaseEnabled(true);
        settings.setGeolocationEnabled(true);
        settings.setLoadWithOverviewMode(true);
        settings.setUseWideViewPort(true);

        web.addJavascriptInterface(new NativePrintBridge(), "VitaNativePrint");
        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onGeolocationPermissionsShowPrompt(String origin, GeolocationPermissions.Callback callback) {
                if (!origin.startsWith("https://" + APP_HOST + "/")) {
                    callback.invoke(origin, false, false);
                    return;
                }
                if (hasLocationPermission()) {
                    callback.invoke(origin, true, false);
                } else {
                    pendingGeoOrigin = origin;
                    pendingGeoCallback = callback;
                    requestPermissions(
                        new String[]{Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION},
                        LOCATION_REQUEST
                    );
                }
            }
        });
        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri uri = request.getUrl();
                if (APP_HOST.equals(uri.getHost())) return false;
                openExternal(uri);
                return true;
            }
        });

        root.addView(web, new FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        ));
        setContentView(root);
        web.loadUrl(APP_URL);
    }

    private boolean hasLocationPermission() {
        return checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
            || checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == LOCATION_REQUEST && pendingGeoCallback != null) {
            boolean granted = hasLocationPermission();
            pendingGeoCallback.invoke(pendingGeoOrigin, granted, false);
            pendingGeoCallback = null;
            pendingGeoOrigin = null;
            if (!granted) Toast.makeText(this, "Для GPS разрешите доступ к местоположению", Toast.LENGTH_LONG).show();
        }
    }

    private void openExternal(Uri uri) {
        try {
            if ("https".equals(uri.getScheme()) || "http".equals(uri.getScheme())
                || "tel".equals(uri.getScheme()) || "geo".equals(uri.getScheme())) {
                startActivity(new Intent(Intent.ACTION_VIEW, uri));
            }
        } catch (Exception e) {
            Toast.makeText(this, "Не удалось открыть ссылку", Toast.LENGTH_SHORT).show();
        }
    }

    private final class NativePrintBridge {
        @JavascriptInterface
        public void printHtml(String html) {
            runOnUiThread(() -> printInvoiceHtml(html));
        }
    }

    private void printInvoiceHtml(String html) {
        if (html == null || html.length() > 1000000) {
            Toast.makeText(this, "Не удалось подготовить накладную", Toast.LENGTH_LONG).show();
            return;
        }

        final WebView printView = new WebView(this);
        printView.getSettings().setJavaScriptEnabled(false);
        printView.setBackgroundColor(Color.WHITE);
        printView.setAlpha(0.01f);
        root.addView(printView, new FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        ));

        printView.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView view, String url) {
                view.postDelayed(() -> {
                    try {
                        PrintManager printManager = (PrintManager) getSystemService(Context.PRINT_SERVICE);
                        String jobName = "VITANET — накладная";
                        PrintAttributes attributes = new PrintAttributes.Builder()
                            .setMediaSize(PrintAttributes.MediaSize.ISO_A4)
                            .setResolution(new PrintAttributes.Resolution("vita", "VITA", 300, 300))
                            .setMinMargins(new PrintAttributes.Margins(250, 250, 250, 250))
                            .build();
                        PrintJob job = printManager.print(jobName, view.createPrintDocumentAdapter(jobName), attributes);
                        monitorPrintJob(job, printView);
                    } catch (Exception e) {
                        root.removeView(printView);
                        printView.destroy();
                        Toast.makeText(MainActivity.this, "Не удалось открыть печать: " + e.getMessage(), Toast.LENGTH_LONG).show();
                    }
                }, 300);
            }
        });

        String printableHtml = html.replace("<script>window.onload=()=>window.print()</script>", "");
        printView.loadDataWithBaseURL(APP_URL, printableHtml, "text/html", "UTF-8", null);
    }

    private void monitorPrintJob(PrintJob job, WebView printView) {
        Handler handler = new Handler(Looper.getMainLooper());
        Runnable checker = new Runnable() {
            @Override
            public void run() {
                if (isFinishing() || job.isCompleted() || job.isFailed() || job.isCancelled()) {
                    if (printView.getParent() == root) root.removeView(printView);
                    printView.destroy();
                } else {
                    handler.postDelayed(this, 1000);
                }
            }
        };
        handler.postDelayed(checker, 1000);
    }

    @Override
    public void onBackPressed() {
        if (web != null && web.canGoBack()) web.goBack();
        else super.onBackPressed();
    }

    @Override
    protected void onDestroy() {
        if (web != null) web.destroy();
        super.onDestroy();
    }
}
