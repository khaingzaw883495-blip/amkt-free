package com.amkt.vpn

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Home-screen widget (v1.0.2).
 *
 * The widget is native — Flutter widgets cannot run on the home screen.
 * Dart pushes status into the widget's data (see HomeWidgetService) and
 * asks Android to redraw; this provider reads that data and paints the
 * widget. The button does NOT toggle the VPN by itself: it opens the
 * app with the `amktvpn://toggle` deep link, and the app toggles the
 * VPN (the VPN cores live in the Flutter engine — a widget cannot start
 * a VpnService from the background on Android 12+).
 *
 * Data keys (written by Dart, read here):
 *   status  — "Connected" / "Connecting…" / "ချိတ်မထားပါ"
 *   country — e.g. "🇸🇬 Singapore" (empty when no server selected)
 *   action  — button label: "ချိတ်မယ်" / "ဖြုတ်မယ်"
 */
class AmktVpnWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(context.packageName, R.layout.amkt_vpn_widget).apply {
                val status = widgetData.getString("status", null) ?: "ချိတ်မထားပါ"
                val country = widgetData.getString("country", null) ?: ""
                val action = widgetData.getString("action", null) ?: "ချိတ်မယ်"
                setTextViewText(R.id.widget_status, status)
                setTextViewText(R.id.widget_country, country)
                setTextViewText(R.id.widget_action, action)
                // Button tap opens the app with amktvpn://toggle.
                val intent = HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("amktvpn://toggle")
                )
                setOnClickPendingIntent(R.id.widget_action, intent)
                // Tapping the widget body also opens the app.
                val openIntent = HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java
                )
                setOnClickPendingIntent(R.id.widget_root, openIntent)
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
