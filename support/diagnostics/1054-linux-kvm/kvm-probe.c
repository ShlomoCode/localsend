/* Admission only, adapted from issue 2884's actual KVM API/setup probe.
 * No guest code, nested virtualization, Windows or application result. */
#include <errno.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static int failed(const char *operation) {
    fprintf(stderr, "%s: %s (errno=%d)\n", operation, strerror(errno), errno);
    return 2;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    puts("scope=host_KVM_admission; guest_code_executed=false");
    printf("probe_uid=%lu probe_euid=%lu\n", (unsigned long)getuid(), (unsigned long)geteuid());
    int kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (kvm < 0) {
        int denied = errno == EACCES;
        failed("open /dev/kvm");
        return denied ? 4 : 2;
    }
    int api = ioctl(kvm, KVM_GET_API_VERSION, 0);
    printf("KVM_GET_API_VERSION=%d expected=%d\n", api, KVM_API_VERSION);
    if (api != KVM_API_VERSION) { close(kvm); return 2; }
    int vm = ioctl(kvm, KVM_CREATE_VM, 0);
    if (vm < 0) { close(kvm); return failed("KVM_CREATE_VM"); }
    if (ioctl(vm, KVM_CREATE_IRQCHIP, 0) < 0) {
        close(vm); close(kvm); return failed("KVM_CREATE_IRQCHIP");
    }
    int vcpu = ioctl(vm, KVM_CREATE_VCPU, 0);
    if (vcpu < 0) { close(vm); close(kvm); return failed("KVM_CREATE_VCPU"); }
    puts("KVM_CREATE_VM=PASS; KVM_CREATE_IRQCHIP=PASS; KVM_CREATE_VCPU=PASS");
    close(vcpu); close(vm); close(kvm);
    puts("KVM_HOST_ADMISSION=PASS; Windows_and_app_unverified=true");
    return 0;
}
