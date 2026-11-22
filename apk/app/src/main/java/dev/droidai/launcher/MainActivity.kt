package dev.droidai.launcher

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

class MainActivity : ComponentActivity() {

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) {
            Gate.refresh(this)
            Gate.probeOk.value = null
            Termux.probe(this)
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Gate.refresh(this)
        setContent {
            MaterialTheme {
                Surface(Modifier.fillMaxSize()) { Root() }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        Gate.refresh(this)
    }

    private fun requestPermission() = permissionLauncher.launch(Termux.PERMISSION)

    private fun openUrl(url: String) {
        runCatching {
            startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }

    @Composable
    private fun Root() {
        val termux by Gate.termuxInstalled.collectAsStateWithLifecycle()
        val permission by Gate.permissionGranted.collectAsStateWithLifecycle()
        val probe by Gate.probeOk.collectAsStateWithLifecycle()
        val message by Gate.probeMessage.collectAsStateWithLifecycle()

        LaunchedEffect(termux, permission) {
            if (termux && permission && probe == null) Termux.probe(this@MainActivity)
        }

        when {
            !termux -> Setup(
                title = "Termux is required",
                body = "Droid AI runs inside Termux, which owns the Linux environment. " +
                    "Install it from F-Droid or the GitHub releases — not the Play Store build, " +
                    "which is outdated.",
                primary = "Get Termux" to { openUrl("https://f-droid.org/packages/com.termux/") },
                secondary = "Re-check" to { Gate.refresh(this@MainActivity) }
            )

            !permission -> Setup(
                title = "Allow commands in Termux",
                body = "Android needs you to grant \"Run commands in Termux environment\". " +
                    "It is a dangerous permission defined by Termux, so it appears under " +
                    "Additional permissions in App info.",
                primary = "Grant permission" to { requestPermission() },
                secondary = "Re-check" to { Gate.refresh(this@MainActivity) }
            )

            probe != true -> Setup(
                title = "Enable external commands",
                body = "Termux only accepts commands from other apps when allow-external-apps " +
                    "is true. In Termux, run:\n\n" +
                    "echo \"allow-external-apps = true\" >> ~/.termux/termux.properties\n" +
                    "termux-reload-settings\n\n" +
                    "Then come back and retry." +
                    if (message.isNotBlank()) "\n\nReported: $message" else "",
                primary = "Open Termux" to { Termux.openTermux(this@MainActivity) },
                secondary = "Retry" to {
                    Gate.probeOk.value = null
                    Termux.probe(this@MainActivity)
                }
            )

            else -> Home()
        }
    }
}

@Composable
private fun Setup(
    title: String,
    body: String,
    primary: Pair<String, () -> Unit>,
    secondary: Pair<String, () -> Unit>
) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Text(title, style = MaterialTheme.typography.headlineSmall)
        Text(body, style = MaterialTheme.typography.bodyMedium)
        Button(onClick = primary.second, modifier = Modifier.fillMaxWidth()) {
            Text(primary.first)
        }
        OutlinedButton(onClick = secondary.second, modifier = Modifier.fillMaxWidth()) {
            Text(secondary.first)
        }
    }
}

@Composable
private fun Home() {
    val context = LocalContext.current
    val result by Runner.result.collectAsStateWithLifecycle()
    val running by Runner.running.collectAsStateWithLifecycle()
    var log by remember { mutableStateOf("") }

    LaunchedEffect(result) {
        result?.let {
            log = it.stdout.ifBlank { it.stderr.ifBlank { it.errmsg } }
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text("Droid AI", style = MaterialTheme.typography.headlineMedium)
        Text("Termux is ready.", style = MaterialTheme.typography.bodyMedium)

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                onClick = { Runner.send(context, listOf("--api", "status")) },
                enabled = !running
            ) { Text("Status") }

            OutlinedButton(
                onClick = { Runner.send(context, listOf("--api", "list")) },
                enabled = !running
            ) { Text("Actions") }
        }

        if (running) {
            LinearProgressIndicator(Modifier.fillMaxWidth())
            Text("Running…", style = MaterialTheme.typography.bodySmall)
        }

        result?.let { r ->
            Text(
                "exit ${r.exitCode}" + if (r.errmsg.isNotBlank()) " · ${r.errmsg}" else "",
                style = MaterialTheme.typography.labelLarge
            )
        }

        Text(
            log.take(8000),
            fontFamily = FontFamily.Monospace,
            style = MaterialTheme.typography.bodySmall
        )
    }
}
