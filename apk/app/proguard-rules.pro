# Compose and Kotlin metadata are handled by the AGP defaults. Nothing custom is needed
# for this app: it has no reflection, no serialization library and no JNI.
#
# Keep the class names in stack traces readable until the app is out of its first
# release cycle.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
