/*
 * Mac mini status LED (SIL) via SMC keys LSOO / LSOF / LSRB.
 *
 * Proven on Mac mini M2 (Mac14,3): LSOO=0 turns the front LED off,
 * LSOO=1 turns it back on. Writes need root; reads do not.
 * This is an OS override — the SMC firmware still owns the LED and
 * may reclaim it on sleep, reboot, or the power button. LSRB hands
 * it back explicitly.
 *
 *   clang -O2 -framework IOKit -o /tmp/smc-led Tools/smc-led.c
 *   /tmp/smc-led status
 *   sudo /tmp/smc-led off
 *   sudo /tmp/smc-led on
 *   sudo /tmp/smc-led revert
 *
 * Not wired into Umbra yet.
 */

#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_KEY 6
#define SMC_CMD_READ_KEYINFO 9

typedef struct {
    char major, minor, build, reserved[1];
    uint16_t release;
} SMCKeyData_vers_t;
typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCKeyData_pLimitData_t;
typedef struct {
    uint32_t dataSize, dataType;
    char dataAttributes;
} SMCKeyData_keyInfo_t;
typedef char SMCBytes_t[32];
typedef struct {
    uint32_t key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result, status, data8;
    uint32_t data32;
    SMCBytes_t bytes;
} SMCKeyData_t;

static io_connect_t conn;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8) | (uint32_t)(uint8_t)s[3];
}

static kern_return_t smc_call(SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t outSize = sizeof(*out);
    memset(out, 0, sizeof(*out));
    return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(*in), out, &outSize);
}

static int read_byte(const char *name, uint8_t *byte, uint8_t *smc_result) {
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    in.key = fourcc(name);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != KERN_SUCCESS) return -1;
    uint32_t size = out.keyInfo.dataSize ? out.keyInfo.dataSize : 1;
    memset(&in, 0, sizeof(in));
    in.key = fourcc(name);
    in.keyInfo.dataSize = size;
    in.data8 = SMC_CMD_READ_BYTES;
    kern_return_t kr = smc_call(&in, &out);
    if (smc_result) *smc_result = (uint8_t)out.result;
    if (kr != KERN_SUCCESS) return -1;
    if (byte) *byte = (uint8_t)out.bytes[0];
    return 0;
}

static int write_flag(const char *name, uint8_t value) {
    SMCKeyData_t in, info, out;
    memset(&in, 0, sizeof(in));
    in.key = fourcc(name);
    in.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t kr = smc_call(&in, &info);
    if (kr != KERN_SUCCESS) {
        printf("KEYINFO %s kr=0x%x\n", name, kr);
        return -1;
    }
    memset(&in, 0, sizeof(in));
    in.key = fourcc(name);
    in.data8 = SMC_CMD_WRITE_KEY;
    in.keyInfo.dataSize = info.keyInfo.dataSize ? info.keyInfo.dataSize : 1;
    in.keyInfo.dataType = info.keyInfo.dataType;
    in.bytes[0] = (char)value;
    kr = smc_call(&in, &out);
    printf("WRITE %s=%u kr=0x%x smc_result=0x%02x\n",
           name, value, kr, (uint8_t)out.result);
    return (kr == KERN_SUCCESS && out.result == 0) ? 0 : -1;
}

static void print_status(void) {
    uint8_t lsof = 0xff, res = 0;
    int ok = read_byte("LSOF", &lsof, &res);
    if (ok == 0)
        printf("LSOF=%u (0=acceso 1=spento) smc_result=0x%02x\n", lsof, res);
    else
        printf("LSOF unreadable\n");
}

int main(int argc, char **argv) {
    const char *cmd = argc > 1 ? argv[1] : "status";
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("AppleSMCKeysEndpoint"));
    if (!svc) { fprintf(stderr, "no AppleSMCKeysEndpoint\n"); return 1; }
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) { fprintf(stderr, "open 0x%x\n", kr); return 1; }

    if (strcmp(cmd, "status") == 0) {
        print_status();
    } else if (strcmp(cmd, "off") == 0) {
        print_status();
        int rc = write_flag("LSOO", 0);
        usleep(300000);
        print_status();
        IOServiceClose(conn);
        return rc == 0 ? 0 : 2;
    } else if (strcmp(cmd, "on") == 0) {
        int rc = write_flag("LSOO", 1);
        usleep(300000);
        print_status();
        IOServiceClose(conn);
        return rc == 0 ? 0 : 2;
    } else if (strcmp(cmd, "revert") == 0) {
        int rc = write_flag("LSRB", 1);
        usleep(300000);
        print_status();
        IOServiceClose(conn);
        return rc == 0 ? 0 : 2;
    } else {
        fprintf(stderr, "usage: %s status|off|on|revert\n", argv[0]);
        IOServiceClose(conn);
        return 1;
    }
    IOServiceClose(conn);
    return 0;
}
