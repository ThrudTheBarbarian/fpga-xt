/* linux/i2c-dev.h — Linux-uapi-compatible ioctl requests for /OS/dev/i2c-N.
 * The devfs i2c node (vfs_devfs.c) implements SLAVE/FUNCS/SMBUS; RDWR is
 * declared for source compatibility but the kernel rejects it (-1/ENOTTY). */
#ifndef _COMPAT_LINUX_I2C_DEV_H
#define _COMPAT_LINUX_I2C_DEV_H

#include <linux/i2c.h>

#define I2C_SLAVE       0x0703   /* set the 7-bit slave address (by value) */
#define I2C_SLAVE_FORCE 0x0706
#define I2C_FUNCS       0x0705   /* unsigned long *: functionality bitmask */
#define I2C_RDWR        0x0707   /* struct i2c_rdwr_ioctl_data * (unsupported) */
#define I2C_SMBUS       0x0720   /* struct i2c_smbus_ioctl_data * */

struct i2c_smbus_ioctl_data {
    uint8_t  read_write;         /* I2C_SMBUS_READ / I2C_SMBUS_WRITE */
    uint8_t  command;            /* register offset */
    uint32_t size;               /* I2C_SMBUS_* transaction kind */
    union i2c_smbus_data *data;
};

#define I2C_RDWR_IOCTL_MAX_MSGS 42
struct i2c_rdwr_ioctl_data {
    struct i2c_msg *msgs;
    uint32_t        nmsgs;
};

#endif
