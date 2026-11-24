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
 * `getPackagesHoldingPermissions` is subject to package-visibility filtering on API 30+, and
 * there is no `<queries><permission>` element to declare against — the `<queries>` element
 * accepts only `package`, `intent` and `provider`. (An earlier comment in this file claimed
 * otherwise; the manifest says it explicitly.) So on API < 30 this list is complete, and on
 * API 30+ it can be partial: the check is a diagnostic, not a guarantee. Completing it would
 * mean requesting QUERY_ALL_PACKAGES, which is not worth it for a warning line.
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
