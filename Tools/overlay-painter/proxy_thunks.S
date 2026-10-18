/* Microsoft x64 tail forwarding. Stack arguments (including Valve extensions) remain intact. */
.text
.macro save_args
 subq $200, %rsp
 .seh_stackalloc 200
 .seh_endprologue
 movq %rcx,32(%rsp)
 movq %rdx,40(%rsp)
 movq %r8,48(%rsp)
 movq %r9,56(%rsp)
 movdqu %xmm0,64(%rsp)
 movdqu %xmm1,80(%rsp)
 movdqu %xmm2,96(%rsp)
 movdqu %xmm3,112(%rsp)
.endm
.macro restore_args
 movq 32(%rsp),%rcx
 movq 40(%rsp),%rdx
 movq 48(%rsp),%r8
 movq 56(%rsp),%r9
 movdqu 64(%rsp),%xmm0
 movdqu 80(%rsp),%xmm1
 movdqu 96(%rsp),%xmm2
 movdqu 112(%rsp),%xmm3
 addq $200,%rsp
 jmp *%rax
.endm
.globl sevo_create_browser_thunk
.seh_proc sevo_create_browser_thunk
sevo_create_browser_thunk:
 save_args
 xorq %rcx,%rcx
 call sevo_create_target
 restore_args
.seh_endproc
.globl sevo_create_browser_sync_thunk
.seh_proc sevo_create_browser_sync_thunk
sevo_create_browser_sync_thunk:
 save_args
 movq $1,%rcx
 call sevo_create_target
 restore_args
.seh_endproc
.globl sevo_accelerated_thunk
.seh_proc sevo_accelerated_thunk
sevo_accelerated_thunk:
 save_args
 call sevo_before_accelerated
 restore_args
.seh_endproc
