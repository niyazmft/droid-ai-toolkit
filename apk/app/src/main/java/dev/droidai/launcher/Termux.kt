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
        # install_pkg <names...>: the app installs what it needs, so the user never opens Termux
        # for it. `pkg` is only a wrapper and on some devices its mirror check fails ("No mirror
        # or mirror group selected" — its own curl cannot link); plain `apt` still works, so both
        # are tried, with an `apt update` in between.
        install_pkg() {
          pkg install -y "${'$'}@" >/dev/null 2>&1 && return 0
          apt update >/dev/null 2>&1
          apt install -y "${'$'}@" >/dev/null 2>&1 && return 0
          return 1
        }

        # 1. jq is what `install.sh --api` refuses to run without, so it is checked before
        #    anything else — including an existing checkout, which used to be exec'd straight away
        #    and then fail on a device where jq had gone missing.
        if ! command -v jq >/dev/null 2>&1; then
          install_pkg jq
        fi
        if ! command -v jq >/dev/null 2>&1; then
          printf '%s\n' '{"t":"error","code":6,"msg":"missing-packages: jq","missing":"jq","hint":"apt update && apt full-upgrade && apt install -y jq"}'
          exit 6
        fi

        # 2. An existing checkout wins: no download, no network.
        for d in "${'$'}HOME/droid-ai-toolkit" "${'$'}HOME/toolkit-test"; do
          if [ -f "${'$'}d/install.sh" ]; then
            cd "${'$'}d" || exit 1
            exec bash ./install.sh "${'$'}@"
          fi
        done

        # 3. Fetching needs git/curl/tar; the toolkit itself needs nothing else.
        missing=""
        for c in git curl tar; do
          command -v "${'$'}c" >/dev/null 2>&1 || missing="${'$'}missing ${'$'}c"
        done
        if [ -n "${'$'}missing" ]; then
          install_pkg ${'$'}missing
        fi
        missing=""
        for c in git curl tar; do
          command -v "${'$'}c" >/dev/null 2>&1 || missing="${'$'}missing ${'$'}c"
        done
        if [ -n "${'$'}missing" ]; then
          printf '%s\n' "{\"t\":\"error\",\"code\":6,\"msg\":\"missing-packages:${'$'}missing\",\"missing\":\"${'$'}missing\",\"hint\":\"apt update && apt full-upgrade && apt install -y${'$'}missing\"}"
          exit 6
        fi

        # 4. Download into a temporary directory; move it into place only when it arrived, so a
        #    failed download cannot leave a half-written checkout behind.
        DEST="${'$'}HOME/droid-ai-toolkit"
        TMP="${'$'}HOME/.droid-ai-toolkit-fetch"
        LOG="${'$'}HOME/.droid_ai_toolkit"
        mkdir -p "${'$'}LOG" 2>/dev/null
        rm -rf "${'$'}TMP"
        if git clone --depth 1 $REPO_URL "${'$'}TMP" >/dev/null 2>"${'$'}LOG/clone.err"; then
          :
        elif curl -fsSL $TARBALL_URL -o "${'$'}TMP.tgz" >/dev/null 2>&1 &&
             mkdir -p "${'$'}TMP" &&
             tar -xzf "${'$'}TMP.tgz" -C "${'$'}TMP" --strip-components=1 >/dev/null 2>&1; then
          :
        fi
        if [ -f "${'$'}TMP/install.sh" ]; then
          rm -rf "${'$'}DEST"
          mv "${'$'}TMP" "${'$'}DEST"
          rm -f "${'$'}TMP.tgz"
        fi
        if [ -f "${'$'}DEST/install.sh" ]; then
          cd "${'$'}DEST" && exec bash ./install.sh "${'$'}@"
        fi

        # 5. Say why, with the evidence, instead of "it did not work".
        why=$(tail -3 "${'$'}LOG/clone.err" 2>/dev/null | tr -d '"' | tr '\n' ' ')
        printf '%s\n' "{\"t\":\"error\",\"code\":4,\"msg\":\"could not download the toolkit\",\"detail\":\"${'$'}why\"}"
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
        // `--fast`: the gate only needs to know that Termux answered with a status document.
        // The full form measured 23.1 s on 8x — against a 25 s probe ceiling, so on slow
        // hardware it timed out and marked a *working* device unreachable. `--fast` answers
        // the same question in well under half that, and skips the version probes that make
        // it expensive (each one starts a whole Node or Python runtime).
        //
        // The blank versions this returns are fine for a gate but not for a screen: see
        // HomeViewModel, where a fast snapshot may update the device facts but never the
        // installed-tool set (which the engine reports separately in `tools.installed`).
        Runner.send(context, listOf("--api", "status", "--fast"), Origin.PROBE)
    }
}
