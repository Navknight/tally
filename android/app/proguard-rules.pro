# Flutter's engine looks these up reflectively; R8 cannot see the references.
-keep class io.flutter.** { *; }
-keep class com.navknight.tally.MainActivity { *; }
