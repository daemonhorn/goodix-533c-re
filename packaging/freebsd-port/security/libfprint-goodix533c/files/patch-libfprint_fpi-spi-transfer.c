--- libfprint/fpi-spi-transfer.c.orig	2026-08-23 16:46:31 UTC
+++ libfprint/fpi-spi-transfer.c
@@ -18,9 +18,17 @@
  */
 
 #include "fpi-spi-transfer.h"
+#include <errno.h>
+/* This translation unit is always compiled, whether or not any SPI-based
+ * driver ('elanspi', the only current SPI driver_helper_mapping consumer)
+ * is enabled -- there is no build-time gate. Its actual transfer mechanism
+ * (transfer_chunk(), below) is Linux spidev-specific; on other platforms it
+ * is stubbed out to fail cleanly rather than fail to compile, since no
+ * driver in a non-Linux build's driver list currently exercises it. */
+#if defined(__linux__)
 #include <sys/ioctl.h>
 #include <linux/spi/spidev.h>
-#include <errno.h>
+#endif
 
 /* spidev can only handle the specified block size, which defaults to 4096. */
 #define SPIDEV_BLOCK_SIZE_PARAM "/sys/module/spidev/parameters/bufsiz"
@@ -310,6 +318,7 @@ transfer_finish_cb (GObject *source_object, GAsyncResu
   callback (transfer, transfer->device, transfer->user_data, error);
 }
 
+#if defined(__linux__)
 static int
 transfer_chunk (FpiSpiTransfer *transfer, gsize full_length, gsize *transferred)
 {
@@ -381,6 +390,18 @@ transfer_chunk (FpiSpiTransfer *transfer, gsize full_l
 
   return status;
 }
+#else
+static int
+transfer_chunk (FpiSpiTransfer *transfer, gsize full_length, gsize *transferred)
+{
+  /* No spidev-equivalent kernel ABI on this platform. Not reached by any
+   * driver in a non-Linux build's -Ddrivers= list (SPI support is only
+   * used by 'elanspi', which requires the Linux-only 'udev' build helper
+   * and is excluded from non-Linux driver lists for that reason already). */
+  errno = ENOSYS;
+  return -1;
+}
+#endif
 
 static void
 transfer_thread_func (GTask        *task,
