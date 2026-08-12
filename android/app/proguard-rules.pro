# Keep the generated UniFFI/JNA surface available in every app variant.
-keep class uniffi.papria_format_core.** { *; }
-keep class com.sun.jna.** { *; }

# JNA ships a desktop AWT helper that is not part of the Android runtime and
# is not used by the UniFFI loader. Suppress only those platform-absent classes
# so R8 can verify the actual Android native-core path.
-dontwarn java.awt.**
