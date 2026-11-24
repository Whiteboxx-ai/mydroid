package com.mydroid.android.fix

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings

/** dontkillmyapp.com-style knowledge: OEM auto-start / battery screens that can keep Mydroid alive. */
object Oem {
    private class Target(val pkg: String, val cls: String)

    private fun targets(): List<Target> {
        val m = Build.MANUFACTURER.lowercase()
        return when {
            "xiaomi" in m || "redmi" in m || "poco" in m -> listOf(
                Target("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
                Target("com.miui.securitycenter", "com.miui.powercenter.PowerSettings"),
            )
            "samsung" in m -> listOf(
                Target("com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity"),
                Target("com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity"),
                Target("com.samsung.android.sm_cn", "com.samsung.android.sm.ui.battery.BatteryActivity"),
            )
            "oneplus" in m -> listOf(
                Target("com.oneplus.security", "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"),
                Target("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
            )
            "oppo" in m || "realme" in m -> listOf(
                Target("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
                Target("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
                Target("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
            )
            "huawei" in m -> listOf(
                Target("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
                Target("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"),
            )
            "honor" in m -> listOf(
                Target("com.hihonor.systemmanager", "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
                Target("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            )
            "vivo" in m || "iqoo" in m -> listOf(
                Target("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
                Target("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
            )
            "asus" in m -> listOf(Target("com.asus.mobilemanager", "com.asus.mobilemanager.autostart.AutoStartActivity"))
            "tecno" in m || "infinix" in m || "itel" in m || "transsion" in m ->
                listOf(Target("com.transsion.phonemaster", "com.itel.autobootmanager.activity.AutoBootMgrActivity"))
            else -> emptyList()
        }
    }

    /** First OEM screen that exists on this device, or null on stock-ish Android. */
    fun autoStartIntent(c: Context): Intent? {
        for (t in targets()) {
            val i = Intent().setComponent(ComponentName(t.pkg, t.cls)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (i.resolveActivity(c.packageManager) != null) return i
        }
        return null
    }

    val brandName: String
        get() = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }

    fun appDetails(c: Context): Intent =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", c.packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /**
     * Android can't tell us whether an OEM auto-start switch is on. What it can tell us is whether the
     * system killed Mydroid in the background, which is the problem that switch exists to prevent.
     * Returns the time of the most recent such kill, or null if there's no evidence of one.
     */
    fun lastBackgroundKill(c: Context): Long? {
        if (Build.VERSION.SDK_INT < 30) return null
        val am = c.getSystemService(ActivityManager::class.java) ?: return null
        val reasons = buildSet {
            add(ApplicationExitInfo.REASON_OTHER)
            add(ApplicationExitInfo.REASON_SIGNALED)
            add(ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE)
            if (Build.VERSION.SDK_INT >= 34) add(ApplicationExitInfo.REASON_FREEZER)
        }
        return runCatching { am.getHistoricalProcessExitReasons(c.packageName, 0, 20) }.getOrNull()
            ?.filter { it.reason in reasons && it.importance > ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND }
            ?.maxOfOrNull { it.timestamp }
    }

    /** True when the OEM has killed Mydroid since the user last visited its auto-start screen. */
    fun needsAutoStart(c: Context, openedAt: Long): Long? =
        lastBackgroundKill(c)?.takeIf { it > openedAt }

    /** Best-effort launch of the OEM screen; falls back to app details. */
    fun openAutoStart(c: Context) {
        val target = autoStartIntent(c) ?: appDetails(c)
        try {
            c.startActivity(target)
        } catch (e: Exception) {
            runCatching { c.startActivity(appDetails(c)) }
        }
    }
}
