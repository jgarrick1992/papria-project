@file:Suppress("DEPRECATION", "DEPRECATION_ERROR")

package com.papria.reader.ui

import androidx.compose.material.ripple.LocalRippleTheme
import androidx.compose.material.ripple.RippleAlpha
import androidx.compose.material.ripple.RippleTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.papria.reader.core.display.DisplayMode

/**
 * The Android implementation keeps the design-token names close to the
 * 0.1.0 specification.  Screen code reads this palette instead of relying on
 * Material defaults, which is especially important for the e-ink rendering.
 */
@Immutable
data class PapriaPalette(
    val canvas: Color,
    val raised: Color,
    val ink: Color,
    val secondaryInk: Color,
    val disabledInk: Color,
    val line: Color,
    val primaryAction: Color,
    val pressedAction: Color,
    val success: Color,
    val remote: Color,
    val warning: Color,
    val error: Color,
    val focus: Color,
    val isEink: Boolean,
)

private val NormalPalette = PapriaPalette(
    canvas = Color(0xFFF7F2E8),
    raised = Color(0xFFFFFCF6),
    ink = Color(0xFF20221F),
    secondaryInk = Color(0xFF6F6C63),
    disabledInk = Color(0xFF9B978D),
    line = Color(0xFFD8D0C3),
    primaryAction = Color(0xFFB74632),
    pressedAction = Color(0xFF8F3425),
    success = Color(0xFF2D7168),
    remote = Color(0xFF3D668B),
    warning = Color(0xFF9C661A),
    error = Color(0xFFB74632),
    focus = Color(0xFF3D668B),
    isEink = false,
)

private val EinkPalette = PapriaPalette(
    canvas = Color(0xFFFFFFFF),
    raised = Color(0xFFFFFFFF),
    ink = Color(0xFF000000),
    secondaryInk = Color(0xFF292929),
    disabledInk = Color(0xFF757575),
    line = Color(0xFFD5D5D5),
    primaryAction = Color(0xFF000000),
    pressedAction = Color(0xFF292929),
    success = Color(0xFF000000),
    remote = Color(0xFF292929),
    warning = Color(0xFF292929),
    error = Color(0xFF000000),
    focus = Color(0xFF000000),
    isEink = true,
)

val LocalPapriaPalette = staticCompositionLocalOf { NormalPalette }

private val PapriaTypography = Typography(
    headlineSmall = TextStyle(fontSize = 24.sp, lineHeight = 32.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.sp),
    titleLarge = TextStyle(fontSize = 17.sp, lineHeight = 24.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.sp),
    bodyLarge = TextStyle(fontSize = 16.sp, lineHeight = 24.sp, fontWeight = FontWeight.Normal, letterSpacing = 0.sp),
    bodyMedium = TextStyle(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Normal, letterSpacing = 0.sp),
    labelLarge = TextStyle(fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.sp),
    labelMedium = TextStyle(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.sp),
)

@Composable
fun PapriaTheme(displayMode: DisplayMode, content: @Composable () -> Unit) {
    val palette = if (displayMode == DisplayMode.EINK) EinkPalette else NormalPalette
    val colors = lightColorScheme(
        primary = palette.primaryAction,
        onPrimary = if (palette.isEink) Color.White else palette.raised,
        primaryContainer = if (palette.isEink) Color.White else Color(0xFFF3DDD8),
        onPrimaryContainer = palette.ink,
        secondary = palette.remote,
        onSecondary = palette.raised,
        background = palette.canvas,
        onBackground = palette.ink,
        surface = palette.raised,
        onSurface = palette.ink,
        surfaceVariant = palette.canvas,
        onSurfaceVariant = palette.secondaryInk,
        outline = palette.line,
        error = palette.error,
        onError = palette.raised,
    )
    val typography = if (palette.isEink) {
        PapriaTypography.copy(
            headlineSmall = PapriaTypography.headlineSmall.copy(fontSize = 22.sp, lineHeight = 30.sp, fontWeight = FontWeight.Bold),
            titleLarge = PapriaTypography.titleLarge.copy(fontSize = 18.sp, lineHeight = 25.sp, fontWeight = FontWeight.Bold),
            bodyLarge = PapriaTypography.bodyLarge.copy(fontSize = 17.sp, lineHeight = 25.sp, fontWeight = FontWeight.Medium),
            bodyMedium = PapriaTypography.bodyMedium.copy(fontSize = 14.sp, lineHeight = 20.sp),
            labelMedium = PapriaTypography.labelMedium.copy(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.SemiBold),
        )
    } else {
        PapriaTypography
    }

    if (palette.isEink) {
        CompositionLocalProvider(
            LocalPapriaPalette provides palette,
            LocalRippleTheme provides NoRippleTheme,
        ) {
            MaterialTheme(colorScheme = colors, typography = typography, content = content)
        }
    } else {
        CompositionLocalProvider(LocalPapriaPalette provides palette) {
            MaterialTheme(colorScheme = colors, typography = typography, content = content)
        }
    }
}

private object NoRippleTheme : RippleTheme {
    @Composable override fun defaultColor() = Color.Transparent
    @Composable override fun rippleAlpha(): RippleAlpha = RippleAlpha(0f, 0f, 0f, 0f)
}
