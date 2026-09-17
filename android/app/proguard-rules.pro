# StylePOS R8 rules.
#
# mobile_scanner (7.x) ships consumer rules that keep ML Kit / CameraX /
# barhopper classes, and the Flutter Gradle plugin injects the engine and
# plugin-registration keep rules automatically. Only generic rules are
# needed here.

# Keep line numbers + source file names so Java/Kotlin stack traces stay
# readable. Dart symbols are stripped separately via --split-debug-info.
-keepattributes SourceFile,LineNumberTable

# Silence harmless references R8 encounters while shrinking plugin deps.
-dontwarn org.slf4j.**
-dontwarn javax.annotation.**
-dontwarn java.lang.invoke.StringConcatFactory
