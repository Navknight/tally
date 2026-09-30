# Flutter's engine looks these up reflectively; R8 cannot see the references.
-keep class io.flutter.** { *; }
-keep class com.navknight.tally.MainActivity { *; }

# Flutter's engine references Play Core's deferred-component classes, which
# are not on the classpath unless the app uses deferred components. R8 treats
# the dangling references as errors and fails the release build.
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }
