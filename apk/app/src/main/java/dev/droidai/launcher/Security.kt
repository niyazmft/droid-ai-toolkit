package dev.droidai.launcher

import android.content.Context

/**
 * Who can run commands in Termux?
 *
 * `allow-external-apps` is one global boolean in Termux — there is no per-app
 * allowlist and no way to say "only this app". The enforceable boundary is the
 * permission: an app that does not hold `com.termux.permission.RUN_COMMAND`
 * cannot use RUN_COMMAND, whatever the property says.
 *
 * So the app audits grants. Granting is not silent: it is a dangerous permission
 * defined by Termux, and the user must approve it under *Additional permissions*
 * in App info. But a user can be talked into that by the wrong app, and nothing
 * on the Termux side would notice — hence this check.
 *
 * `getPackagesHoldingPermissions` is subject to package-visibility filtering on
 * API 30+, which is why the manifest declares
 * `<queries><permission android:name="com.termux.permission.RUN_COMMAND"/></queries>`.
 */
object Security {
    /** Every package currently holding the Termux RUN_COMMAND permission. */
    fun holders(context: Context): List<String> =
        runCatching {
            context.packageManager
                .getPackagesHoldingPermissions(arrayOf(Termux.PERMISSION), 0)
                .map { it.packageName }
                .sorted()
        }.getOrDefault(emptyList())

    /** Holders other than this app — each one is a way into Termux's shell. */
    fun foreignHolders(context: Context): List<String> = holders(context).filter { it != context.packageName }

    /** The command to revoke a grant, for a user who wants to close the gap. */
    fun revokeCommand(pkg: String): String = "adb shell pm revoke $pkg ${Termux.PERMISSION}"
}
