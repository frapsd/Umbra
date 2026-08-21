/*
 * umbra-led — turns the Mac's status LED off and back on, via SMC.
 *
 * Runs as root through a sudoers rule restricted to this exact path and this
 * exact set of arguments. It therefore takes NO key names from the caller: the
 * three SMC keys below are compiled in, and argv can only select which of them
 * to poke. Anything else exits non-zero without touching the SMC.
 *
 * Key attributes, read from the SMC key table on a Mac mini M2 (Mac14,3):
 *
 *   LSOF  flag  attr 0x80  read-only    the override status
 *   LSOO  flag  attr 0x50  write+func   the command; not readable by design
 *   LSRB  flag  attr 0x50  write+func   hands the LED back to the firmware
 *
 * That is why this writes one key and reads a different one back.
 *
 * The firmware still owns the LED and reclaims it across sleep and reboot, so
 * a caller that wants the LED to stay off has to reapply after wake.
 *
 *   clang -O2 -framework IOKit -o umbra-led Tools/umbra-led.c
 *   ./umbra-led status          # no root needed
 *   sudo ./umbra-led off|on|revert
 */

#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_KEY 6
#define SMC_CMD_READ_KEYINFO 9

typedef struct { char major, minor, build, reserved[1]; uint16_t release; } SMCKeyData_vers_t;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCKeyData_pLimitData_t;
typedef struct { uint32_t dataSize, dataType; char dataAttributes; } SMCKeyData_keyInfo_t;
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

/* Compiled-in, never taken from argv. */
static const char *const KEY_STATUS = "LSOF";
static const char *const KEY_SET    = "LSOO";
static const char *const KEY_REVERT = "LSRB";

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

static int read_flag(const char *name, uint8_t *value) {
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
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;

    if (value) *value = (uint8_t)out.bytes[0];
    return 0;
}

static int write_flag(const char *name, uint8_t value) {
    SMCKeyData_t in, info, out;
    memset(&in, 0, sizeof(in));
    in.key = fourcc(name);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &info) != KERN_SUCCESS) return -1;

    memset(&in, 0, sizeof(in));
    in.key = fourcc(name);
    in.data8 = SMC_CMD_WRITE_KEY;
    in.keyInfo.dataSize = info.keyInfo.dataSize ? info.keyInfo.dataSize : 1;
    in.keyInfo.dataType = info.keyInfo.dataType;
    in.bytes[0] = (char)value;

    kern_return_t kr = smc_call(&in, &out);
    return (kr == KERN_SUCCESS && out.result == 0) ? 0 : -1;
}

/* One machine-readable line, so the app can parse it without guessing. */
static void print_status(void) {
    uint8_t flag = 0;
    if (read_flag(KEY_STATUS, &flag) == 0)
        printf("led=%s\n", flag ? "off" : "on");
    else
        printf("led=unknown\n");
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: umbra-led status|off|on|revert\n");
        return 64;
    }
    const char *cmd = argv[1];
    int is_status = strcmp(cmd, "status") == 0;
    int is_off    = strcmp(cmd, "off") == 0;
    int is_on     = strcmp(cmd, "on") == 0;
    int is_revert = strcmp(cmd, "revert") == 0;
    if (!is_status && !is_off && !is_on && !is_revert) {
        fprintf(stderr, "usage: umbra-led status|off|on|revert\n");
        return 64;
    }

    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("AppleSMCKeysEndpoint"));
    if (!service) { fprintf(stderr, "no AppleSMCKeysEndpoint\n"); return 1; }

    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) { fprintf(stderr, "IOServiceOpen 0x%x\n", kr); return 1; }

    int rc = 0;
    if (is_status) {
        print_status();
    } else if (is_revert) {
        rc = write_flag(KEY_REVERT, 1);
        usleep(200000);
        print_status();
    } else {
        rc = write_flag(KEY_SET, is_off ? 0 : 1);
        usleep(200000);
        print_status();
    }

    IOServiceClose(conn);
    return rc == 0 ? 0 : 2;
}
