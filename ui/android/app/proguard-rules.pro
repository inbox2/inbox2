# UniFFI-generated bindings (uniffi.inbox2_core) reach the native library through
# JNA: Library interfaces, Structure fields, and Callback methods are all resolved
# reflectively, so nothing in either package may be renamed or stripped.
-keep class uniffi.** { *; }
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.Structure { *; }
-keep class * implements com.sun.jna.Callback { *; }
# JNA's desktop half references AWT/JAWT classes that don't exist on Android.
-dontwarn java.awt.**

# kotlinx.serialization: serializers for @Serializable classes are looked up via
# the generated companion; keep them for everything in the app.
-keepclassmembers @kotlinx.serialization.Serializable class com.inbox2.app.** {
    static **$Companion Companion;
}
-keepclasseswithmembers class com.inbox2.app.**$$serializer { *; }
-if @kotlinx.serialization.Serializable class **
-keepclassmembers class <1>$Companion {
    kotlinx.serialization.KSerializer serializer(...);
}

# Ktor's OkHttp engine is discovered via ServiceLoader.
-keep class io.ktor.client.engine.okhttp.OkHttpEngineContainer { *; }
-dontwarn org.slf4j.**

# MediaPipe tasks-genai loads its own JNI glue reflectively; protobuf-lite messages
# are reflection-parsed.
-keep class com.google.mediapipe.** { *; }
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite { <fields>; }

# tasks-genai compiles against MediaPipe's vision image classes and full-protobuf
# annotations that aren't on this app's classpath (we never feed it images).
-dontwarn com.google.mediapipe.framework.image.**
-dontwarn com.google.protobuf.Internal$ProtoMethodMayReturnNull
-dontwarn com.google.protobuf.Internal$ProtoNonnullApi
-dontwarn com.google.protobuf.ProtoField
-dontwarn com.google.protobuf.ProtoPresenceBits
-dontwarn com.google.protobuf.ProtoPresenceCheckedField
