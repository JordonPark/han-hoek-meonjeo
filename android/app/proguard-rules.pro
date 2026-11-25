# Room constructs this WorkManager database through its no-argument constructor.
-keep class androidx.work.impl.WorkDatabase_Impl {
    public <init>();
}

# ONNX Runtime JNI looks up Java classes and members by their original names.
-keep class ai.onnxruntime.** { *; }
