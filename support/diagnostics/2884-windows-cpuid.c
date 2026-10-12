#include <stdio.h>

#if defined(__GNUC__) && defined(__x86_64__) && defined(_WIN64)
#include <cpuid.h>

typedef struct {
    unsigned int leaf;
    unsigned int eax;
    unsigned int ebx;
    unsigned int ecx;
    unsigned int edx;
} RawLeaf;

static RawLeaf read_leaf(unsigned int leaf)
{
    RawLeaf result;
    result.leaf = leaf;
    __cpuid_count(leaf, 0, result.eax, result.ebx, result.ecx, result.edx);
    return result;
}

static void vendor_word(unsigned char *bytes, unsigned int word)
{
    unsigned int i;
    for (i = 0; i < 4; ++i) {
        bytes[i] = (unsigned char)(word >> (8 * i));
    }
}

static void print_vendor(const unsigned char *bytes)
{
    unsigned int i;
    putchar('"');
    for (i = 0; i < 12; ++i) {
        unsigned int byte = bytes[i];
        if (byte == '"' || byte == '\\') {
            putchar('\\');
            putchar((int)byte);
        } else if (byte < 0x20 || byte >= 0x7f) {
            printf("\\u%04x", byte);
        } else {
            putchar((int)byte);
        }
    }
    putchar('"');
}

static const char *json_bool(int value)
{
    return value ? "true" : "false";
}

int main(void)
{
    RawLeaf raw[10];
    unsigned int count = 0;
    unsigned int i;
    unsigned int max_basic;
    unsigned int max_extended;
    unsigned int max_hypervisor = 0;
    unsigned int eax, ebx, ecx, edx;
    unsigned char cpu_vendor[12];
    unsigned char hypervisor_vendor[12];
    RawLeaf svm_spec = {0, 0, 0, 0, 0};
    int vmx = 0;
    int hypervisor = 0;
    int svm = 0;
    int npt = 0;
    int has_svm_spec = 0;
    int has_hypervisor_vendor = 0;

    if (!__get_cpuid(0, &eax, &ebx, &ecx, &edx)) {
        puts("{\"schemaVersion\":1,\"cpuidAvailable\":false,\"error\":\"cpuid-unavailable\"}");
        return 1;
    }
    raw[count++] = (RawLeaf){0, eax, ebx, ecx, edx};
    max_basic = eax;
    vendor_word(cpu_vendor, ebx);
    vendor_word(cpu_vendor + 4, edx);
    vendor_word(cpu_vendor + 8, ecx);

    if (max_basic >= 1) {
        RawLeaf features = read_leaf(1);
        raw[count++] = features;
        vmx = (features.ecx & (1u << 5)) != 0;
        hypervisor = (features.ecx & (1u << 31)) != 0;
    }
    if (max_basic >= 7) {
        raw[count++] = read_leaf(7);
    }

    raw[count++] = read_leaf(0x80000000u);
    max_extended = raw[count - 1].eax;
    if (max_extended >= 0x80000001u && max_extended <= 0x8fffffffu) {
        RawLeaf features = read_leaf(0x80000001u);
        raw[count++] = features;
        svm = (features.ecx & (1u << 2)) != 0;
    }
    if (max_extended >= 0x8000000au && max_extended <= 0x8fffffffu) {
        svm_spec = read_leaf(0x8000000au);
        raw[count++] = svm_spec;
        has_svm_spec = 1;
        npt = (svm_spec.edx & 1u) != 0;
    }

    if (hypervisor) {
        RawLeaf root = read_leaf(0x40000000u);
        raw[count++] = root;
        max_hypervisor = root.eax;
        /* Only interpret the advertised base hypervisor leaf range. */
        if (max_hypervisor >= 0x40000000u && max_hypervisor <= 0x4000ffffu) {
            vendor_word(hypervisor_vendor, root.ebx);
            vendor_word(hypervisor_vendor + 4, root.ecx);
            vendor_word(hypervisor_vendor + 8, root.edx);
            has_hypervisor_vendor = 1;
            if (max_hypervisor >= 0x40000001u) {
                raw[count++] = read_leaf(0x40000001u);
            }
            if (max_hypervisor >= 0x40000003u) {
                raw[count++] = read_leaf(0x40000003u);
            }
            if (max_hypervisor >= 0x4000000au) {
                raw[count++] = read_leaf(0x4000000au);
            }
        }
    }

    printf("{\"schemaVersion\":1,\"cpuidAvailable\":true,\"cpuVendor\":");
    print_vendor(cpu_vendor);
    printf(",\"hypervisorVendor\":");
    if (has_hypervisor_vendor) {
        print_vendor(hypervisor_vendor);
    } else {
        printf("null");
    }
    printf(",\"flags\":{\"svm\":%s,\"npt\":%s,\"vmx\":%s,\"hypervisor\":%s},\"svmSpec\":",
           json_bool(svm), json_bool(npt), json_bool(vmx), json_bool(hypervisor));
    if (has_svm_spec) {
        printf("{\"revision\":%u,\"asidCount\":%u,\"featuresRaw\":\"0x%08x\"}",
               svm_spec.eax & 0xffu, svm_spec.ebx, svm_spec.edx);
    } else {
        printf("null");
    }
    printf(",\"rawLeaves\":[");
    for (i = 0; i < count; ++i) {
        RawLeaf leaf = raw[i];
        printf("%s{\"leaf\":\"0x%08x\",\"subleaf\":0,\"eax\":\"0x%08x\","
               "\"ebx\":\"0x%08x\",\"ecx\":\"0x%08x\",\"edx\":\"0x%08x\"}",
               i ? "," : "", leaf.leaf, leaf.eax, leaf.ebx, leaf.ecx, leaf.edx);
    }
    puts("]}");
    if (fflush(stdout) == EOF || ferror(stdout)) {
        return 1;
    }
    return 0;
}
#else
int main(void)
{
    puts("{\"schemaVersion\":1,\"cpuidAvailable\":false,\"error\":\"requires-gcc-windows-x64\"}");
    return 1;
}
#endif
