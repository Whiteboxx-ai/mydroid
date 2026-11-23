package com.mydroid.android.find

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.mydroid.android.ui.MydroidTheme

/** Full-screen "Stop" screen shown over the lock screen while the phone is ringing for find-my-phone. */
class FindActivity : ComponentActivity() {
    private val finisher = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        ContextCompat.registerReceiver(this, finisher, IntentFilter(ACTION_FINISH), ContextCompat.RECEIVER_NOT_EXPORTED)
        setContent {
            MydroidTheme {
                Surface(Modifier.fillMaxSize()) {
                    FindScreen(onStop = { FindMyPhone.stop(this); finish() })
                }
            }
        }
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(finisher) }
        super.onDestroy()
    }

    companion object {
        const val ACTION_FINISH = "com.mydroid.android.FIND_FINISH"
    }
}

@Composable
private fun FindScreen(onStop: () -> Unit) {
    Column(
        Modifier.fillMaxSize().systemBarsPadding().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Here I am", style = MaterialTheme.typography.displayMedium, textAlign = TextAlign.Center)
        Spacer(Modifier.height(12.dp))
        Text("Your Mac is finding this phone", style = MaterialTheme.typography.bodyLarge, textAlign = TextAlign.Center)
        Spacer(Modifier.height(48.dp))
        Button(onClick = onStop, modifier = Modifier.fillMaxWidth().height(72.dp)) {
            Text("Stop", style = MaterialTheme.typography.titleLarge)
        }
    }
}
