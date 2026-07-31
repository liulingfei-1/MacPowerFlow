// smc.h
#ifndef SMC_H
#define SMC_H

#include <IOKit/IOKitLib.h>
#include <stdint.h>

#define KERNEL_INDEX_SMC 2

#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9
#define SMC_CMD_READ_PLIMIT 11
#define SMC_CMD_READ_VERS 12

typedef struct {
  char major;
  char minor;
  char build;
  char reserved[1];
  unsigned short release;
} SMCKeyData_vers_t;

typedef struct {
  unsigned short version;
  unsigned short length;
  unsigned int cpuPLimit;
  unsigned int gpuPLimit;
  unsigned int memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
  unsigned int dataSize;
  unsigned int dataType;
  char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef char SMCBytes_t[32];

typedef struct {
  unsigned int key;
  SMCKeyData_vers_t vers;
  SMCKeyData_pLimitData_t pLimitData;
  SMCKeyData_keyInfo_t keyInfo;
  char result;
  char status;
  char data8;
  unsigned int data32;
  SMCBytes_t bytes;
} SMCKeyData_t;

typedef char SMCKey_t[5];

typedef struct {
  char key[4];
  SMCKeyData_t data;
} SMCVal_t;

/// A decoded numeric SMC value together with the firmware type metadata used
/// to decode it. Callers must still validate the semantic meaning of `key`;
/// this type deliberately does not infer a sensor name from an unknown FourCC.
typedef struct {
  double value;
  uint32_t dataType;
  uint32_t dataSize;
} SMCNumericValue_t;

// Function prototypes
io_connect_t SMCOpen(void);
kern_return_t SMCClose(io_connect_t conn);
kern_return_t SMCReadKey(io_connect_t conn, const char *key, SMCKeyData_t *val);
/// Decodes only known numeric SMC data types. Returns kIOReturnUnsupported for
/// an otherwise readable key whose data type is not numeric/recognized.
kern_return_t SMCReadNumericValue(io_connect_t conn, const char *key,
                                  SMCNumericValue_t *value);
double SMCGetFloatValue(io_connect_t conn, const char *key);
int SMCDataTypeIsNumeric(uint32_t dataType);
int SMCGetKeyCount(io_connect_t conn);
kern_return_t SMCGetKeyFromIndex(io_connect_t conn, int index, char *outputKey);
kern_return_t SMCGetKeyInfo(io_connect_t conn, const char *key,
                            SMCKeyData_keyInfo_t *keyInfo);

#endif
