#!/usr/bin/env python3
"""K14: make AdrenoMetal's frontend build for x86_64 macOS.
1. The newest commit (f6f3808, diagnostics only) left code outside its functions; the build takes the file of the commit
   before it (beeab71), which the caller writes to argv[1].
2. The abort probe reads arm64 registers; on x86_64 it keeps only the frame walk (rbp)."""
import sys
p = sys.argv[1]
s = open(p).read()
a = " const __darwin_arm_thread_state64 &ss = ((ucontext_t *)context)->uc_mcontext->__ss;\n"
assert s.count(a) == 1, "abort probe register dump not found"
s = s.replace(a, "#if defined(__arm64__)\n" + a)
b = ' at = line;\n at = probeText(at, "native-metal abort probe: stack guard now ");'
assert s.count(b) == 1, "stack guard line not found"
s = s.replace(b, "#endif\n" + b)
c = " uint64_t fp = __darwin_arm_thread_state64_get_fp(((ucontext_t *)context)->uc_mcontext->__ss);\n"
assert s.count(c) == 1, "frame pointer line not found"
s = s.replace(c, "#if defined(__arm64__)\n" + c + "#else\n uint64_t fp = ((ucontext_t *)context)->uc_mcontext->__ss.__rbp;\n#endif\n")
open(p, "w").write(s)
print("frontend fixed for x86_64")
