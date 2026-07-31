// smc.c
#include "SMC.h"
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#define SMC_RESULT_SUCCESS 0x00
#define SMC_RESULT_KEY_NOT_FOUND 0x84

#define SMC_FOURCC(a, b, c, d)                                                  \
  (((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | ((uint32_t)(c) << 8) |       \
   (uint32_t)(d))

#define SMC_TYPE_FLT SMC_FOURCC('f', 'l', 't', ' ')
#define SMC_TYPE_IOF SMC_FOURCC('i', 'o', 'f', ' ')
#define SMC_TYPE_IOFT SMC_FOURCC('i', 'o', 'f', 't')
#define SMC_TYPE_UI8 SMC_FOURCC('u', 'i', '8', ' ')
#define SMC_TYPE_UI16 SMC_FOURCC('u', 'i', '1', '6')
#define SMC_TYPE_UI32 SMC_FOURCC('u', 'i', '3', '2')
#define SMC_TYPE_SI8 SMC_FOURCC('s', 'i', '8', ' ')
#define SMC_TYPE_SI16 SMC_FOURCC('s', 'i', '1', '6')
#define SMC_TYPE_SI32 SMC_FOURCC('s', 'i', '3', '2')

static int SMCHexDigit(unsigned char value) {
  if (value >= '0' && value <= '9') {
    return value - '0';
  }
  if (value >= 'a' && value <= 'f') {
    return value - 'a' + 10;
  }
  if (value >= 'A' && value <= 'F') {
    return value - 'A' + 10;
  }
  return -1;
}

/// Returns the fractional bit count for the SMC `fpXY` / `spXY` families.
/// The X digit describes integer bits and Y describes fractional bits; power
/// rails such as PDTR are commonly `fpa6`, while temperatures are often `sp78`.
static int SMCFixedPointFractionBits(uint32_t dataType, int *isSigned) {
  unsigned char first = (unsigned char)(dataType >> 24);
  unsigned char second = (unsigned char)(dataType >> 16);
  if ((first != 'f' && first != 's') || second != 'p') {
    return -1;
  }

  int integerBits = SMCHexDigit((unsigned char)(dataType >> 8));
  int fractionBits = SMCHexDigit((unsigned char)dataType);
  int payloadBits = first == 's' ? 15 : 16;
  if (integerBits < 0 || fractionBits < 0 ||
      integerBits + fractionBits > payloadBits) {
    return -1;
  }
  if (isSigned != NULL) {
    *isSigned = first == 's';
  }
  return fractionBits;
}

static uint64_t SMCReadUnsignedBigEndian(const char *bytes, uint32_t size) {
  uint64_t value = 0;
  uint32_t count = size > 8 ? 8 : size;
  for (uint32_t index = 0; index < count; index++) {
    value = (value << 8) | (unsigned char)bytes[index];
  }
  return value;
}

static uint64_t SMCReadUnsignedLittleEndian(const char *bytes, uint32_t size) {
  uint64_t value = 0;
  uint32_t count = size > 8 ? 8 : size;
  for (uint32_t index = 0; index < count; index++) {
    value |= (uint64_t)(unsigned char)bytes[index] << (index * 8);
  }
  return value;
}

int SMCDataTypeIsNumeric(uint32_t dataType) {
  if (dataType == SMC_TYPE_FLT || dataType == SMC_TYPE_IOF ||
      dataType == SMC_TYPE_IOFT || dataType == SMC_TYPE_UI8 ||
      dataType == SMC_TYPE_UI16 || dataType == SMC_TYPE_UI32 ||
      dataType == SMC_TYPE_SI8 || dataType == SMC_TYPE_SI16 ||
      dataType == SMC_TYPE_SI32) {
    return 1;
  }
  return SMCFixedPointFractionBits(dataType, NULL) >= 0;
}

static kern_return_t SMCValidateResponse(const SMCKeyData_t *response) {
  if (response == NULL) {
    return kIOReturnBadArgument;
  }

  unsigned char result = (unsigned char)response->result;
  unsigned char status = (unsigned char)response->status;
  // `result` is the protocol-level completion code. `status` is present in
  // every AppleSMC response, but its non-zero values are not a stable failure
  // contract across driver generations. Keep successful results compatible
  // with older Macs instead of rejecting them solely on `status`.
  if (result == SMC_RESULT_SUCCESS) {
    return kIOReturnSuccess;
  }
  if (result == SMC_RESULT_KEY_NOT_FOUND ||
      status == SMC_RESULT_KEY_NOT_FOUND) {
    return kIOReturnNotFound;
  }
  return kIOReturnError;
}

io_connect_t SMCOpen(void) {
  kern_return_t result;
  io_iterator_t iterator;
  io_object_t device;
  io_connect_t conn = 0;

  CFMutableDictionaryRef matchingDictionary = IOServiceMatching("AppleSMC");
  result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary,
                                        &iterator);
  if (result != kIOReturnSuccess) {
    return 0;
  }

  device = IOIteratorNext(iterator);
  IOObjectRelease(iterator);

  if (device == 0) {
    return 0;
  }

  result = IOServiceOpen(device, mach_task_self(), 0, &conn);
  IOObjectRelease(device);

  if (result != kIOReturnSuccess) {
    return 0;
  }

  return conn;
}

kern_return_t SMCClose(io_connect_t conn) { return IOServiceClose(conn); }

static kern_return_t SMCCall(io_connect_t conn, int index,
                             SMCKeyData_t *inputStructure,
                             SMCKeyData_t *outputStructure) {
  size_t structureInputSize;
  size_t structureOutputSize;

  structureInputSize = sizeof(SMCKeyData_t);
  structureOutputSize = sizeof(SMCKeyData_t);

  return IOConnectCallStructMethod(conn, index, inputStructure,
                                   structureInputSize, outputStructure,
                                   &structureOutputSize);
}

kern_return_t SMCReadKey(io_connect_t conn, const char *key,
                         SMCKeyData_t *val) {
  if (conn == 0 || key == NULL || strlen(key) < 4 || val == NULL) {
    return kIOReturnBadArgument;
  }

  kern_return_t result;
  SMCKeyData_t inputStructure;
  SMCKeyData_t outputStructure;

  memset(&inputStructure, 0, sizeof(SMCKeyData_t));
  memset(&outputStructure, 0, sizeof(SMCKeyData_t));
  memset(val, 0, sizeof(SMCKeyData_t));

  inputStructure.key =
      SMC_FOURCC((unsigned char)key[0], (unsigned char)key[1],
                 (unsigned char)key[2], (unsigned char)key[3]);
  inputStructure.data8 = SMC_CMD_READ_KEYINFO;

  result = SMCCall(conn, KERNEL_INDEX_SMC, &inputStructure, &outputStructure);
  if (result != kIOReturnSuccess) {
    return result;
  }
  result = SMCValidateResponse(&outputStructure);
  if (result != kIOReturnSuccess) {
    return result;
  }
  if (outputStructure.keyInfo.dataSize == 0 ||
      outputStructure.keyInfo.dataSize > sizeof(val->bytes) ||
      outputStructure.keyInfo.dataType == 0) {
    return kIOReturnNotFound;
  }

  val->keyInfo.dataSize = outputStructure.keyInfo.dataSize;
  val->keyInfo.dataType = outputStructure.keyInfo.dataType;
  val->keyInfo.dataAttributes = outputStructure.keyInfo.dataAttributes;
  inputStructure.keyInfo.dataSize = val->keyInfo.dataSize;
  inputStructure.data8 = SMC_CMD_READ_BYTES;

  result = SMCCall(conn, KERNEL_INDEX_SMC, &inputStructure, &outputStructure);
  if (result != kIOReturnSuccess) {
    return result;
  }
  result = SMCValidateResponse(&outputStructure);
  if (result != kIOReturnSuccess) {
    return result;
  }

  memcpy(val->bytes, outputStructure.bytes, sizeof(outputStructure.bytes));
  return kIOReturnSuccess;
}

static kern_return_t SMCDecodeNumericValue(const SMCKeyData_t *raw,
                                           double *decoded) {
  if (raw == NULL || decoded == NULL || raw->keyInfo.dataSize == 0 ||
      raw->keyInfo.dataSize > sizeof(raw->bytes)) {
    return kIOReturnBadArgument;
  }

  uint32_t type = raw->keyInfo.dataType;
  uint32_t size = raw->keyInfo.dataSize;
  double value = 0.0;

  if ((type == SMC_TYPE_FLT || type == SMC_TYPE_IOF) && size >= 4) {
    // AppleSMC stores these IEEE-754 values in host/little-endian order.
    float floatValue = 0;
    memcpy(&floatValue, raw->bytes, sizeof(floatValue));
    value = (double)floatValue;
  } else if (type == SMC_TYPE_IOFT && size >= 8) {
    // IO fixed-point values use a little-endian unsigned 48.16 layout.
    uint64_t fixed = SMCReadUnsignedLittleEndian(raw->bytes, 8);
    value = (double)fixed / 65536.0;
  } else if (type == SMC_TYPE_UI8 && size >= 1) {
    value = (double)(unsigned char)raw->bytes[0];
  } else if (type == SMC_TYPE_UI16 && size >= 2) {
    value = (double)SMCReadUnsignedBigEndian(raw->bytes, 2);
  } else if (type == SMC_TYPE_UI32 && size >= 4) {
    value = (double)SMCReadUnsignedBigEndian(raw->bytes, 4);
  } else if (type == SMC_TYPE_SI8 && size >= 1) {
    value = (double)(int8_t)raw->bytes[0];
  } else if (type == SMC_TYPE_SI16 && size >= 2) {
    value = (double)(int16_t)SMCReadUnsignedBigEndian(raw->bytes, 2);
  } else if (type == SMC_TYPE_SI32 && size >= 4) {
    value = (double)(int32_t)SMCReadUnsignedBigEndian(raw->bytes, 4);
  } else {
    int isSigned = 0;
    int fractionBits = SMCFixedPointFractionBits(type, &isSigned);
    if (fractionBits < 0 || size < 2) {
      return kIOReturnUnsupported;
    }

    uint16_t rawValue = (uint16_t)SMCReadUnsignedBigEndian(raw->bytes, 2);
    double divisor = (double)(1U << fractionBits);
    value = isSigned ? (double)(int16_t)rawValue / divisor
                     : (double)rawValue / divisor;
  }

  if (!isfinite(value)) {
    return kIOReturnError;
  }
  *decoded = value;
  return kIOReturnSuccess;
}

kern_return_t SMCReadNumericValue(io_connect_t conn, const char *key,
                                  SMCNumericValue_t *value) {
  if (conn == 0 || key == NULL || strlen(key) < 4 || value == NULL) {
    return kIOReturnBadArgument;
  }

  memset(value, 0, sizeof(*value));
  SMCKeyData_t val;
  kern_return_t result = SMCReadKey(conn, key, &val);
  if (result != kIOReturnSuccess) {
    return result;
  }

  value->dataType = val.keyInfo.dataType;
  value->dataSize = val.keyInfo.dataSize;
  return SMCDecodeNumericValue(&val, &value->value);
}

double SMCGetFloatValue(io_connect_t conn, const char *key) {
  SMCNumericValue_t value;
  if (SMCReadNumericValue(conn, key, &value) == kIOReturnSuccess) {
    return value.value;
  }
  return 0.0;
}

int SMCGetKeyCount(io_connect_t conn) {
  SMCKeyData_t val;
  kern_return_t result = SMCReadKey(conn, "#KEY", &val);
  if (result != kIOReturnSuccess) {
    // printf("SMCGetKeyCount: SMCReadKey failed with result %d\n", result);
    return 0;
  }

  uint32_t count = ((uint32_t)(unsigned char)val.bytes[0] << 24) |
                   ((uint32_t)(unsigned char)val.bytes[1] << 16) |
                   ((uint32_t)(unsigned char)val.bytes[2] << 8) |
                   (uint32_t)(unsigned char)val.bytes[3];
  if (count > INT_MAX) {
    return 0;
  }
  // printf("SMCGetKeyCount: Found %d keys\n", count);
  return (int)count;
}

kern_return_t SMCGetKeyFromIndex(io_connect_t conn, int index,
                                 char *outputKey) {
  if (conn == 0 || index < 0 || outputKey == NULL) {
    return kIOReturnBadArgument;
  }

  kern_return_t result;
  SMCKeyData_t inputStructure;
  SMCKeyData_t outputStructure;

  memset(&inputStructure, 0, sizeof(SMCKeyData_t));
  memset(&outputStructure, 0, sizeof(SMCKeyData_t));

  inputStructure.data8 = SMC_CMD_READ_INDEX;
  inputStructure.data32 = index;

  result = SMCCall(conn, KERNEL_INDEX_SMC, &inputStructure, &outputStructure);
  if (result != kIOReturnSuccess) {
    return result;
  }
  result = SMCValidateResponse(&outputStructure);
  if (result != kIOReturnSuccess) {
    return result;
  }

  unsigned int key = outputStructure.key;
  if (key == 0) {
    return kIOReturnNotFound;
  }
  outputKey[0] = (key >> 24) & 0xFF;
  outputKey[1] = (key >> 16) & 0xFF;
  outputKey[2] = (key >> 8) & 0xFF;
  outputKey[3] = key & 0xFF;
  outputKey[4] = '\0';

  return kIOReturnSuccess;
}

kern_return_t SMCGetKeyInfo(io_connect_t conn, const char *key,
                            SMCKeyData_keyInfo_t *keyInfo) {
  if (conn == 0 || key == NULL || strlen(key) < 4 || keyInfo == NULL) {
    return kIOReturnBadArgument;
  }

  kern_return_t result;
  SMCKeyData_t inputStructure;
  SMCKeyData_t outputStructure;

  memset(&inputStructure, 0, sizeof(SMCKeyData_t));
  memset(&outputStructure, 0, sizeof(SMCKeyData_t));

  inputStructure.key =
      SMC_FOURCC((unsigned char)key[0], (unsigned char)key[1],
                 (unsigned char)key[2], (unsigned char)key[3]);
  inputStructure.data8 = SMC_CMD_READ_KEYINFO;

  result = SMCCall(conn, KERNEL_INDEX_SMC, &inputStructure, &outputStructure);
  if (result != kIOReturnSuccess) {
    return result;
  }
  result = SMCValidateResponse(&outputStructure);
  if (result != kIOReturnSuccess) {
    return result;
  }
  if (outputStructure.keyInfo.dataSize == 0 ||
      outputStructure.keyInfo.dataSize > sizeof(outputStructure.bytes) ||
      outputStructure.keyInfo.dataType == 0) {
    return kIOReturnNotFound;
  }

  *keyInfo = outputStructure.keyInfo;
  return kIOReturnSuccess;
}
