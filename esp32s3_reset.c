/*
 * ESP32S3 Hardware Reset via CH343 RTS/DTR control
 * Based on CH343 library functions
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <fcntl.h>

int main(int argc, char *argv[])
{
    int fd;
    int status;
    int bootloader_mode = 0;
    
    if (argc < 2 || argc > 3) {
        printf("Usage: %s <serial_device> [bootloader]\n", argv[0]);
        printf("Example: %s /dev/ttyCH343USB0          # Normal boot\n", argv[0]);
        printf("Example: %s /dev/ttyCH343USB0 bootloader # Bootloader mode\n", argv[0]);
        return -1;
    }
    
    if (argc == 3 && strcmp(argv[2], "bootloader") == 0) {
        bootloader_mode = 1;
    }
    
    // 打开串口设备
    fd = open(argv[1], O_RDWR | O_NOCTTY);
    if (fd < 0) {
        perror("Failed to open serial device");
        return -1;
    }
    
    if (bootloader_mode) {
        printf("Resetting ESP32S3 into bootloader mode via RTS/DTR control...\n");
    } else {
        printf("Resetting ESP32S3 into normal mode via RTS/DTR control...\n");
    }
    
    // ESP32S3重启序列：
    // DTR控制EN引脚 (DTR=1为低电平，DTR=0为高电平)
    // RTS控制GPIO0引脚 (RTS=1为低电平，RTS=0为高电平)
    // 对于bootloader: EN=low->high, GPIO0=low
    // 对于normal: EN=low->high, GPIO0=high
    
    // 步骤1: 准备重启序列
    printf("Step 1: Setting up reset sequence...\n");
    ioctl(fd, TIOCMGET, &status);
    status &= ~TIOCM_DTR;  // DTR = 0 (EN = high)
    if (bootloader_mode) {
        status |= TIOCM_RTS;   // RTS = 1 (GPIO0 = low) - bootloader模式
    } else {
        status &= ~TIOCM_RTS;  // RTS = 0 (GPIO0 = high) - 正常模式
    }
    ioctl(fd, TIOCMSET, &status);
    usleep(50000); // 50ms
    
    // 步骤2: 拉低EN引脚执行重启
    printf("Step 2: Pulling EN low to reset...\n");
    ioctl(fd, TIOCMGET, &status);
    status |= TIOCM_DTR;   // DTR = 1 (EN = low) - 执行重启
    ioctl(fd, TIOCMSET, &status);
    usleep(100000); // 100ms
    
    // 步骤3: 释放EN引脚，设备启动
    printf("Step 3: Releasing EN to start...\n");
    ioctl(fd, TIOCMGET, &status);
    status &= ~TIOCM_DTR;  // DTR = 0 (EN = high) - 释放重启
    ioctl(fd, TIOCMSET, &status);
    usleep(200000); // 200ms 等待启动
    
    printf("Reset sequence completed!\n");
    if (bootloader_mode) {
        printf("ESP32S3 should now be in bootloader mode for flashing.\n");
    } else {
        printf("ESP32S3 should now be running in normal mode.\n");
    }
    
    close(fd);
    return 0;
}