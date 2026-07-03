/* linux/i2c.h — Linux-uapi-compatible i2c message/SMBus types for XTOS.
 * Layouts match the kernel-side structs in vfs_devfs.c; the /OS/dev/i2c-N
 * ioctl surface (see linux/i2c-dev.h) consumes them directly. */
#ifndef _COMPAT_LINUX_I2C_H
#define _COMPAT_LINUX_I2C_H

#include <stdint.h>

struct i2c_msg {
    uint16_t addr;              /* 7-bit slave address */
    uint16_t flags;
#define I2C_M_RD   0x0001       /* read (from slave to master) */
#define I2C_M_TEN  0x0010       /* 10-bit addressing (unsupported) */
    uint16_t len;
    uint8_t *buf;
};

/* functionality bits (I2C_FUNCS) */
#define I2C_FUNC_I2C                  0x00000001
#define I2C_FUNC_SMBUS_QUICK          0x00010000
#define I2C_FUNC_SMBUS_READ_BYTE      0x00020000
#define I2C_FUNC_SMBUS_WRITE_BYTE     0x00040000
#define I2C_FUNC_SMBUS_READ_BYTE_DATA 0x00080000
#define I2C_FUNC_SMBUS_WRITE_BYTE_DATA 0x00100000
#define I2C_FUNC_SMBUS_READ_WORD_DATA 0x00200000
#define I2C_FUNC_SMBUS_WRITE_WORD_DATA 0x00400000
#define I2C_FUNC_SMBUS_READ_I2C_BLOCK 0x04000000
#define I2C_FUNC_SMBUS_WRITE_I2C_BLOCK 0x08000000

#define I2C_SMBUS_BLOCK_MAX 32
union i2c_smbus_data {
    uint8_t  byte;
    uint16_t word;
    uint8_t  block[I2C_SMBUS_BLOCK_MAX + 2];   /* block[0] = length */
};

/* i2c_smbus_ioctl_data.read_write */
#define I2C_SMBUS_WRITE 0
#define I2C_SMBUS_READ  1

/* i2c_smbus_ioctl_data.size (transaction kinds) */
#define I2C_SMBUS_QUICK          0
#define I2C_SMBUS_BYTE           1
#define I2C_SMBUS_BYTE_DATA      2
#define I2C_SMBUS_WORD_DATA      3
#define I2C_SMBUS_I2C_BLOCK_DATA 8

#endif
