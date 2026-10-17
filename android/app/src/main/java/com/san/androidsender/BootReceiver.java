package com.san.androidsender;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public final class BootReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        if (intent == null || !(Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())
                || Intent.ACTION_MY_PACKAGE_REPLACED.equals(intent.getAction()))) return;
        if (context.getSharedPreferences("sender", Context.MODE_PRIVATE).getBoolean("enabled", false))
            context.startForegroundService(new Intent(context, SenderService.class).setAction(SenderService.WAIT));
    }
}
