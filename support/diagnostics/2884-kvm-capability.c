/* Read KVM's advertised guest VMX/EPT or SVM/NPT capability without executing guest code.
 * This is a preparation gate, not a nested Hyper-V, Windows, or app result.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static void fail(const char *operation) {
    fprintf(stderr, "%s: %s (errno=%d)\n", operation, strerror(errno), errno);
    exit(2);
}

static int read_msr(int vcpu, uint32_t index, uint64_t *value) {
    struct kvm_msrs *request = calloc(1, sizeof(*request) + sizeof(struct kvm_msr_entry));
    if (!request) fail("calloc msr");
    request->nmsrs = 1;
    request->entries[0].index = index;
    int result = ioctl(vcpu, KVM_GET_MSRS, request);
    int saved_errno = errno;
    printf("KVM_GET_MSRS index=0x%x result=%d", index, result);
    if (result == 1) {
        *value = request->entries[0].data;
        printf(" value=0x%016llx\n", (unsigned long long)*value);
    } else {
        printf(" errno=%d\n", result < 0 ? saved_errno : 0);
    }
    free(request);
    return result == 1;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    puts("scope=host_and_advertised_guest_capability; guest_code_executed=false; no_OS_install=true");
    printf("probe_uid=%lu probe_euid=%lu\n", (unsigned long)getuid(), (unsigned long)geteuid());
    int kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (kvm < 0) {
        int denied = errno == EACCES;
        fprintf(stderr, "open /dev/kvm: %s (errno=%d)\n", strerror(errno), errno);
        return denied ? 4 : 2;
    }
    int api = ioctl(kvm, KVM_GET_API_VERSION, 0);
    printf("KVM_GET_API_VERSION=%d expected=%d\n", api, KVM_API_VERSION);
    if (api != KVM_API_VERSION) return 2;
    int nested_state = ioctl(kvm, KVM_CHECK_EXTENSION, KVM_CAP_NESTED_STATE);
    printf("KVM_CAP_NESTED_STATE=%d (state ioctl support only)\n", nested_state);

    const uint32_t capacity = 512;
    struct kvm_cpuid2 *cpuid = calloc(1, sizeof(*cpuid) + capacity * sizeof(struct kvm_cpuid_entry2));
    if (!cpuid) fail("calloc cpuid");
    cpuid->nent = capacity;
    if (ioctl(kvm, KVM_GET_SUPPORTED_CPUID, cpuid) < 0) fail("KVM_GET_SUPPORTED_CPUID");
    int vmx = 0;
    int svm = 0, npt = 0;
    for (uint32_t i = 0; i < cpuid->nent; i++) {
        const struct kvm_cpuid_entry2 *entry = &cpuid->entries[i];
        if (entry->function == 1 && entry->index == 0) {
            vmx = (entry->ecx & (1u << 5)) != 0;
            printf("guest_cpuid_1_ecx=0x%08x guest_vmx=%d\n", entry->ecx, vmx);
        }
        /* Linux v6.17 cpufeatures.h: word 6 is CPUID 0x80000001 ECX;
         * word 15 is CPUID 0x8000000a EDX. SVM is bit 2, NPT is bit 0.
         * These are KVM-supported guest bits, not host lscpu flags.
         */
        if (entry->function == 0x80000001 && entry->index == 0) {
            svm = (entry->ecx & (1u << 2)) != 0;
            printf("guest_cpuid_80000001_ecx=0x%08x guest_svm=%d\n", entry->ecx, svm);
        }
        if (entry->function == 0x8000000a && entry->index == 0) {
            npt = (entry->edx & 1u) != 0;
            printf("guest_cpuid_8000000a_edx=0x%08x guest_npt=%d\n", entry->edx, npt);
        }
    }
    int vm = ioctl(kvm, KVM_CREATE_VM, 0);
    if (vm < 0) fail("KVM_CREATE_VM");
    /* Supported CPUID can include x2APIC/TSC deadline/PV_UNHALT features
     * that require an in-kernel LAPIC. Create it before applying CPUID.
     */
    if (ioctl(vm, KVM_CREATE_IRQCHIP, 0) < 0) fail("KVM_CREATE_IRQCHIP");
    int vcpu = ioctl(vm, KVM_CREATE_VCPU, 0);
    if (vcpu < 0) fail("KVM_CREATE_VCPU");
    if (ioctl(vcpu, KVM_SET_CPUID2, cpuid) < 0) fail("KVM_SET_CPUID2");
    free(cpuid);
    uint64_t basic = 0, secondary = 0, ept = 0;
    int basic_read = vmx && read_msr(vcpu, 0x480, &basic);
    int secondary_read = vmx && read_msr(vcpu, 0x48b, &secondary);
    int ept_read = vmx && read_msr(vcpu, 0x48c, &ept);
    int ept_allowed = secondary_read && ((secondary >> 32) & (1u << 1));
    int ept_four_level = ept_read && (ept & (1ull << 6));
    printf("guest_vmx_basic_read=%d guest_ept_allowed=%d guest_ept_4level=%d\n", basic_read, ept_allowed, ept_four_level);
    puts("limitation=KVM advertised features and vCPU creation do not prove a nested guest executes, Hyper-V starts, or WSL2/Docker works");
    close(vcpu);
    close(vm);
    close(kvm);
    int intel_admitted = nested_state > 0 && vmx && basic_read && ept_allowed && ept_four_level;
    int amd_admitted = nested_state > 0 && svm && npt;
    printf("advertised_intel_nested_gate=%s\n", intel_admitted ? "PASS" : "UNAVAILABLE");
    printf("advertised_amd_nested_gate=%s\n", amd_admitted ? "PASS" : "UNAVAILABLE");
    int admitted = intel_admitted || amd_admitted;
    return admitted ? 0 : 3;
}
