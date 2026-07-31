// smc.c
#include "SMC.h"
#include <stdio.h>
#include <string.h>

#define SMC_RESULT_SUCCESS 0x00
#define SMC_RESULT_KEY_NOT_FOUND 0x84

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

kern_return_t SMCCall(io_connect_t conn, int index,
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
  kern_return_t result;
  SMCKeyData_t inputStructure;
  SMCKeyData_t outputStructure;

  memset(&inputStructure, 0, sizeof(SMCKeyData_t));
  memset(&outputStructure, 0, sizeof(SMCKeyData_t));
  memset(val, 0, sizeof(SMCKeyData_t));

  inputStructure.key = (key[0] << 24) | (key[1] << 16) | (key[2] << 8) | key[3];
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

double SMCGetFloatValue(io_connect_t conn, const char *key) {
  SMCKeyData_t val;
  kern_return_t result = SMCReadKey(conn, key, &val);
  if (result != kIOReturnSuccess) {
    return 0.0;
  }

  // flt  (0x666C7420) — IEEE 754 float, used for power/fan keys
  if (val.keyInfo.dataType == 1718383648 &&
      val.keyInfo.dataSize >= sizeof(float)) {
    float f;
    memcpy(&f, val.bytes, 4);
    return (double)f;
  }

  // sp78 (0x73703738) — signed fixed-point 7.8, used for Apple Silicon temperature sensors
  if (val.keyInfo.dataType == 1936734008 && val.keyInfo.dataSize >= 2) {
    int16_t raw = (int16_t)(((unsigned char)val.bytes[0] << 8) | (unsigned char)val.bytes[1]);
    return (double)raw / 256.0;
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

  unsigned int count = 0;
  count = ((unsigned char)val.bytes[0] << 24) |
          ((unsigned char)val.bytes[1] << 16) |
          ((unsigned char)val.bytes[2] << 8) | (unsigned char)val.bytes[3];
  // printf("SMCGetKeyCount: Found %d keys\n", count);
  return count;
}

kern_return_t SMCGetKeyFromIndex(io_connect_t conn, int index,
                                 char *outputKey) {
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
  kern_return_t result;
  SMCKeyData_t inputStructure;
  SMCKeyData_t outputStructure;

  memset(&inputStructure, 0, sizeof(SMCKeyData_t));
  memset(&outputStructure, 0, sizeof(SMCKeyData_t));

  inputStructure.key = (key[0] << 24) | (key[1] << 16) | (key[2] << 8) | key[3];
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
