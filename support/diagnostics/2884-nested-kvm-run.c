/* Execute one owned real-mode payload through the guest Linux KVM API.
 * The outer QEMU must use -accel kvm. This is no Windows or app result.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

static void fail(const char *stage) {
    fprintf(stderr, "2884_INNER_ERROR stage=%s errno=%d detail=%s\n", stage, errno, strerror(errno));
    exit(2);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    puts("scope=Linux_guest_inner_KVM_RUN; no_Windows_or_app=true");
    printf("probe_uid=%lu probe_euid=%lu\n", (unsigned long)getuid(), (unsigned long)geteuid());
    int kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (kvm < 0) fail("inner_open_kvm");
    int api = ioctl(kvm, KVM_GET_API_VERSION, 0);
    printf("inner_KVM_API=%d\n", api);
    if (api != KVM_API_VERSION) { puts("2884_INNER_ERROR stage=inner_api_version"); return 2; }
    int vm = ioctl(kvm, KVM_CREATE_VM, 0);
    if (vm < 0) fail("inner_create_vm");
    /* No in-kernel IRQCHIP: HLT must return to userspace, not wait for an
     * interrupt. This payload uses no interrupts or CPUID instruction.
     */
    const size_t memory_size = 1u << 20;
    uint8_t *memory = mmap(NULL, memory_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (memory == MAP_FAILED) fail("inner_allocate_memory");
    struct kvm_userspace_memory_region region = { .slot = 0, .guest_phys_addr = 0,
        .memory_size = memory_size, .userspace_addr = (uintptr_t)memory };
    if (ioctl(vm, KVM_SET_USER_MEMORY_REGION, &region) < 0) fail("inner_set_memory");
    const char expected[] = "2884_NESTED_KVM_RUN_OK";
    size_t code_offset = 0x1000;
    for (size_t i = 0; i < sizeof(expected) - 1; i++) {
        memory[code_offset++] = 0xb0; /* mov al, immediate */
        memory[code_offset++] = (uint8_t)expected[i];
        memory[code_offset++] = 0xe6; /* out immediate-port, al */
        memory[code_offset++] = 0xe9;
    }
    memory[code_offset] = 0xf4; /* hlt */
    int vcpu = ioctl(vm, KVM_CREATE_VCPU, 0);
    if (vcpu < 0) fail("inner_create_vcpu");
    struct kvm_sregs sregs;
    if (ioctl(vcpu, KVM_GET_SREGS, &sregs) < 0) fail("inner_get_sregs");
    sregs.cs.base = 0; sregs.cs.selector = 0;
    sregs.ds.base = 0; sregs.ds.selector = 0;
    sregs.es.base = 0; sregs.es.selector = 0;
    sregs.ss.base = 0; sregs.ss.selector = 0;
    if (ioctl(vcpu, KVM_SET_SREGS, &sregs) < 0) fail("inner_set_sregs");
    struct kvm_regs regs = { .rip = 0x1000, .rsp = 0x8000, .rflags = 2 };
    if (ioctl(vcpu, KVM_SET_REGS, &regs) < 0) fail("inner_set_regs");
    int run_size = ioctl(kvm, KVM_GET_VCPU_MMAP_SIZE, 0);
    if (run_size < 0) fail("inner_mmap_size");
    if (run_size < (int)sizeof(struct kvm_run)) {
        printf("2884_INNER_ERROR stage=inner_mmap_size_too_small size=%d\n", run_size); return 2;
    }
    struct kvm_run *run = mmap(NULL, (size_t)run_size, PROT_READ | PROT_WRITE, MAP_SHARED, vcpu, 0);
    if (run == MAP_FAILED) fail("inner_mmap_run");
    char observed[sizeof(expected)] = {0};
    size_t observed_size = 0;
    for (unsigned int attempt = 0; attempt < 256; attempt++) {
        if (ioctl(vcpu, KVM_RUN, 0) < 0) {
            if (errno == EINTR) continue;
            fail("inner_run");
        }
        printf("inner_exit_reason=%u\n", run->exit_reason);
        if (run->exit_reason == KVM_EXIT_IO) {
            if (run->io.direction != KVM_EXIT_IO_OUT || run->io.port != 0xe9 || run->io.size != 1 ||
                run->io.data_offset > (uint64_t)run_size || run->io.count > (uint64_t)run_size - run->io.data_offset ||
                run->io.count > sizeof(expected) - 1 - observed_size) {
                puts("2884_INNER_ERROR stage=inner_unexpected_io"); return 3;
            }
            memcpy(observed + observed_size, (uint8_t *)run + run->io.data_offset, run->io.count);
            observed_size += run->io.count;
        } else if (run->exit_reason == KVM_EXIT_HLT) {
            if (observed_size != sizeof(expected) - 1 || memcmp(observed, expected, sizeof(expected) - 1) != 0) {
                puts("2884_INNER_ERROR stage=inner_marker_mismatch"); return 3;
            }
            printf("inner_observed_payload=%s\n", observed);
            puts("2884_INNER_RESULT=PASS; KVM_RUN_IO_and_HLT_observed=true");
            munmap(run, (size_t)run_size); munmap(memory, memory_size);
            close(vcpu); close(vm); close(kvm);
            return 0;
        } else {
            if (run->exit_reason == KVM_EXIT_FAIL_ENTRY)
                printf("inner_hardware_entry_failure=0x%llx\n", (unsigned long long)run->fail_entry.hardware_entry_failure_reason);
            puts("2884_INNER_ERROR stage=inner_unexpected_exit"); return 3;
        }
    }
    puts("2884_INNER_ERROR stage=inner_exit_budget");
    return 3;
}
