#if defined(__APPLE__) && defined(THRESHOLD_PGO_INSTRUMENTED)
extern int __llvm_profile_write_file(void);

int ThresholdLLVMProfileIsInstrumented(void) {
    return 1;
}

int ThresholdLLVMProfileWriteFile(void) {
    return __llvm_profile_write_file();
}
#else
int ThresholdLLVMProfileIsInstrumented(void) {
    return 0;
}

int ThresholdLLVMProfileWriteFile(void) {
    return -1;
}
#endif
