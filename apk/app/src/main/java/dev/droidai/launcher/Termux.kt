package dev.droidai.launcher

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent

/**
 * The Termux side of the contract.
 *
 * The app never touches Termux's files: they belong to another UID and SELinux
 * forbids it. Everything goes through one explicit intent to RunCommandService,
 * which Termux executes as itself.
 *
 * Values are copied from TermuxConstants (upstream) rather than guessed:
 *   RUN_COMMAND_SERVICE.EXTRA_*        = com.termux.RUN_COMMAND_*
 *   TERMUX_SERVICE.EXTRA_PLUGIN_RESULT_BUNDLE = "result"
 *   bundle keys: stdout, stderr, exitCode, err, errmsg
 */
object Termux {
    const val PKG = "com.termux"
    const val SERVICE = "com.termux.app.RunCommandService"
    const val ACTION_RUN = "com.termux.RUN_COMMAND"
    const val PERMISSION = "com.termux.permission.RUN_COMMAND"

    const val EXTRA_PATH = "com.termux.RUN_COMMAND_PATH"
    const val EXTRA_ARGS = "com.termux.RUN_COMMAND_ARGUMENTS"
    const val EXTRA_WORKDIR = "com.termux.RUN_COMMAND_WORKDIR"
    const val EXTRA_BACKGROUND = "com.termux.RUN_COMMAND_BACKGROUND"
    const val EXTRA_PENDING = "com.termux.RUN_COMMAND_PENDING_INTENT"

    const val RESULT_BUNDLE = "result"
    const val R_STDOUT = "stdout"
    const val R_STDERR = "stderr"
    const val R_EXIT = "exitCode"
    const val R_ERR = "err"
    const val R_ERRMSG = "errmsg"

    const val BASH = "/data/data/com.termux/files/usr/bin/bash"
    const val HOME_DIR = "/data/data/com.termux/files/home"

    /**
     * Finds the toolkit in Termux and runs its machine interface.
     *
     * `bash -c` receives the arguments after $0, so "--api status" reaches
     * install.sh intact. Nothing is interpolated into a shell string by the app:
     * the argument list is passed as argv.
     */
    private val launcher = """
        for d in "${'$'}HOME/droid-ai-toolkit" "${'$'}HOME/toolkit-test" "${'$'}HOME"; do
          if [ -f "${'$'}d/install.sh" ] && [ -d "${'$'}d/lib" ]; then
            cd "${'$'}d" || exit 1
            exec bash ./install.sh "${'$'}@"
          fi
        done
        printf '%s\n' '{"t":"error","code":4,"msg":"toolkit not found under ${'$'}HOME (expected ~/droid-ai-toolkit)"}'
        exit 4
    """.trimIndent()

    fun buildIntent(args: List<String>, pending: PendingIntent): Intent =
        Intent().apply {
            component = ComponentName(PKG, SERVICE)
            action = ACTION_RUN
            putExtra(EXTRA_PATH, BASH)
            putExtra(EXTRA_ARGS, arrayOf("-c", launcher, "droid-ai") + args.toTypedArray())
            putExtra(EXTRA_WORKDIR, HOME_DIR)
            putExtra(EXTRA_BACKGROUND, true)
            putExtra(EXTRA_PENDING, pending)
        }

    /** Opens Termux itself, for the one setup step the app cannot perform. */
    fun openTermux(context: Context): Boolean {
        val i = context.packageManager.getLaunchIntentForPackage(PKG) ?: return false
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return runCatching { context.startActivity(i) }.isSuccess
    }

    fun probe(context: Context) = Runner.send(context, listOf("--api", "status"), isProbe = true)
}
