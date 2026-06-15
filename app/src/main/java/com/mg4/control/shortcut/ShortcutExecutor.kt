package com.mg4.control.shortcut

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.app.AlertDialog
import android.view.ContextThemeWrapper
import android.view.LayoutInflater
import android.view.View
import android.os.Handler
import android.os.Looper
import android.widget.LinearLayout
import com.mg4.control.BuildConfig
import com.mg4.control.MainActivity
import com.mg4.control.R
import com.mg4.control.model.RegenLevel
import com.mg4.control.profile.ProfileApplier
import com.mg4.control.profile.ProfileManager
import com.mg4.control.service.ProfilePickerOverlay
import com.mg4.control.hardware.MG4Hardware
import com.mg4.control.hardware.MG4Hardware.AebMode
import com.mg4.control.hardware.MG4Hardware.Swi68Mode
import com.mg4.control.util.FirmwareInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

object ShortcutExecutor {

    fun executeConfiguredShortcut(context: Context, prefs: SharedPreferences, pressKey: String) {
        val action = ShortcutAction.fromId(prefs.getInt("shortcut_$pressKey", ShortcutAction.NONE.id))
        execute(context, prefs, action, pressKey)
    }

    fun execute(context: Context, prefs: SharedPreferences, action: ShortcutAction, pressKey: String = "") {
        if (action == ShortcutAction.NONE) return

        if (action == ShortcutAction.PROFILE_PICKER) {
            Handler(Looper.getMainLooper()).post {
                if (BuildConfig.EMULATOR_MODE) {
                    showEmulatorProfilePicker(context)
                } else {
                    ProfilePickerOverlay.toggle(context)
                }
            }
            return
        }

        if (action == ShortcutAction.APPLY_PROFILE) {
            val profileId = prefs.getString("shortcut_${pressKey}_profile_id", null) ?: return
            CoroutineScope(Dispatchers.IO).launch {
                val profile = ProfileManager(context.applicationContext).getById(profileId)
                if (profile != null) {
                    ProfileApplier.apply(profile)
                }
            }
            return
        }

        val toggleState = !(prefs.getBoolean("shortcut_toggle_${action.name}", false))
        prefs.edit().putBoolean("shortcut_toggle_${action.name}", toggleState).apply()

        CoroutineScope(Dispatchers.IO).launch {
            when (action) {
                ShortcutAction.ONE_PEDAL -> {
                    if (toggleState) {
                        MG4Hardware.setRegenLevel(RegenLevel.ONE_PEDAL)
                    } else {
                        val fallback = RegenLevel.fromValue(
                            prefs.getInt("shortcut_one_pedal_fallback", RegenLevel.HIGH.value)
                        )
                        MG4Hardware.setRegenLevel(fallback)
                    }
                }
                ShortcutAction.AEB_CYCLE -> {
                    val mode = if (toggleState)
                        prefs.getInt("shortcut_aeb_mode_a", AebMode.ALARM)
                    else
                        prefs.getInt("shortcut_aeb_mode_b", AebMode.ALARM_BRAKE)
                    MG4Hardware.setAebMode(mode)
                }
                ShortcutAction.SOUND_WARNING    -> MG4Hardware.setSoundWarning(toggleState)
                ShortcutAction.OVERSPEED_ALARM  -> MG4Hardware.setOverspeedAlarm(toggleState)
                ShortcutAction.SPEED_LIMIT_TONE -> MG4Hardware.setSpeedLimitTone(toggleState)
                ShortcutAction.ADAS_CYCLE -> {
                    val modeA = prefs.getInt("shortcut_adas_mode_a", 3)
                    val modeB = prefs.getInt("shortcut_adas_mode_b", 0)
                    val mode  = if (toggleState) modeA else modeB
                    if (FirmwareInfo.isVsmBased()) {
                        when (mode) {
                            1 -> { MG4Hardware.setSpeedLimiterMode(MG4Hardware.SasMode.MANUEL);      MG4Hardware.setAccTjaMode(Swi68Mode.OFF) }
                            2 -> { MG4Hardware.setSpeedLimiterMode(MG4Hardware.SasMode.INTELLIGENT); MG4Hardware.setAccTjaMode(Swi68Mode.OFF) }
                            3 -> { MG4Hardware.setAccTjaMode(Swi68Mode.ACC); MG4Hardware.setSpeedLimiterMode(MG4Hardware.SasMode.OFF) }
                            4 -> { MG4Hardware.setAccTjaMode(Swi68Mode.TJA); MG4Hardware.setSpeedLimiterMode(MG4Hardware.SasMode.OFF) }
                            else -> { MG4Hardware.setAccTjaMode(Swi68Mode.OFF); MG4Hardware.setSpeedLimiterMode(MG4Hardware.SasMode.OFF) }
                        }
                    } else {
                        MG4Hardware.setMixedIntelligentDrive(mode)
                    }
                }
                ShortcutAction.ENERGY_SAVING_TOGGLE -> MG4Hardware.setEnergySavingMode(toggleState)
                ShortcutAction.TSR_TOGGLE           -> MG4Hardware.setTsrMode(toggleState)
                ShortcutAction.OPEN_APP -> {
                    val intent = Intent(context, MainActivity::class.java).apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                    }
                    context.startActivity(intent)
                }
                ShortcutAction.OPEN_CUSTOM_APP -> {
                    val pkg = prefs.getString("shortcut_${pressKey}_custom_app", null) ?: return@launch
                    val launchIntent = context.packageManager.getLaunchIntentForPackage(pkg) ?: return@launch
                    launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(launchIntent)
                }
                else -> Unit
            }
        }
    }

    private fun showEmulatorProfilePicker(context: Context) {
        val profiles = ProfileManager(context.applicationContext).getAll()
        if (profiles.isEmpty()) return

        val themed = ContextThemeWrapper(context, R.style.Theme_MG4Control)
        val content = LayoutInflater.from(themed).inflate(R.layout.overlay_profile_picker, null)
        val container = content.findViewById<LinearLayout>(R.id.overlay_profiles_container)

        val dialog = AlertDialog.Builder(themed, com.google.android.material.R.style.ThemeOverlay_Material3_MaterialAlertDialog)
            .setView(content)
            .create()

        content.findViewById<View>(R.id.overlay_btn_close)?.setOnClickListener {
            dialog.dismiss()
        }
        content.findViewById<View>(R.id.overlay_backdrop)?.setOnClickListener {
            dialog.dismiss()
        }

        val dm = context.resources.displayMetrics
        fun dp(value: Float) = (value * dm.density).toInt()

        profiles.chunked(2).forEach { row ->
            val rowLayout = LinearLayout(themed).apply {
                orientation = LinearLayout.HORIZONTAL
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).also { it.bottomMargin = dp(10f) }
            }

            row.forEachIndexed { index, profile ->
                val button = com.google.android.material.button.MaterialButton(themed).apply {
                    text = profile.name
                    textSize = 19f
                    isAllCaps = false
                    setOnClickListener {
                        CoroutineScope(Dispatchers.IO).launch {
                            ProfileApplier.apply(profile)
                        }
                        dialog.dismiss()
                    }
                }
                rowLayout.addView(button, LinearLayout.LayoutParams(0, dp(90f), 1f).also {
                    if (index == 0 && row.size == 2) it.marginEnd = dp(10f)
                })
            }

            if (row.size == 1) {
                rowLayout.addView(View(themed), LinearLayout.LayoutParams(0, dp(90f), 1f))
            }

            container.addView(rowLayout)
        }

        dialog.show()
    }
}
