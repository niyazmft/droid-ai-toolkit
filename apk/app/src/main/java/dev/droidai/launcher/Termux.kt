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

    private const val REPO_URL = "https://github.com/niyazmft/droid-ai-toolkit.git"
    private const val TARBALL_URL =
        "https://github.com/niyazmft/droid-ai-toolkit/archive/refs/heads/main.tar.gz"

    /**
     * Finds the toolkit in Termux and runs its machine interface.
     *
     * `bash -c` receives the arguments after $0, so "--api status" reaches
     * install.sh intact. Nothing is interpolated into a shell string by the app:
     * the argument list is passed as argv.
     *
     * When no checkout exists this **fetches one** instead of failing. That is what
     * makes "install Termux from F-Droid, and that is it" true: the user never has
     * to clone the repository or open a shell. `--api` needs the whole checkout (it
     * sources lib/), so `curl … | bash` is not enough here — hence a clone, with a
     * tarball fallback for a device without git.
     *
     * `$HOME/install.sh` is deliberately not a candidate. It is the curl-installed
     * monolith, it cannot serve `--api`, and running a stale copy of it is what
     * broke a Hermes update on 8x (see AGENTS.md, v1.17.7).
     */
    private val launcher =
        """
        for d in "${'$'}HOME/droid-ai-toolkit" "${'$'}HOME/toolkit-test"; do
          if [ -f "${'$'}d/install.sh" ]; then
            cd "${'$'}d" || exit 1
            exec bash ./install.sh "${'$'}@"
          fi
        done
        DEST="${'$'}HOME/droid-ai-toolkit"
        command -v git >/dev/null 2>&1 || pkg install -y git >/dev/null 2>&1
        command -v curl >/dev/null 2>&1 || pkg install -y curl >/dev/null 2>&1
        rm -rf "${'$'}DEST"
        if git clone --depth 1 $REPO_URL "${'$'}DEST" >/dev/null 2>&1; then
          :
        elif curl -fsSL $TARBALL_URL | tar -xz -C "${'$'}HOME" >/dev/null 2>&1; then
          mv "${'$'}HOME/droid-ai-toolkit-main" "${'$'}DEST" >/dev/null 2>&1
        fi
        if [ -f "${'$'}DEST/install.sh" ]; then
          cd "${'$'}DEST" && exec bash ./install.sh "${'$'}@"
        fi
        printf '%s\n' '{"t":"error","code":4,"msg":"first-run setup could not download the toolkit: no network, or git and curl are both unavailable"}'
        exit 4
        """.trimIndent()

    fun buildIntent(
        args: List<String>,
        pending: PendingIntent,
    ): Intent =
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

    /** The one line a user must paste into Termux, offered as a copy button. */
    const val ALLOW_EXTERNAL_APPS =
        """echo "allow-external-apps = true" >> ~/.termux/termux.properties && termux-reload-settings"""

    fun probe(context: Context) {
        Gate.resetProbe()
        Runner.send(context, listOf("--api", "status"), Origin.PROBE)
    }
}
