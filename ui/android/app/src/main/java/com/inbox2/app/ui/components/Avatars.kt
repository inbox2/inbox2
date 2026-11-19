package com.inbox2.app.ui.components

import com.inbox2.app.model.MailAddress
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateIntAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.Image
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import coil.compose.AsyncImage
import com.inbox2.app.R
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.ChannelColor
import com.inbox2.app.theme.ThemePalette
import com.inbox2.app.theme.theme

/**
 * Circular avatar with the pink→violet→orange gradient ring (iOS AvatarRing). Spins the
 * ring while `loading` (the reader's loading affordance). Renders initials on a dark
 * tile (person avatars in rows/activity/reader).
 */
@Composable
fun AvatarRing(
    initials: String,
    size: Dp = 56.dp,
    seed: Int = 0,
    loading: Boolean = false,
    icon: String? = null,
    modifier: Modifier = Modifier,
    /** The person's address: their picture (Gravatar, else their domain's icon)
     *  replaces the initials once it loads. See [com.inbox2.app.cloud.AvatarImages]. */
    email: String? = null,
) {
    val p = theme
    val ctx = LocalContext.current
    val photo by androidx.compose.runtime.produceState<android.graphics.Bitmap?>(null, email) {
        value = email?.let { com.inbox2.app.cloud.AvatarImages.get(ctx, it) }
    }
    val spin by rememberInfiniteTransition(label = "ring").animateFloat(
        initialValue = 0f, targetValue = if (loading) 360f else 0f,
        animationSpec = infiniteRepeatable(tween(1000, easing = LinearEasing), RepeatMode.Restart),
        label = "spin",
    )
    Box(modifier.size(size), contentAlignment = Alignment.Center) {
        Box(
            Modifier
                .size(size)
                .rotate(if (loading) spin else 0f)
                .background(p.ringGradient, CircleShape),
        )
        Box(
            Modifier
                .size(size - 6.dp)
                .clip(CircleShape)
                .background(p.bgElevated),
            contentAlignment = Alignment.Center,
        ) {
            val bmp = photo
            if (bmp != null) {
                Image(bmp.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            } else if (icon != null) {
                Icon(SfIcon.vector(icon), null, tint = p.textPrimary, modifier = Modifier.size(size * 0.36f))
            } else {
                Text(initials, color = p.textPrimary,
                    style = AppFont.ui(1).copy(fontSize = (size.value * 0.34f).sp, fontWeight = FontWeight.SemiBold))
            }
        }
    }
}

/**
 * Channel badge for the top tracker (iOS ChannelAvatar): the inbox2 cube on a light tile
 * for Unified, the provider photo when present, else a deterministic ChannelColor circle
 * with the account initial. A hairline ring turns violet when selected; an optional green
 * online dot. The tinted-initial circle sits *under* the remote photo so a failed image
 * load falls back gracefully instead of showing blank.
 */
@Composable
fun ChannelAvatar(
    label: String,
    seed: String,
    order: List<String> = emptyList(),
    avatarURL: String? = null,
    icon: String? = null,
    isUnified: Boolean = false,
    selected: Boolean = false,
    online: Boolean = false,
    provider: String? = null,
    size: Dp = 58.dp,
) {
    val p = theme
    val ringColor = if (selected) p.accentViolet else p.textTertiary.copy(alpha = 0.55f)
    // Real provider brand logo (Gmail/Outlook/WhatsApp/…) when we know the provider —
    // matches iOS ChannelAvatar.brandLogo(for:). Drawn on a white tile like iOS.
    val brand = if (!isUnified && icon == null) providerBrandLogo(provider) else null
    Box(Modifier.size(size), contentAlignment = Alignment.BottomEnd) {
        Box(
            Modifier
                .size(size)
                .clip(CircleShape)
                .background(
                    when {
                        isUnified -> ThemePalette.unifiedLogoTile
                        brand != null -> Color.White
                        else -> ChannelColor.base(seed, order)
                    }
                )
                .border(if (selected) 2.dp else 0.5.dp, ringColor, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            when {
                isUnified -> UnifiedTurntable(selected, Modifier.size(size * 0.62f))
                icon != null -> Icon(SfIcon.vector(icon), label, tint = Color.White, modifier = Modifier.size(size * 0.4f))
                brand != null -> {
                    Image(
                        painter = painterResource(brand), contentDescription = label,
                        modifier = Modifier.fillMaxSize().padding(size * 0.16f),
                    )
                    if (avatarURL != null) AvatarRemotePhoto(avatarURL, label)
                }
                else -> {
                    // Tinted initial (fallback), with the remote photo layered on top.
                    Box(Modifier.fillMaxSize().background(ChannelColor.gradient(seed, order)), contentAlignment = Alignment.Center) {
                        Text(MailAddress.initials(label).take(1), color = Color.White,
                            style = AppFont.ui(1).copy(fontSize = (size.value * 0.32f).sp, fontWeight = FontWeight.SemiBold))
                    }
                    if (avatarURL != null) AvatarRemotePhoto(avatarURL, label)
                }
            }
        }
        if (online) Box(
            Modifier.size(size * 0.22f).clip(CircleShape).background(p.accentSuccess)
                .border(2.dp, p.bgBase, CircleShape)
        )
    }
}

/**
 * The unified-inbox brand mark as an animated turntable (iOS UnifiedBoxIcon): a 6×5 sprite
 * sheet (`inbox2-rotate-sheet.png`, the same one Tauri/web `UnifiedCubeIcon` and the launch
 * splash use) where frame 0 is the "2" facing front (resting) and the last frame is the cube
 * spun to the side. Selecting the inbox spins it forward; deselecting spins it back. Falls
 * back to the static cube if the sheet can't be sliced.
 */
@Composable
private fun UnifiedTurntable(selected: Boolean, modifier: Modifier = Modifier) {
    val ctx = LocalContext.current
    // Slice the sheet once and share it across recompositions/instances.
    val frames = remember {
        val sheet = android.graphics.BitmapFactory.decodeResource(ctx.resources, R.drawable.inbox2_rotate_sheet)
        if (sheet == null) emptyList()
        else {
            val cols = 6; val rows = 5
            val w = sheet.width / cols; val h = sheet.height / rows
            if (w <= 0 || h <= 0) emptyList()
            else buildList {
                for (r in 0 until rows) for (c in 0 until cols)
                    add(android.graphics.Bitmap.createBitmap(sheet, c * w, r * h, w, h).asImageBitmap())
            }
        }
    }
    if (frames.isEmpty()) {
        Image(painterResource(R.drawable.ch_unified), "Unified", modifier)
        return
    }
    // animateIntAsState seeds at the first target with no initial animation (primes the
    // pose), then spins forward/back through the frames when `selected` flips.
    val target = if (selected) frames.lastIndex else 0
    val idx by animateIntAsState(target, tween(360, easing = FastOutSlowInEasing), label = "turntable")
    Image(frames[idx.coerceIn(0, frames.lastIndex)], "Unified", modifier)
}

/** Maps an account's provider to its bundled brand logo (iOS ChannelAvatar.brandLogo). */
fun providerBrandLogo(provider: String?): Int? {
    val pv = (provider ?: return null).lowercase()
    return when {
        pv.contains("gmail") || pv.contains("google") -> R.drawable.ch_gmail
        pv.contains("micro") || pv.contains("office") || pv.contains("outlook") -> R.drawable.ch_microsoft
        pv.contains("whatsapp") -> R.drawable.ch_whatsapp
        pv.contains("messenger") -> R.drawable.ch_messenger
        pv.contains("instagram") -> R.drawable.ch_instagram
        pv.contains("imap") || pv.contains("smtp") -> R.drawable.ch_imap
        else -> null
    }
}

/** Remote/inline profile photo layered over an avatar tile (data: base64 or http via Coil). */
@Composable
private fun AvatarRemotePhoto(avatarURL: String, label: String?) {
    val inline = remember(avatarURL) {
        if (!avatarURL.startsWith("data:")) null
        else runCatching {
            val b64 = avatarURL.substringAfter("base64,", "")
            val bytes = android.util.Base64.decode(b64, android.util.Base64.DEFAULT)
            android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
        }.getOrNull()
    }
    if (inline != null) Image(
        bitmap = inline, contentDescription = label, contentScale = ContentScale.Crop,
        modifier = Modifier.fillMaxSize().clip(CircleShape),
    ) else AsyncImage(
        model = avatarURL, contentDescription = label, contentScale = ContentScale.Crop,
        modifier = Modifier.fillMaxSize().clip(CircleShape),
    )
}

/** The channel info needed to draw a [ChannelBadge] on a conversation row. */
data class ChannelBadgeInfo(
    val seed: String,
    val label: String,
    val order: List<String> = emptyList(),
    val avatarURL: String? = null,
    val provider: String? = null,
)

/**
 * A small channel mark for the bottom-right corner of a conversation row's avatar
 * — shown only in the unified inbox so pooled channels are distinguishable
 * (mirrors the channel chip: a ChannelColor circle with the account initial, or
 * the provider photo). A `bgBase` outer ring punches it out from the avatar
 * behind, like the online dot.
 */
@Composable
fun ChannelBadge(
    info: ChannelBadgeInfo,
    modifier: Modifier = Modifier,
    size: Dp = 18.dp,
) {
    val p = theme
    val brand = providerBrandLogo(info.provider)
    Box(
        modifier.size(size).clip(CircleShape).background(p.bgBase),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(size - 3.dp).clip(CircleShape)
                .background(if (brand != null) androidx.compose.ui.graphics.SolidColor(Color.White) else ChannelColor.gradient(info.seed, info.order)),
            contentAlignment = Alignment.Center,
        ) {
            if (brand != null) {
                Image(painter = painterResource(brand), contentDescription = info.label,
                    modifier = Modifier.fillMaxSize().padding(size * 0.16f))
            } else {
                Text(
                    MailAddress.initials(info.label).take(1), color = Color.White,
                    style = AppFont.ui(1).copy(fontSize = ((size.value - 3f) * 0.5f).sp, fontWeight = FontWeight.Bold),
                )
            }
            info.avatarURL?.let { AvatarRemotePhoto(it, null) }
        }
    }
}

/**
 * Short channel label from an email (iOS Channel.displayLabel): consumer providers show
 * the local part (alex501@gmail.com → alex501); custom domains show the registrable
 * name dropping the TLD (alex@example.com → example).
 */
fun channelDisplayLabel(email: String): String {
    val parts = email.split("@", limit = 2)
    if (parts.size != 2) return email
    val local = parts[0]
    val first = parts[1].lowercase().split(".").firstOrNull() ?: return local
    val providers = setOf(
        "gmail", "googlemail", "outlook", "hotmail", "live", "msn", "windowslive",
        "yahoo", "ymail", "rocketmail", "icloud", "me", "mac",
        "aol", "gmx", "proton", "protonmail", "pm", "yandex", "zoho", "mail",
    )
    return if (first in providers) local else first
}
