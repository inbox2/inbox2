package com.inbox2.app.theme

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import androidx.annotation.DrawableRes
import com.inbox2.app.R

/**
 * The app icons a user can pick in Settings › Theme (iOS AppIconOption).
 *
 * Android has no `setAlternateIconName`: the launcher entry is an `<activity-alias>`
 * per icon and exactly one is enabled at a time, so the PackageManager component state
 * *is* the stored preference — nothing else persists the choice.
 *
 * Artwork comes from `brand/make-alt-icons.py`: `mipmap-anydpi-v26/ic_launcher_<name>.xml`
 * for the launcher, `drawable-nodpi/app_icon_<name>.png` for the picker row (Compose's
 * painterResource can't load an AdaptiveIconDrawable).
 */
enum class AppIconOption(
    val alias: String,
    @DrawableRes val preview: Int,
    val label: String,
    val blurb: String,
) {
    CLASSIC(".IconClassic", R.drawable.app_icon_classic, "Classic", "The original ring"),
    SUN(".IconSun", R.drawable.app_icon_sun, "Rising sun", "Red rays, cream ground"),
    VENNLIGHT(".IconVennlight", R.drawable.app_icon_vennlight, "Venn", "Three discs on white"),
    GRAFFITI(".IconGraffiti", R.drawable.app_icon_graffiti, "Graffiti", "Wildstyle X"),
    GROOVEBOX(".IconGroovebox", R.drawable.app_icon_groovebox, "Groovebox", "Line-art cube on the grid");

    private fun component(ctx: Context) = ComponentName(ctx.packageName, ctx.packageName + alias)

    companion object {
        /** Matches `android:enabled="true"` on the one alias in AndroidManifest.xml. */
        val DEFAULT = CLASSIC

        /** Which alias the launcher is showing. */
        fun current(ctx: Context): AppIconOption {
            val pm = ctx.packageManager
            return entries.firstOrNull {
                // An untouched component reports DEFAULT, which means "whatever the
                // manifest says" — only the default alias ships enabled.
                when (pm.getComponentEnabledSetting(it.component(ctx))) {
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED -> false
                    else -> it == DEFAULT
                }
            } ?: DEFAULT
        }

        /**
         * Enable the chosen alias, then disable the rest — in that order, so the app
         * never has zero launcher entries (a launcher that rescans in the gap drops the
         * icon from the home screen). DONT_KILL_APP keeps this process alive; the
         * aliases are not the running component, only its front door.
         */
        fun select(ctx: Context, option: AppIconOption) {
            val pm = ctx.packageManager
            pm.setComponentEnabledSetting(
                option.component(ctx),
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP,
            )
            entries.filter { it != option }.forEach {
                pm.setComponentEnabledSetting(
                    it.component(ctx),
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP,
                )
            }
        }
    }
}
